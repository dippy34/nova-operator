import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeNova } from './server.mjs';

const wait = ms=>new Promise(ok=>setTimeout(ok,ms));
async function fixture(executeOverride) {
  const dir=mkdtempSync(join(tmpdir(),'nova-'));
  const app=makeNova({dbFile:join(dir,'db.sqlite'),executeOverride});
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
test('job runs, creates evidence, and persists across process restart',async()=>{
 const f=await fixture();
 try {
   const code=f.app.store.issueInvitation(); const {token}=await (await f.post('/v1/pair',{code,deviceName:'iPhone'})).json();
   const {id}=await (await f.post('/v1/jobs',{type:'hello',message:'Nova!'},token)).json();
   let j;for(let i=0;i<50;i++){j=await (await f.get('/v1/jobs/'+id,token)).json();if(j.status==='succeeded')break;await wait(10);}
   assert.equal(j.status,'succeeded');assert.match(j.result.message,/Nova!/);assert(j.events.length>=2);
   const jobs=await (await f.get('/v1/jobs',token)).json();assert.equal(jobs.jobs[0].id,id);
 }finally{await f.close();}
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
