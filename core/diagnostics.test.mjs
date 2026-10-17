import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync,existsSync,readFileSync,chmodSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {Store} from './db.mjs';
import {makeNova} from './server.mjs';
import {memoryKeyStore} from './keys.mjs';
import {collectDiagnostics,inspectDiagnosticDatabase,formatDiagnostics} from './diagnostics.mjs';

const network={installed:true,running:true,url:'https://private-mac.test.ts.net',funnel:false};
const native={running:true,accessibility:true,screenRecording:true};
const setup={state:'ok',privateFile:true,paired:true,ownerPaired:true,range:'full',stopped:false};
const fetchOK=async url=>url.endsWith('/v1/health')?Response.json({service:'nova-core',ready:true}):new Response(null,{status:401});
const options={fetchImpl:fetchOK,tailStatus:async()=>network,permissionCheck:async()=>native,inspectDatabase:()=>setup,nodeVersion:'24.19.0',platform:'darwin',arch:'arm64'};
const byId=(report,id)=>report.checks.find(check=>check.id===id);

test('healthy Mac checks remain explicitly separate from phone and AI verification',async()=>{
  const report=await collectDiagnostics(options);
  assert.equal(report.summary.pass,12);
  assert.equal(report.summary.fail+report.summary.warning+report.summary.unknown,0);
  assert.match(report.scope,/does not verify the iPhone connection, provider key or an AI task/);
  assert.match(formatDiagnostics(report),/PASS: Nova Core/);
});

test('a healthy HTTP listener must be Nova Core and reject unpaired requests',async()=>{
  const wrong=await collectDiagnostics({...options,fetchImpl:async()=>Response.json({service:'another-service',ready:true})});
  assert.equal(byId(wrong,'core').status,'fail');
  assert.equal(byId(wrong,'local-auth').status,'unknown');
  const unprotected=await collectDiagnostics({...options,fetchImpl:async url=>url.endsWith('/v1/health')?fetchOK(url):Response.json({connected:true})});
  assert.equal(byId(unprotected,'core').status,'pass');
  assert.equal(byId(unprotected,'local-auth').status,'fail');
  assert.equal(byId(unprotected,'private-route').status,'fail');
});

test('requests contain no credentials and refuse redirects',async()=>{
  const seen=[];
  await collectDiagnostics({...options,fetchImpl:async(url,init)=>{seen.push({url,init});return fetchOK(url);}});
  assert.equal(seen.length,4);
  for(const {url,init} of seen){
    assert.ok(url.endsWith('/v1/health')||url.endsWith('/v1/status'));
    assert.equal(init.redirect,'error');
    assert.equal(init.headers,undefined);
    assert.equal(init.body,undefined);
    assert.ok(init.signal instanceof AbortSignal);
  }
});

test('an auth probe timeout does not misreport a healthy Core as stopped',async()=>{
  const report=await collectDiagnostics({...options,fetchImpl:async url=>{
    if(url.endsWith('/v1/status'))throw new Error('timeout');
    return fetchOK(url);
  }});
  assert.equal(byId(report,'core').status,'pass');
  assert.equal(byId(report,'local-auth').status,'unknown');
  assert.match(byId(report,'local-auth').message,/could not be checked/);
  assert.equal(byId(report,'private-route').status,'fail');
});

test('an unavailable VPN and public Funnel produce useful independent failures',async()=>{
  const report=await collectDiagnostics({...options,tailStatus:async()=>({...network,running:false,funnel:true})});
  assert.equal(byId(report,'vpn').status,'fail');
  assert.match(byId(report,'vpn').hint,/same account/);
  assert.equal(byId(report,'funnel').status,'fail');
  assert.equal(byId(report,'private-route').status,'unknown');
});

test('only a credential-free private HTTPS origin can be probed remotely',async()=>{
  for(const url of ['http://private-mac.test.ts.net','https://public.example','https://test.ts.net.evil.example','https://user:secret@test.ts.net','https://test.ts.net/?secret=code','https://test.ts.net/#code','https://test.ts.net/other']){
    const seen=[];
    const report=await collectDiagnostics({...options,tailStatus:async()=>({...network,url}),fetchImpl:async(url,init)=>{seen.push(url);return fetchOK(url,init);}});
    assert.deepEqual(seen,['http://127.0.0.1:8787/v1/health','http://127.0.0.1:8787/v1/status']);
    assert.equal(byId(report,'private-route').status,'unknown');
    assert.ok(!JSON.stringify(report).includes(url));
  }
});

test('the private route must reach the right service and enforce pairing',async()=>{
  const report=await collectDiagnostics({...options,fetchImpl:async url=>url.startsWith('https:')?new Response(null,{status:502}):fetchOK(url)});
  assert.equal(byId(report,'core').status,'pass');
  assert.equal(byId(report,'private-route').status,'fail');
});

test('missing owner explains the conversation-only phone without transferring ownership',async()=>{
  const report=await collectDiagnostics({...options,inspectDatabase:()=>({...setup,ownerPaired:false})});
  assert.equal(byId(report,'owner-phone').status,'warning');
  assert.match(byId(report,'owner-phone').message,/chat-only phone cannot control/);
  assert.match(byId(report,'owner-phone').hint,/transfers control/);
  assert.equal(setup.ownerPaired,true);
});

test('Mac control distinguishes helper startup, Accessibility and Screen Recording',async()=>{
  for(const [state,text] of [[{...native,running:false},/not running/],[{...native,accessibility:false},/Accessibility/],[{...native,screenRecording:false},/Screen Recording/]]){
    const report=await collectDiagnostics({...options,permissionCheck:async()=>state});
    assert.equal(byId(report,'mac-permissions').status,'fail');
    assert.match(byId(report,'mac-permissions').message,text);
  }
  const chat=await collectDiagnostics({...options,inspectDatabase:()=>({...setup,range:'chat'}),permissionCheck:async()=>({running:false})});
  assert.equal(byId(chat,'mac-permissions').status,'pass');
  assert.match(byId(chat,'mac-permissions').message,/Just chat/);
});

test('emergency stop is reported without resuming Nova',async()=>{
  const report=await collectDiagnostics({...options,inspectDatabase:()=>({...setup,stopped:true})});
  assert.equal(byId(report,'stop-state').status,'warning');
  assert.match(byId(report,'stop-state').hint,/only when you are ready/);
});

test('reports exclude raw errors, response bodies and extra data returned by collectors',async()=>{
  const secret='PRIVATE_SENTINEL_DO_NOT_EXPORT';
  const report=await collectDiagnostics({...options,
    nodeVersion:secret,platform:secret,arch:secret,
    tailStatus:()=>{throw new Error(secret);},
    permissionCheck:async()=>{throw new Error(secret);},
    inspectDatabase:()=>({...setup,name:secret,token:secret,task:secret}),
    fetchImpl:async()=>{throw new Error(secret);}
  });
  assert.ok(!JSON.stringify(report).includes(secret));
  assert.ok(!formatDiagnostics(report).includes(secret));
  assert.equal(report.runtime.node,'unknown');
  assert.equal(byId(report,'vpn').status,'unknown');
  const raw=await collectDiagnostics({...options,tailStatus:async()=>({...network,dnsName:secret,token:secret}),permissionCheck:async()=>({...native,screenshot:secret}),fetchImpl:async()=>Response.json({error:secret})});
  assert.ok(!JSON.stringify(raw).includes(secret));
  assert.ok(!JSON.stringify(raw).includes(network.url));
});

test('missing, corrupt and old databases are handled without creating or migrating them',()=>{
  const dir=mkdtempSync(join(tmpdir(),'nova-diagnostic-'));
  try{
    const file=join(dir,'missing','nova.sqlite');
    assert.deepEqual(inspectDiagnosticDatabase(file),{state:'missing'});
    assert.equal(existsSync(join(dir,'missing')),false);
    const corrupt=join(dir,'corrupt');writeFileSync(corrupt,'not a database');
    assert.deepEqual(inspectDiagnosticDatabase(corrupt),{state:'unreadable'});
    const old=join(dir,'old.sqlite'),db=new DatabaseSync(old);db.exec('CREATE TABLE old_data(value TEXT)');db.close();
    const before=readFileSync(old);
    assert.deepEqual(inspectDiagnosticDatabase(old),{state:'unreadable'});
    assert.deepEqual(readFileSync(old),before);
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('saved setup is read without leaking identities, mutating records or relaxing permissions',()=>{
  const dir=mkdtempSync(join(tmpdir(),'nova-diagnostic-'));
  try{
    const file=join(dir,'nova.sqlite'),store=new Store(file);
    const invitation=store.createInvitation({owner:true}),device=store.redeemInvitation(invitation.code,'PRIVATE_PHONE_NAME');
    store.setSetting('access_level','full');
    const beforeSettings=store.db.prepare('SELECT * FROM settings ORDER BY key').all();
    const beforeInvites=store.db.prepare('SELECT * FROM invitations').all();
    const state=inspectDiagnosticDatabase(file);
    assert.deepEqual(state,{state:'ok',privateFile:true,paired:true,ownerPaired:true,range:'full',stopped:false});
    assert.deepEqual(store.db.prepare('SELECT * FROM settings ORDER BY key').all(),beforeSettings);
    assert.deepEqual(store.db.prepare('SELECT * FROM invitations').all(),beforeInvites);
    assert.ok(!JSON.stringify(state).includes('PRIVATE_PHONE_NAME'));
    assert.ok(!JSON.stringify(state).includes(device.token));
    store.revokeDevice(device.id);
    assert.equal(inspectDiagnosticDatabase(file).ownerPaired,false);
    chmodSync(file,0o644);assert.equal(inspectDiagnosticDatabase(file).privateFile,false);
    store.close();
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('a real loopback Core passes the unauthenticated health and auth checks without a paid request',async()=>{
  const dir=mkdtempSync(join(tmpdir(),'nova-diagnostic-http-'));
  const core=makeNova({dbFile:join(dir,'nova.sqlite'),setupOptions:{keyStore:memoryKeyStore()},computerOptions:{permissionCheck:async()=>native}});
  try{
    const port=await core.listen(0);
    const report=await collectDiagnostics({...options,port,fetchImpl:fetch});
    assert.equal(byId(report,'core').status,'pass');
    assert.equal(byId(report,'local-auth').status,'pass');
    assert.equal(core.store.db.prepare('SELECT COUNT(*) AS n FROM jobs').get().n,0);
  }finally{await core.close();rmSync(dir,{recursive:true,force:true});}
});

test('invalid runtime and port settings fail safely',async()=>{
  const old=await collectDiagnostics({...options,nodeVersion:'22.12.0'});
  assert.equal(byId(old,'runtime').status,'fail');
  for(const port of [NaN,0,65536,8787.5])await assert.rejects(collectDiagnostics({...options,port}),/invalid local port/);
});
