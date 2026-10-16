import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHmac} from 'node:crypto';
import {Store} from './db.mjs';
import {createComputer,signedEnvelope,TURN_RESERVATION_MICROS} from './computer.mjs';
import {AGENT_MODEL,TOOLSET,agentCost} from './agent.mjs';
import {AI_BUDGET_MICROS} from './ai.mjs';
import {makeNova} from './server.mjs';

const usage={input_tokens:1000,cache_creation_input_tokens:2000,cache_read_input_tokens:10000,output_tokens:200};
const toolUse=(id,name,input={})=>({type:'tool_use',id,name,toolset_name:'computer',input});
// Claude asks for a screenshot and a click, then answers.
const script=()=>[
  {stop_reason:'tool_use',usage,content:[{type:'text',text:'Opening Calculator.'},toolUse('t1','screenshot'),toolUse('t2','left_click',{coordinate:[40,50],extra:'dropped'})]},
  {stop_reason:'end_turn',usage,content:[{type:'text',text:'Done, it shows 7.'}]}
];
function fixture(options={}){
 const dir=mkdtempSync(join(tmpdir(),'nova-control-')),store=new Store(join(dir,'db'));
 const owner=store.redeemInvitation(store.issueInvitation(),'owner'),other=store.redeemInvitation(store.issueInvitation(),'other');
 store.db.prepare("INSERT INTO settings(key,value) VALUES('computer_owner',?)").run(owner.id);
 const calls=[],bodies=[],replies=options.replies??script();
 const run=async request=>{calls.push(request);return request.action==='screenshot'?{image:'anBn',width:1366,height:888}:{text:'OK'};};
 const call=async body=>{bodies.push(structuredClone(body));const reply=replies.shift();if(!reply)throw new Error('no more replies');return reply;};
 const control=createComputer(store,{run,call,permissionCheck:async()=>({installed:true,running:true,accessibility:true,screenRecording:true}),...options});
 return {store,owner,other,control,calls,bodies,close(){store.close();rmSync(dir,{recursive:true,force:true});}};
}
const signal=()=>new AbortController().signal;

test('missing permission is named precisely and nothing reaches the Mac',async()=>{
 for(const [permission,expected,other] of [[{accessibility:true,screenRecording:false},'needs Screen Recording','needs Accessibility'],[{accessibility:false,screenRecording:true},'needs Accessibility','needs Screen Recording'],[{installed:true,running:false},'not running','needs']]){
  const f=fixture({permissionCheck:async()=>({installed:true,...permission})});
  try{
   await assert.rejects(f.control.task(f.owner.id,'job-000000000001','press 7',signal()),error=>error.message.includes(expected)&&!error.message.includes(other));
   assert.equal(f.calls.length,0);assert.equal(f.bodies.length,0);
  }finally{f.close();}
 }
});
test('only the owner iPhone can run tasks, and emergency stop blocks them',async()=>{
 const f=fixture();
 try{
  await assert.rejects(f.control.task(f.other.id,'job-000000000001','press 7',signal()),/owner/);
  f.store.stop();
  await assert.rejects(f.control.task(f.owner.id,'job-000000000002','press 7',signal()),/emergency stopped/);
  assert.equal(f.calls.length,0);
 }finally{f.close();}
});
test('agent runs Claude computer-use calls in order without approvals and returns screenshots to Claude',async()=>{
 const f=fixture();
 try{
  const id=f.store.createJob(f.owner.id,'computer.task',{message:'press 7'});
  const result=await f.control.task(f.owner.id,id,'press 7',signal());
  assert.equal(result.message,'Done, it shows 7.');assert.equal(result.actions,1);
  assert.deepEqual(f.calls,[{action:'begin'},{action:'screenshot'},{action:'left_click',coordinate:[40,50]}]);
  const [first,second]=f.bodies;
  assert.equal(first.model,AGENT_MODEL);assert.deepEqual(first.tools.map(t=>t.type??t.name),[TOOLSET,'show']);
  assert.deepEqual(first.messages.at(-1).content.at(-1).cache_control,{type:'ephemeral'});
  const results=second.messages.at(-1).content;
  assert.equal(results[0].tool_use_id,'t1');assert.equal(results[0].toolset_name,'computer');assert.equal(results[0].content[0].type,'image');
  assert.equal(results[1].tool_use_id,'t2');assert.equal(results[1].content[0].text,'OK');
  assert.equal(result.estimatedUSD,2*agentCost(usage)/1e6);assert.equal(f.store.aiSpent(),2*agentCost(usage));
  const kinds=f.store.events(id).map(e=>e.kind);
  assert.ok(kinds.includes('narration')&&kinds.includes('action'));
  assert.deepEqual(f.control.screen(f.owner.id,id),Buffer.from('anBn','base64'));
  assert.throws(()=>f.control.screen(f.other.id,id),/owner/);
 }finally{f.close();}
});
test('show displays a visual without the computer, and the conversation remembers it',async()=>{
 const graph={type:'graph',title:'y = x^2',functions:[{expression:'x^2'}]};
 const replies=[{stop_reason:'tool_use',usage,content:[{type:'tool_use',id:'v1',name:'show',input:graph}]},{stop_reason:'end_turn',usage,content:[{type:'text',text:'Here it is.'}]},
  {stop_reason:'end_turn',usage,content:[{type:'text',text:'It is a parabola.'}]},{stop_reason:'end_turn',usage,content:[{type:'text',text:'Fresh start.'}]}];
 const f=fixture({replies});
 try{
  const id=f.store.createJob(f.owner.id,'computer.task',{message:'graph x squared'});
  assert.equal((await f.control.task(f.owner.id,id,'graph x squared',signal(),'conversation-1')).message,'Here it is.');
  assert.deepEqual(f.calls,[{action:'begin'}]);
  assert.deepEqual(JSON.parse(f.store.events(id).find(e=>e.kind==='visual').description),graph);
  assert.equal(f.bodies[1].messages.at(-1).content[0].content[0].text,"Shown on Matthew's iPhone.");
  await f.control.task(f.owner.id,f.store.createJob(f.owner.id,'computer.task',{message:'what is it'}),'what is it',signal(),'conversation-1');
  const remembered=f.bodies[2].messages;
  assert.equal(remembered[0].content,'graph x squared');assert.match(remembered[1].content,/Here it is\.[\s\S]*x\^2/);
  await f.control.task(f.owner.id,f.store.createJob(f.owner.id,'computer.task',{message:'hi'}),'hi',signal(),'conversation-2');
  assert.equal(f.bodies[3].messages.length,1);
 }finally{f.close();}
});
test('live screenshots are owner-only and never reach Claude',async()=>{
 const f=fixture();
 try{
  assert.deepEqual(await f.control.live(f.owner.id),Buffer.from('anBn','base64'));
  await assert.rejects(f.control.live(f.other.id),/owner/);
  assert.deepEqual(f.calls,[{action:'screenshot'}]);assert.equal(f.bodies.length,0);
 }finally{f.close();}
});
test('the allowance is reserved before each Claude turn and blocks once exhausted',async()=>{
 const f=fixture();
 try{
  f.store.reserveAI('earlier',AI_BUDGET_MICROS-TURN_RESERVATION_MICROS+1,AI_BUDGET_MICROS);
  await assert.rejects(f.control.task(f.owner.id,'job-000000000001','press 7',signal()),/allowance/);
  assert.equal(f.bodies.length,0);
 }finally{f.close();}
});
test('Control-Option-S on the Mac ends the task instead of being retried',async()=>{
 const f=fixture({run:async request=>{if(request.action==='begin')return {};throw new Error('Stopped on the Mac with Control-Option-S.');}});
 try{
  await assert.rejects(f.control.task(f.owner.id,'job-000000000001','press 7',signal()),/Stopped on the Mac/);
  assert.equal(f.bodies.length,1);
 }finally{f.close();}
});
test('a failed action is reported to Claude as an error so it can recover',async()=>{
 const replies=[{stop_reason:'tool_use',usage,content:[toolUse('t1','key',{text:'hyper+q'})]},{stop_reason:'end_turn',usage,content:[{type:'text',text:'That key does not exist.'}]}];
 const f=fixture({replies,run:async request=>{if(request.action==='key')throw new Error('Unknown modifier hyper');return {};}});
 try{
  const result=await f.control.task(f.owner.id,'job-000000000001','quit',signal());
  assert.equal(result.message,'That key does not exist.');
  const error=f.bodies[1].messages.at(-1).content[0];
  assert.equal(error.is_error,true);assert.match(error.content[0].text,/Unknown modifier/);
 }finally{f.close();}
});
test('action envelope authenticates exact arguments and has short expiry',()=>{
 const key=Buffer.alloc(32,7),envelope=signedEnvelope({action:'type',text:'reviewed'},key,100000);
 const payload=Buffer.from(envelope.payload,'base64');
 assert.equal(envelope.mac,createHmac('sha256',key).update(payload).digest('base64'));
 assert.equal(JSON.parse(payload).expires,105);assert.match(JSON.parse(payload).nonce,/^[a-f0-9]{32}$/);
 const modified=Buffer.from(payload.toString().replace('reviewed','changed'));
 assert.notEqual(envelope.mac,createHmac('sha256',key).update(modified).digest('base64'));
});
test('HTTP computer tasks run to completion, one at a time, and the iPhone can stop them',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'nova-control-http-'));
 let release;const gate=new Promise(ok=>release=ok);
 const app=makeNova({dbFile:join(dir,'db'),computerOptions:{
  permissionCheck:async()=>({installed:true,running:true,accessibility:true,screenRecording:true}),
  run:async()=>({text:'OK'}),
  call:async(body,{signal})=>{await Promise.race([gate,new Promise((_,fail)=>signal.addEventListener('abort',()=>fail(new Error('Task cancelled'))))]);return {stop_reason:'end_turn',usage,content:[{type:'text',text:'Hi Matthew.'}]};}}});
 try{
  const port=await app.listen(0),owner=app.store.redeemInvitation(app.store.issueInvitation(),'owner');
  app.store.db.prepare("INSERT INTO settings(key,value) VALUES('computer_owner',?)").run(owner.id);
  const post=(path,body)=>fetch(`http://127.0.0.1:${port}${path}`,{method:'POST',headers:{authorization:`Bearer ${owner.token}`,'content-type':'application/json'},body:JSON.stringify(body)});
  const settle=async id=>{for(let i=0;i<200;i++){const j=app.store.getJob(id,owner.id);if(!['queued','running'].includes(j.status))return j;await new Promise(ok=>setTimeout(ok,5));}throw new Error('no result');};
  const first=(await (await post('/v1/jobs',{type:'computer.task',message:'hello'})).json()).id;
  await new Promise(ok=>setTimeout(ok,30));
  const second=(await (await post('/v1/jobs',{type:'computer.task',message:'again'})).json()).id;
  assert.match((await settle(second)).error,/already working/);
  assert.equal((await post('/v1/computer/end',{})).status,200);
  assert.equal((await settle(first)).status,'cancelled');
  release();
  const third=(await (await post('/v1/jobs',{type:'computer.task',message:'hello'})).json()).id;
  const done=await settle(third);
  assert.equal(done.status,'succeeded');assert.equal(done.result.message,'Hi Matthew.');
 }finally{await app.close();rmSync(dir,{recursive:true,force:true});}
});
