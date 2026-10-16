import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from './db.mjs';
import { makeNova } from './server.mjs';
import { createAI, AI_BUDGET_MICROS, RESERVATION_MICROS, callWorker } from './ai.mjs';
import { askClaude, MODEL } from './claude-worker.mjs';

const signal = () => new AbortController().signal;
function fixture() {
  const dir = mkdtempSync(join(tmpdir(),'nova-ai-'));
  const file = join(dir,'db');
  const store = new Store(file);
  return {file,store,close(){store.close();rmSync(dir,{recursive:true,force:true});}};
}
test('Claude request has no tools, redirects, retries or unbounded output; usage is priced', async () => {
  let calls = 0;
  const result = await askClaude([{role:'user',content:'hi'}], {key:'fake-key',signal:signal(),fetchImpl:async(url,options)=>{
    calls++;
    assert.equal(url,'https://api.anthropic.com/v1/messages');
    assert.equal(options.redirect,'error');
    const body = JSON.parse(options.body);
    assert.equal(body.model,MODEL); assert.equal(body.max_tokens,512); assert.equal(body.tools,undefined);
    assert.deepEqual(body.thinking,{type:'disabled'});
    return Response.json({content:[{type:'text',text:'Hello Matthew'}],usage:{input_tokens:100,output_tokens:50},stop_reason:'end_turn'});
  }});
  assert.equal(calls,1); assert.equal(result.costMicros,35); assert.equal(result.message,'Hello Matthew');
  await assert.rejects(askClaude([], {key:'fake',fetchImpl:async()=>new Response('secret echoed by provider',{status:401})}),/^Error: AUTH$/);
  await assert.rejects(askClaude([], {key:'fake',fetchImpl:async()=>Response.json({usage:{input_tokens:1,output_tokens:9999}})}),/USAGE/);
});
test('AI spend persists and there is no allowance to run out', async () => {
  const f = fixture(); let calls = 0;
  try {
    const ai = createAI(f.store,{configured:()=>true, request:async()=>{calls++;return {message:'ok',costMicros:20};}});
    assert.equal(f.store.reserveAI('past',1_000_000_000,AI_BUDGET_MICROS),true);
    await ai.chat('last','phone','hi',signal());
    await ai.chat('again','phone','hi',signal());
    assert.equal(calls,2);
    assert.equal(ai.status().allowanceUSD,null);
    const reopened = new Store(f.file);
    assert.equal(reopened.aiSpent(),1_000_000_040); reopened.close();
  } finally {f.close();}
});
test('uncertain outcomes retain reservation and concurrent requests cannot spend in parallel', async () => {
  const f = fixture(); let release;
  const ai = createAI(f.store,{configured:()=>true,request:()=>new Promise((ok,reject)=>{release=()=>reject(new Error('timeout'));})});
  try {
    const first = ai.chat('first','a','hi',signal());
    await assert.rejects(ai.chat('second','b','hi',signal()),/already answering/);
    release(); await assert.rejects(first,/timeout/);
    assert.equal(f.store.aiSpent(),RESERVATION_MICROS);
    assert.equal(ai.status().busy,false);
    const missing = createAI(f.store,{configured:()=>false});
    await assert.rejects(missing.chat('missing','a','hi',signal()),/API key/);
    assert.equal(f.store.aiSpent(),RESERVATION_MICROS);
  } finally {f.close();}
});
test('history is bounded and isolated by device; only successful chats go to Claude', () => {
  const f = fixture();
  try {
    for(let i=0;i<5;i++) {
      const id=f.store.createJob('a','ai.chat',{message:'question'+i});
      f.store.updateJob(id,'succeeded',{message:'answer'+i});
    }
    const other=f.store.createJob('b','ai.chat',{message:'private'});
    f.store.updateJob(other,'succeeded',{message:'other device'});
    const repo=f.store.createJob('a','repo.status',{}); f.store.updateJob(repo,'succeeded',{message:'private files'});
    assert.deepEqual(f.store.aiHistory('a').map(m=>m.content),['question3','answer3','question4','answer4']);
  } finally {f.close();}
});
test('authenticated AI jobs reject oversize input and emergency stop aborts without refunding unknown spend', async () => {
  const f = fixture(); let started;
  const ready = new Promise(ok=>started=ok);
  const app = makeNova({dbFile:f.file,aiOptions:{configured:()=>true,request:async(messages,signal)=>{
    started(); await new Promise((ok,reject)=>signal.addEventListener('abort',()=>reject(new Error('cancelled')),{once:true}));
  }}});
  try {
    const port=await app.listen(0);
    const {token}=app.store.redeemInvitation(app.store.issueInvitation(),'phone');
    const post=(path,body,auth=token)=>fetch(`http://127.0.0.1:${port}${path}`,{method:'POST',headers:{authorization:`Bearer ${auth}`,'content-type':'application/json'},body:JSON.stringify(body)});
    assert.equal((await post('/v1/jobs',{type:'ai.chat',message:'hi'},'wrong')).status,401);
    assert.equal((await post('/v1/jobs',{type:'ai.chat',message:'x'.repeat(2001)})).status,400);
    const {id}=await (await post('/v1/jobs',{type:'ai.chat',message:'hi'})).json();
    await ready; await post('/v1/stop',{}); await app.close();
    assert.equal(f.store.getJob(id,f.store.devices()[0].id).status,'cancelled');
    assert.equal(f.store.aiSpent(),RESERVATION_MICROS);
  } finally {await app.close();f.close();}
});
test('already cancelled worker never starts',async()=>{
  const controller=new AbortController();controller.abort();
  await assert.rejects(callWorker([],controller.signal),/cancelled/);
});
