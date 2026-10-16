import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, statSync, writeFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeNova } from './server.mjs';
import { Store } from './db.mjs';

const wait = ms=>new Promise(ok=>setTimeout(ok,ms));
async function fixture(executeOverride, options = {}) {
  const dir=mkdtempSync(join(tmpdir(),'nova-'));
  const app=makeNova({dbFile:join(dir,'db.sqlite'),executeOverride,...options});
  const port=await app.listen(0);
  const url=`http://127.0.0.1:${port}`;
  const post=(route, body={}, token)=>fetch(url+route,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body)});
  const get=(route,token)=>fetch(url+route,{headers:token?{authorization:`Bearer ${token}`}:{}});
  return {app,dir,url,post,get,close:async()=>{await app.close();rmSync(dir,{recursive:true,force:true});}};
}
test('pairing is one use, auth is required, commands are restricted',async()=>{
  const f=await fixture();
  try {
    assert.equal((await f.get('/v1/jobs')).status,401);
    const code=f.app.store.issueInvitation();
    const p=await f.post('/v1/pair',{code,deviceName:'My iPhone'});
    assert.equal(p.status,201);const {token}=await p.json();
    assert.equal((await f.post('/v1/pair',{code,deviceName:'Second device'})).status,403);
    assert.equal((await f.post('/v1/jobs',{type:'shell.exec',command:'rm -rf /'},token)).status,400);
    assert.equal((await f.get('/v1/status',token)).status,200);
  } finally {await f.close();}
});
test('job runs and creates evidence',async()=>{
 const f=await fixture();
 try {
   const code=f.app.store.issueInvitation(); const {token}=await (await f.post('/v1/pair',{code,deviceName:'iPhone'})).json();
   const {id}=await (await f.post('/v1/jobs',{type:'hello',message:'Nova!'},token)).json();
   let j;for(let i=0;i<50;i++){j=await (await f.get('/v1/jobs/'+id,token)).json();if(j.status==='succeeded')break;await wait(10);}
   assert.equal(j.status,'succeeded');assert.match(j.result.message,/Nova!/);assert(j.events.length>=2);
   const jobs=await (await f.get('/v1/jobs',token)).json();assert.equal(jobs.jobs[0].id,id);
 }finally{await f.close();}
});

test('credentials, results and emergency stop survive reopening; unfinished jobs are interrupted', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'nova-restart-'));
  const dbFile = join(dir, 'db.sqlite');
  let app = makeNova({dbFile});
  try {
    await app.listen(0);
    const credential = app.store.redeemInvitation(app.store.issueInvitation(), 'iPhone');
    const done = app.store.createJob(credential.id, 'hello', {message:'saved'});
    app.store.updateJob(done, 'succeeded', {message:'saved result'});
    const unfinished = app.store.createJob(credential.id, 'mac.status', {});
    app.store.updateJob(unfinished, 'running');
    app.store.stop();
    await app.close();
    app = makeNova({dbFile});
    await app.listen(0);
    assert.equal(app.store.auth(credential.token).id, credential.id);
    assert.equal(app.store.getJob(done, credential.id).result.message, 'saved result');
    assert.equal(app.store.getJob(unfinished, credential.id).status, 'interrupted');
    assert.equal(app.store.stopped(), true);
    assert.equal(statSync(dbFile).mode & 0o777, 0o600);
    app.store.resume();
    assert.equal(app.store.stopped(), false);
  } finally { await app.close(); rmSync(dir, {recursive:true, force:true}); }
});

test('a pairing CLI or failed second listener cannot interrupt the live instance', async () => {
  const f = await fixture();
  const dbFile = join(f.dir, 'db.sqlite');
  let second;
  try {
    const credential = f.app.store.redeemInvitation(f.app.store.issueInvitation(), 'iPhone');
    const id = f.app.store.createJob(credential.id, 'hello', {});
    f.app.store.updateJob(id, 'running');
    const cli = new Store(dbFile);
    cli.issueInvitation(); cli.close();
    second = makeNova({dbFile});
    await assert.rejects(second.listen(Number(new URL(f.url).port)), {code:'EADDRINUSE'});
    assert.equal(f.app.store.getJob(id, credential.id).status, 'running');
  } finally { if (second) await second.close(); await f.close(); }
});

test('expired invitations, cross-device jobs and revoked tokens are rejected', async () => {
  const f = await fixture();
  try {
    const expired = f.app.store.issueInvitation();
    f.app.store.db.prepare('UPDATE invitations SET expires_ms=0').run();
    assert.equal((await f.post('/v1/pair', {code:expired, deviceName:'Late'})).status, 403);
    const a = f.app.store.redeemInvitation(f.app.store.issueInvitation(), 'A');
    const b = f.app.store.redeemInvitation(f.app.store.issueInvitation(), 'B');
    const {id} = await (await f.post('/v1/jobs', {type:'hello'}, a.token)).json();
    assert.equal((await f.get('/v1/jobs/' + id, b.token)).status, 404);
    assert.deepEqual((await (await f.get('/v1/jobs', b.token)).json()).jobs, []);
    assert.equal(f.app.store.revokeDevice(a.id), true);
    assert.equal((await f.get('/v1/status', a.token)).status, 401);
    assert.equal((await f.get('/v1/status', b.token)).status, 200);
  } finally { await f.close(); }
});

test('shutdown waits for active cancellation before closing SQLite and can be repeated', async () => {
  let started;
  const ready = new Promise(ok => started = ok);
  const f = await fixture(async (type, payload, signal) => {
    started();
    await new Promise(ok => signal.addEventListener('abort', ok, {once:true}));
    await wait(25);
    throw new Error('Cancelled');
  });
  try {
    const {token} = f.app.store.redeemInvitation(f.app.store.issueInvitation(), 'iPhone');
    const {id} = await (await f.post('/v1/jobs', {type:'hello'}, token)).json();
    await ready;
    await Promise.all([f.app.close(), f.app.close()]);
    const reopened = new Store(join(f.dir, 'db.sqlite'));
    try { assert.equal(reopened.db.prepare('SELECT status FROM jobs WHERE id=?').get(id).status, 'cancelled'); }
    finally { reopened.close(); }
  } finally { await f.close(); }
});

test('public listening addresses are prohibited', async () => {
  const f = await fixture();
  try { await assert.rejects(f.app.listen(0, '0.0.0.0'), /loopback/); }
  finally { await f.close(); }
});

test('repository status never invokes configured fsmonitor hooks or modifies the index', async () => {
  const workspace = mkdtempSync(join(tmpdir(), 'nova-repo-'));
  const git = (...args) => execFileSync('git', args, {cwd:workspace, stdio:'pipe'});
  git('init');
  writeFileSync(join(workspace, 'tracked.txt'), 'safe\n');
  git('add', 'tracked.txt');
  const indexBefore = statSync(join(workspace, '.git/index')).mtimeMs;
  writeFileSync(join(workspace,'monitor.sh'), '#!/bin/sh\ntouch hook-ran\nprintf "token\\0"\n', {mode:0o700});
  git('config', 'core.fsmonitor', './monitor.sh');
  const f = await fixture(undefined, {workspace});
  try {
    const {token} = f.app.store.redeemInvitation(f.app.store.issueInvitation(), 'iPhone');
    const {id} = await (await f.post('/v1/jobs',{type:'repo.status'},token)).json();
    let job;
    for(let i=0;i<100;i++) {
      job = await (await f.get('/v1/jobs/'+id,token)).json();
      if (!['queued','running'].includes(job.status)) break;
      await wait(10);
    }
    assert.equal(job.status,'succeeded');
    assert.match(job.result.output,/tracked.txt/);
    assert.equal(existsSync(join(workspace,'hook-ran')),false);
    assert.equal(statSync(join(workspace,'.git/index')).mtimeMs,indexBefore);
  } finally {await f.close();rmSync(workspace,{recursive:true,force:true});}
});
test('remote emergency stop aborts in-flight task, blocks new requests, local resume works',async()=>{
  let started;const signalStarted=new Promise(ok=>started=ok);
  const f=await fixture(async(type,payload,signal)=>{started();return await new Promise((ok,reject)=>signal.addEventListener('abort',()=>reject(new Error('Aborted')),{once:true}));});
  try {
    const code=f.app.store.issueInvitation();const {token}=await(await f.post('/v1/pair',{code,deviceName:'iPhone'})).json();
    const {id}=await(await f.post('/v1/jobs',{type:'hello',message:'work'},token)).json();
    await signalStarted;
    assert.equal((await f.post('/v1/stop',{},token)).status,200);
    assert.equal((await f.post('/v1/jobs',{type:'hello',message:'again'},token)).status,423);
    await wait(20);const j=await(await f.get('/v1/jobs/'+id,token)).json();assert.equal(j.status,'cancelled');
    f.app.store.resume();assert.equal((await f.get('/v1/status',token)).status,200);
  }finally{await f.close();}
});
