import http from 'node:http';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Store } from './db.mjs';

const execFileAsync = promisify(execFile);
const defaultDb = resolve(process.env.NOVA_DB ?? './.nova-data/nova.sqlite');
const MAX_BODY = 8192;
const types = new Set(['hello', 'mac.status', 'repo.status']);
const json = (res, status, object) => {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(JSON.stringify(object));
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

export function makeNova({ dbFile = defaultDb, workspace = process.env.NOVA_WORKSPACE, executeOverride } = {}) {
  const store = new Store(dbFile);
  store.reconcileStartup();
  let server;
  const active = new Map();
  const execute = executeOverride ?? (async (type, payload, signal) => {
    if (type === 'hello') return { message: `Nova received: ${payload.message || 'Hello!'}` };
    if (type === 'mac.status') return { platform: os.platform(), release: os.release(), arch: os.arch(), uptimeSeconds: Math.round(os.uptime()) };
    if (type === 'repo.status') {
      if (!workspace) throw new Error('NOVA_WORKSPACE not configured on the Mac');
      const { stdout } = await execFileAsync('git', ['status','--short','--branch'], { cwd: resolve(workspace), timeout: 10000, maxBuffer: 4096, signal });
      return { output: stdout.trim().slice(0,4000) };
    }
    throw new Error('Unknown safe task type');
  });
  const runJob = async (id, type, payload) => {
    if (store.stopped()) { store.updateJob(id, 'cancelled'); return; }
    const controller = new AbortController(); active.set(id, controller);
    store.updateJob(id, 'running');
    try {
      const result = await execute(type, payload, controller.signal);
      if (controller.signal.aborted || store.stopped()) store.updateJob(id, 'cancelled');
      else store.updateJob(id, 'succeeded', result);
    } catch (error) { store.updateJob(id, controller.signal.aborted ? 'cancelled' : 'failed', null, String(error.message).slice(0,250)); }
    finally { active.delete(id); }
  };
  const handler = async (req, res) => {
    try {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1');
      if (req.method === 'GET' && url.pathname === '/v1/health') return json(res, 200, { service:'nova-core', version:'0.1.0', ready:true });
      if (req.method === 'POST' && url.pathname === '/v1/pair') {
        const body = await readJson(req);
        if (!body || typeof body.code !== 'string' || body.code.length > 60 || typeof body.deviceName !== 'string' || body.deviceName.length > 50 || !body.deviceName.trim()) return json(res,400,{error:'Invalid pairing request'});
        const credential = store.redeemInvitation(body.code, body.deviceName.trim());
        return credential ? json(res, 201, credential) : json(res, 403, {error:'Pairing code invalid, expired or used'});
      }
      const authorization = req.headers.authorization ?? '';
      const device = authorization.startsWith('Bearer ') ? store.auth(authorization.slice(7)) : null;
      if (!device) return json(res, 401, { error:'Pair this iPhone before accessing Nova' });
      if (req.method === 'GET' && url.pathname === '/v1/status') return json(res,200,{connected:true,stopped:store.stopped(),device:device.name,capabilities:[...types]});
      if (req.method === 'GET' && url.pathname === '/v1/jobs') return json(res,200,{jobs:store.jobs(device.id)});
      if (req.method === 'POST' && url.pathname === '/v1/jobs') {
        if (store.stopped()) return json(res,423,{error:'Nova is stopped. Resume locally on Mac.'});
        const body = await readJson(req);
        if (!body || !types.has(body.type)) return json(res,400,{error:'Only known read-only task types are supported in v0.1'});
        const payload = { message: body.type === 'hello' ? cleanMessage(body.message ?? '') : '' };
        const id = store.createJob(device.id, body.type, payload);
        setImmediate(() => { void runJob(id, body.type, payload); });
        return json(res,202,{id,status:'queued'});
      }
      const jobMatch = /^\/v1\/jobs\/([a-zA-Z0-9_-]{16})$/.exec(url.pathname);
      if (req.method === 'GET' && jobMatch) {
        const job = store.getJob(jobMatch[1],device.id);
        return job ? json(res,200,{...job,events:store.events(job.id)}) : json(res,404,{error:'Job not found'});
      }
      if (req.method === 'POST' && url.pathname === '/v1/stop') {
        store.stop(); for (const controller of active.values()) controller.abort();
        return json(res,200,{stopped:true});
      }
      return json(res,404,{error:'Not found'});
    } catch (error) { return json(res,error.status || 500,{error:error.status ? error.message : 'Internal error'}); }
  };
  return {
    store,
    async listen(port=8787, host='127.0.0.1') {
      server=http.createServer((req,res)=>{void handler(req,res);});
      await new Promise((ok,fail)=>server.once('error',fail).listen(port,host,ok));
      return server.address().port;
    },
    async close() { for(const c of active.values()) c.abort(); if(server) await new Promise(ok=>server.close(ok)); store.close(); }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const app = makeNova();
  const port = await app.listen(Number(process.env.NOVA_PORT ?? 8787));
  console.log(`Nova Core v0.1 listening on http://127.0.0.1:${port} (safe read-only tasks only)`);
  process.on('SIGINT',()=>{void app.close().then(()=>process.exit(0));});
}
