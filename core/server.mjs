import http from 'node:http';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Store } from './db.mjs';
import { paths } from './paths.mjs';
import { createAI } from './ai.mjs';
import { createComputer, permissions, requestPermissions } from './computer.mjs';
import { createWork } from './work.mjs';
import { readAccess, validateApps, validateFolders, LEVELS } from './policy.mjs';
import { keys as defaultKeys, PROVIDERS, providerStatus, selectedProvider, testKey } from './keys.mjs';
import { computerName, createPairingGuard, installedApps, listFolders, setupStatus } from './setup.mjs';

const execFileAsync = promisify(execFile);
const MAX_BODY = 8192;
const types = new Set(['hello', 'mac.status', 'repo.status', 'ai.chat', 'computer.task']);
const json = (res, status, object) => {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(JSON.stringify(object));
  return true;
};
async function readJson(req) {
  let size = 0, chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) { const e = new Error('Payload too large'); e.status = 413; throw e; }
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { const e = new Error('Invalid JSON'); e.status = 400; throw e; }
}
function cleanMessage(message) {
  if (typeof message !== 'string' || message.length > 350) throw Object.assign(new Error('Message must be text of at most 350 characters'), {status:400});
  return message.trim();
}

export function makeNova({ dbFile = paths.db, workspace = paths.workspace, executeOverride, aiOptions, computerOptions, workOptions, setupOptions = {} } = {}) {
  const store = new Store(dbFile);
  const keyStore = setupOptions.keyStore ?? defaultKeys;
  const keyTest = setupOptions.testKey ?? testKey;
  const askPermissions = setupOptions.requestPermissions ?? requestPermissions;
  const apps = setupOptions.installedApps ?? installedApps;
  const ai = createAI(store, { keyStore, ...aiOptions });
  const computer=createComputer(store,{keyStore,...computerOptions});
  const work=createWork(store,computer,{call:computerOptions?.call,openai:computerOptions?.openai,keyStore,...workOptions});
  const pairing = createPairingGuard(setupOptions.pairing);
  let server;
  let closing = false, closePromise;
  const active = new Map();
  const pending = new Set();
  const scheduled = new Set();
  const execute = executeOverride ?? (async (type, payload, signal) => {
    if (type === 'hello') return { message: `Nova received: ${payload.message || 'Hello!'}` };
    if (type === 'mac.status') return { platform: os.platform(), release: os.release(), arch: os.arch(), uptimeSeconds: Math.round(os.uptime()) };
    if (type === 'repo.status') {
      if (!workspace) throw new Error('NOVA_WORKSPACE not configured on the Mac');
      // Status can otherwise execute a repository's fsmonitor hook and refresh its index.
      const { stdout } = await execFileAsync('git', ['--no-optional-locks', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', 'status', '--short', '--branch', '--ignore-submodules=all'], { cwd: resolve(workspace), timeout: 10000, maxBuffer: 4096, signal });
      return { output: stdout.trim().slice(0,4000) };
    }
    throw new Error('Unknown safe task type');
  });
  const runJob = async (id, type, payload, deviceId) => {
    if (closing || store.stopped()) { store.updateJob(id, 'cancelled'); return; }
    const controller = new AbortController(); active.set(id, controller);
    store.updateJob(id, 'running');
    try {
      if (type === 'computer.task') await work.yieldComputer();
      const result = type === 'computer.task'
        ? await computer.task(deviceId,id,payload.message,controller.signal,payload.conversation,{...work.tools(deviceId,id),prefix:work.context(deviceId)})
        : type === 'ai.chat'
        ? await ai.chat(id, deviceId, payload.message, controller.signal)
        : await execute(type, payload, controller.signal);
      if (controller.signal.aborted || store.stopped()) store.updateJob(id, 'cancelled');
      else store.updateJob(id, 'succeeded', result);
    } catch (error) { store.updateJob(id, controller.signal.aborted ? 'cancelled' : 'failed', null, String(error.message).slice(0,250)); }
    finally { active.delete(id); }
  };
  const schedule=(id,type,payload,deviceId)=>{
    if(active.has(id)||scheduled.has(id))throw Object.assign(new Error('Job is already running'),{status:409});
    scheduled.add(id);
    const task=new Promise(ok=>setImmediate(ok)).then(()=>{scheduled.delete(id);return runJob(id,type,payload,deviceId);});
    pending.add(task);void task.finally(()=>pending.delete(task));
  };
  const badProvider = res => json(res,400,{error:'Choose Claude or OpenAI'});
  // Setup, devices and unpairing. Returns true once it has responded, otherwise undefined.
  // Changes are owner-only; any paired device may read setup status and unpair itself.
  const setupRoute = async (req, url, device, owner, res) => {
    const path = url.pathname;
    if (req.method === 'GET' && path === '/v1/setup') return json(res,200,await setupStatus(store,device,{keyStore,permissionCheck:computer.permissions,owner}));
    if (req.method === 'POST' && path === '/v1/unpair') { store.revokeDevice(device.id); return json(res,200,{unpaired:true}); }
    if (!path.startsWith('/v1/setup/') && path !== '/v1/devices' && path !== '/v1/devices/revoke') return undefined;
    if (!owner) return json(res,403,{error:'Only the iPhone that controls this Mac can change setup. Pair it from the Mac with "This iPhone controls the Mac" turned on.'});
    if (req.method === 'GET' && path === '/v1/devices') {
      const ownerId = store.setting('computer_owner');
      return json(res,200,{devices:store.devices().map(d=>({...d,owner:d.id===ownerId,current:d.id===device.id}))});
    }
    if (req.method === 'POST' && path === '/v1/devices/revoke') {
      const body = await readJson(req);
      return store.revokeDevice(String(body?.id ?? '')) ? json(res,200,{revoked:true}) : json(res,404,{error:'That device is not paired'});
    }
    if (req.method === 'GET' && path === '/v1/setup/apps') return json(res,200,{apps:await apps()});
    if (req.method === 'GET' && path === '/v1/setup/folders') {
      try { return json(res,200,{folders:listFolders(url.searchParams.get('in') ?? '~')}); }
      catch (error) { return json(res,400,{error:error.message}); }
    }
    if (req.method === 'POST' && path === '/v1/setup/access') {
      const body = await readJson(req);
      if (!LEVELS.includes(body?.level)) return json(res,400,{error:'Choose a range: chat, apps or full'});
      try {
        let chosenApps = [];
        if (body.level === 'apps') {
          const installed = new Map((await apps()).map(a=>[a.bundleId,a]));
          chosenApps = validateApps(body.apps ?? []).map(a=>installed.get(a.bundleId) ?? null);
          if (chosenApps.includes(null)) return json(res,400,{error:"One of those apps isn't installed on the Mac"});
        }
        const folders = body.level === 'chat' ? [] : validateFolders(body.folders ?? []);
        if (body.level === 'apps' && !chosenApps.length && !folders.length) return json(res,400,{error:'Choose at least one app or folder'});
        store.setSetting('access_level',body.level);
        store.setSetting('access_apps',JSON.stringify(chosenApps));
        store.setSetting('access_folders',JSON.stringify(folders));
        store.setSetting('access_chosen','1');
        store.event(null,'range',`${device.name} set Nova's range to ${body.level} (${chosenApps.length} apps, ${folders.length} folders)`);
        return json(res,200,{access:readAccess(store)});
      } catch (error) { return json(res,400,{error:error.message}); }
    }
    if (req.method === 'POST' && path === '/v1/setup/key') {
      const body = await readJson(req);
      const provider = body?.provider;
      if (!PROVIDERS[provider]) return badProvider(res);
      const key = typeof body.key === 'string' ? body.key.trim() : '';
      if (!PROVIDERS[provider].pattern.test(key)) return json(res,400,{error:provider==='anthropic'?"That doesn't look like a Claude API key. Claude keys start with sk-ant-.":"That doesn't look like an OpenAI API key. OpenAI keys start with sk-."});
      const test = await keyTest(provider,key);
      if (test.code === 'rejected') return json(res,400,{error:test.message,test});
      try { keyStore.save(provider,key); } catch (error) { return json(res,500,{error:error.message}); }
      if (body.select !== false) store.setSetting('ai_provider',provider);
      store.event(null,'ai_key',`${device.name} connected a ${PROVIDERS[provider].label} key`);
      return json(res,200,{saved:true,test,ai:providerStatus(store,keyStore)});
    }
    if (req.method === 'POST' && path === '/v1/setup/key/remove') {
      const body = await readJson(req);
      if (!PROVIDERS[body?.provider]) return badProvider(res);
      keyStore.remove(body.provider);
      if (store.setting('ai_provider') === body.provider) store.setSetting('ai_provider',null);
      store.event(null,'ai_key',`${device.name} removed the ${PROVIDERS[body.provider].label} key from the Keychain`);
      return json(res,200,{ai:providerStatus(store,keyStore)});
    }
    if (req.method === 'POST' && path === '/v1/setup/provider') {
      const body = await readJson(req);
      if (!PROVIDERS[body?.provider]) return badProvider(res);
      if (!keyStore.storage(body.provider)) return json(res,400,{error:`Connect your ${PROVIDERS[body.provider].label} key first`});
      store.setSetting('ai_provider',body.provider);
      return json(res,200,{ai:providerStatus(store,keyStore)});
    }
    if (req.method === 'POST' && path === '/v1/setup/test') {
      const body = await readJson(req);
      if (!PROVIDERS[body?.provider]) return badProvider(res);
      const key = keyStore.read(body.provider);
      if (!key) return json(res,400,{error:`No ${PROVIDERS[body.provider].label} key is connected yet`});
      return json(res,200,{test:await keyTest(body.provider,key)});
    }
    if (req.method === 'POST' && path === '/v1/setup/permissions') {
      try { await askPermissions(); } catch (error) { return json(res,409,{error:error.message}); }
      return json(res,200,{asked:true,permissions:await computer.permissions()});
    }
    return json(res,404,{error:'Not found'});
  };
  const handler = async (req, res) => {
    try {
      if (closing) return json(res,503,{error:'Core is shutting down'});
      const url = new URL(req.url ?? '/', 'http://127.0.0.1');
      if (req.method === 'GET' && url.pathname === '/v1/health') return json(res, 200, { service:'nova-core', version:'0.1.0', ready:true });
      if (req.method === 'POST' && url.pathname === '/v1/pair') {
        if (pairing.locked()) return json(res,429,{error:'Too many wrong codes. Wait 10 minutes, then make a new code on your Mac.',code:'locked'});
        const body = await readJson(req);
        if (!body || typeof body.code !== 'string' || body.code.length > 60 || typeof body.deviceName !== 'string' || body.deviceName.length > 50 || !body.deviceName.trim()) return json(res,400,{error:'Invalid pairing request'});
        const credential = store.redeemInvitation(body.code, body.deviceName.trim());
        if (credential) return json(res, 201, {...credential, computer:computerName()});
        if (pairing.fail()) store.expireInvitations();
        return json(res, 403, {error:"That code didn't work. It may be mistyped, expired (codes last 10 minutes) or already used. Make a new code on your Mac and try again.",code:'invalid'});
      }
      const authorization = req.headers.authorization ?? '';
      const device = authorization.startsWith('Bearer ') ? store.auth(authorization.slice(7)) : null;
      if (!device) return json(res, 401, { error:'This iPhone is no longer paired with the Mac. Pair it again.', code:'unpaired' });
      const owner = computer.status(device.id).owner;
      if (req.method === 'GET' && url.pathname === '/v1/status') {
        const provider = selectedProvider(store, keyStore);
        return json(res,200,{connected:true,stopped:store.stopped(),device:device.name,capabilities:[...types].filter(type=>type!=='computer.task'||owner),ai:ai.status(),computer:computer.status(device.id),
          range:readAccess(store).level,provider:{selected:provider,label:PROVIDERS[provider].label,configured:Boolean(keyStore.storage(provider))}});
      }
      if (await setupRoute(req, url, device, owner, res)) return;
      if(req.method==='GET'&&url.pathname==='/v1/computer/permissions'){
        if(!computer.status(device.id).owner)return json(res,403,{error:'Owner iPhone required'});
        return json(res,200,await computer.permissions());
      }
      if(req.method==='POST'&&url.pathname==='/v1/computer/end'){
        const task=computer.status(device.id).task;
        if(task)active.get(task)?.abort();
        return json(res,200,{ended:true});
      }
      if(req.method==='POST'&&url.pathname==='/v1/computer/takeover'){
        try{return json(res,200,computer.takeOver(device.id));}catch(error){return json(res,403,{error:error.message});}
      }
      if(req.method==='POST'&&url.pathname==='/v1/computer/input'){
        const body=await readJson(req);
        // Taking over pauses whatever Nova is doing on the Mac until Matthew hands back control.
        try{return json(res,200,await computer.input(device.id,body));}catch(error){return json(res,409,{error:error.message});}
      }
      if(req.method==='POST'&&url.pathname==='/v1/computer/release'){
        try{computer.release(device.id);return json(res,200,{released:true});}catch(error){return json(res,403,{error:error.message});}
      }
      if(req.method==='GET'&&url.pathname==='/v1/work')return json(res,200,work.status(device.id));
      if(req.method==='POST'&&url.pathname==='/v1/work/agent'){
        try{return json(res,201,{id:work.startAgent(device.id,await readJson(req))});}
        catch(error){return json(res,400,{error:error.message});}
      }
      if(req.method==='POST'&&url.pathname==='/v1/work/schedule'){
        try{return json(res,201,work.addSchedule(device.id,await readJson(req)));}
        catch(error){return json(res,400,{error:error.message});}
      }
      if(req.method==='POST'&&url.pathname==='/v1/work/cancel'){
        const body=await readJson(req);
        try{return json(res,200,{message:work.cancel(device.id,String(body?.id??''))});}catch(error){return json(res,404,{error:error.message});}
      }
      if(req.method==='GET'&&url.pathname==='/v1/computer/live'){
        try{const jpeg=await computer.live(device.id);res.writeHead(200,{'Content-Type':'image/jpeg','Cache-Control':'no-store'});return res.end(jpeg);}
        catch(error){return json(res,409,{error:error.message});}
      }
      const screenMatch=/^\/v1\/computer\/screen\/([a-zA-Z0-9_-]{16})$/.exec(url.pathname);
      if(screenMatch&&req.method==='GET'){
        try{const jpeg=computer.screen(device.id,screenMatch[1]);res.writeHead(200,{'Content-Type':'image/jpeg','Cache-Control':'no-store'});return res.end(jpeg);}
        catch(error){return json(res,404,{error:error.message});}
      }
      if (req.method === 'GET' && url.pathname === '/v1/jobs') return json(res,200,{jobs:store.jobs(device.id)});
      if (req.method === 'POST' && url.pathname === '/v1/jobs') {
        if (store.stopped()) return json(res,423,{error:'Nova is stopped. Resume locally on Mac.'});
        const body = await readJson(req);
        if (!body || !types.has(body.type)) return json(res,400,{error:'Only known safe task types are supported'});
        if (body.type === 'computer.task' && !owner) return json(res,403,{error:'This iPhone is paired for conversation only. Enable "This iPhone controls the Mac" when pairing from Nova on your Mac.'});
        if (['ai.chat','computer.task'].includes(body.type) && (typeof body.message !== 'string' || !body.message.trim() || body.message.length > 2000)) return json(res,400,{error:'AI messages must contain 1–2000 characters'});
        const payload = { message: ['ai.chat','computer.task'].includes(body.type) ? body.message.trim() : body.type === 'hello' ? cleanMessage(body.message ?? '') : '' };
        if (body.type === 'computer.task' && typeof body.conversation === 'string' && /^[A-Za-z0-9-]{8,64}$/.test(body.conversation)) payload.conversation = body.conversation;
        const id = store.createJob(device.id, body.type, payload);
        schedule(id,body.type,payload,device.id);
        return json(res,202,{id,status:'queued'});
      }
      const jobMatch = /^\/v1\/jobs\/([a-zA-Z0-9_-]{16})$/.exec(url.pathname);
      if (req.method === 'GET' && jobMatch) {
        const job = store.getJob(jobMatch[1],device.id);
        return job ? json(res,200,{...job,events:store.events(job.id)}) : json(res,404,{error:'Job not found'});
      }
      if (req.method === 'POST' && url.pathname === '/v1/stop') {
        store.stop();computer.stop();work.stop(); for (const controller of active.values()) controller.abort();
        return json(res,200,{stopped:true});
      }
      return json(res,404,{error:'Not found'});
    } catch (error) { return json(res,error.status || 500,{error:error.status ? error.message : 'Internal error'}); }
  };
  return {
    store, work,
    async listen(port=8787, host='127.0.0.1') {
      if (host !== '127.0.0.1' && host !== '::1') throw new Error('Nova Core must listen on loopback; use private Tailscale Serve');
      server=http.createServer((req,res)=>{void handler(req,res);});
      await new Promise((ok,fail)=>server.once('error',fail).listen(port,host,ok));
      // A failed second server must never interrupt jobs in the live instance.
      store.reconcileStartup();
      work.start();
      return server.address().port;
    },
    close() {
      if (!closePromise) closePromise = (async () => {
        closing = true;
        await work.close();
        computer.stop();
        for (const c of active.values()) c.abort();
        if (server?.listening) await new Promise(ok => server.close(ok));
        await Promise.allSettled([...pending]);
        store.close();
      })();
      return closePromise;
    }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const app = makeNova();
  const port = await app.listen(paths.port);
  console.log(`Nova Core v0.1 listening on http://127.0.0.1:${port} (chat and autonomous computer control)`);
  console.log('Nova Operator service-context permissions: '+JSON.stringify(await permissions()));
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal,()=>{void app.close().then(()=>process.exit(0));});
  }
}
