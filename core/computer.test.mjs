import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHmac} from 'node:crypto';
import {Store} from './db.mjs';
import {createComputer,signedEnvelope,TURN_RESERVATION_MICROS} from './computer.mjs';
import {AGENT_MODEL,TOOLSET,agentCost,callClaude} from './agent.mjs';
import {makeNova} from './server.mjs';
import {memoryKeyStore} from './keys.mjs';
import {OPENAI_MODEL,openaiCost} from './openai.mjs';

const FULL={mode:'full'};

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
 store.setSetting('access_level',options.level??'full');
 if(options.apps)store.setSetting('access_apps',JSON.stringify(options.apps));
 const calls=[],bodies=[],replies=options.replies??script();
 const run=async request=>{calls.push(request);return request.action==='screenshot'?{image:'anBn',width:1366,height:888}:{text:'OK'};};
 const call=async body=>{bodies.push(structuredClone(body));const reply=replies.shift();if(!reply)throw new Error('no more replies');return reply;};
 const control=createComputer(store,{run,call,keyStore:memoryKeyStore(),permissionCheck:async()=>({installed:true,running:true,accessibility:true,screenRecording:true}),...options});
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
  assert.deepEqual(f.calls,[{action:'begin'},{action:'screenshot',scope:FULL},{action:'left_click',coordinate:[40,50],scope:FULL}]);
  const [first,second]=f.bodies;
  assert.equal(first.model,AGENT_MODEL);assert.deepEqual(first.tools.map(t=>t.type??t.name),[TOOLSET,'web_search_20260318','web_fetch_20260318','show']);
  assert.match(first.system,/Range: Whole Mac\.$/);
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
  assert.deepEqual(f.calls,[{action:'screenshot',scope:FULL}]);assert.equal(f.bodies.length,0);
 }finally{f.close();}
});
test('every turn is metered with no spending cap, and empty credits are explained',async()=>{
 const f=fixture();
 try{
  f.store.reserveAI('earlier',50_000_000_000,Number.POSITIVE_INFINITY);
  const id=f.store.createJob(f.owner.id,'computer.task',{message:'press 7'});
  await f.control.task(f.owner.id,id,'press 7',signal());
  assert.equal(f.store.aiSpent(),50_000_000_000+2*agentCost(usage));
  assert.equal(agentCost({...usage,server_tool_use:{web_search_requests:3}}),agentCost(usage)+30_000);
  const fetchImpl=async()=>Response.json({type:'error',error:{type:'invalid_request_error',message:'Your credit balance is too low to access the Anthropic API.'}},{status:400});
  await assert.rejects(callClaude({},{signal:signal(),fetchImpl,key:'k'}),/credits ran out/);
 }finally{f.close();}
});
test('taking over sends direct input, holds off background work and is validated',async()=>{
 const f=fixture();
 try{
  await f.control.input(f.owner.id,{action:'left_click',coordinate:[100.4,200.6]});
  assert.deepEqual(f.calls,[{action:'begin'},{action:'left_click',direct:true,coordinate:[100,201],scope:FULL}]);
  assert.equal(f.control.controlled(),true);
  await assert.rejects(f.control.task(f.owner.id,'job-000000000003','check mail',signal(),'schedule-x',{background:true}),/controlling the Mac/);
  for(const bad of [{action:'shell',text:'ls'},{action:'left_click'},{action:'key',text:'cmd+$(rm)'},{action:'type',text:''},{action:'scroll',coordinate:[1,1],scroll_direction:'sideways'}])
   await assert.rejects(f.control.input(f.owner.id,bad));
  await assert.rejects(f.control.input(f.other.id,{action:'left_click',coordinate:[1,1]}),/owner/);
  await f.control.input(f.owner.id,{action:'scroll',coordinate:[5,5],scroll_direction:'down',scroll_amount:99});
  assert.deepEqual(f.calls.at(-1),{action:'scroll',direct:true,coordinate:[5,5],scroll_direction:'down',scroll_amount:15,scope:FULL});
  f.control.release(f.owner.id);
  assert.equal(f.control.controlled(),false);
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
 const app=makeNova({dbFile:join(dir,'db'),setupOptions:{keyStore:memoryKeyStore()},computerOptions:{
  permissionCheck:async()=>({installed:true,running:true,accessibility:true,screenRecording:true}),
  run:async()=>({text:'OK'}),
  call:async(body,{signal})=>{await Promise.race([gate,new Promise((_,fail)=>signal.addEventListener('abort',()=>fail(new Error('Task cancelled'))))]);return {stop_reason:'end_turn',usage,content:[{type:'text',text:'Hi Matthew.'}]};}}});
 try{
  const port=await app.listen(0),owner=app.store.redeemInvitation(app.store.issueInvitation(),'owner');
  app.store.db.prepare("INSERT INTO settings(key,value) VALUES('computer_owner',?)").run(owner.id);
  app.store.setSetting('access_level','full');
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

test('Just chat runs without the Mac: no permission check, no computer tool and no remote control',async()=>{
 const replies=[{stop_reason:'tool_use',usage,content:[toolUse('t1','screenshot')]},{stop_reason:'end_turn',usage,content:[{type:'text',text:'I can only chat.'}]}];
 let checked=false;
 const f=fixture({level:'chat',replies,permissionCheck:async()=>{checked=true;return {installed:false};}});
 try{
  assert.equal((await f.control.task(f.owner.id,'job-000000000001','open mail',signal())).message,'I can only chat.');
  assert.equal(checked,false);
  assert.ok(!f.bodies[0].tools.some(t=>t.type===TOOLSET));
  assert.match(f.bodies[0].system,/Range: Just chat/);
  // Even if the model asks for the computer anyway, the action is refused before it reaches the Mac.
  assert.match(f.bodies[1].messages.at(-1).content[0].content[0].text,/Just chat/);
  await assert.rejects(f.control.live(f.owner.id),/Just chat/);
  await assert.rejects(f.control.input(f.owner.id,{action:'left_click',coordinate:[1,1]}),/Just chat/);
  assert.throws(()=>f.control.takeOver(f.owner.id),/Just chat/);
  await assert.rejects(f.control.task(f.owner.id,'job-000000000002','check mail',signal(),'schedule-x',{background:true}),/Just chat/);
  assert.deepEqual(f.calls,[]);
 }finally{f.close();}
});
test('Chosen apps: the scope is signed into every action, global shortcuts are refused and open_app opens only chosen apps',async()=>{
 const replies=[
  {stop_reason:'tool_use',usage,content:[toolUse('t1','key',{text:'cmd+space'}),toolUse('t2','left_click',{coordinate:[5,5]}),
   {type:'tool_use',id:'t3',name:'open_app',input:{app:'notes'}},{type:'tool_use',id:'t4',name:'open_app',input:{app:'Terminal'}}]},
  {stop_reason:'end_turn',usage,content:[{type:'text',text:'Notes is open.'}]}];
 const f=fixture({level:'apps',apps:[{bundleId:'com.apple.Notes',name:'Notes'}],replies});
 try{
  await f.control.task(f.owner.id,'job-000000000001','open notes',signal());
  const scope={mode:'apps',apps:['com.apple.Notes']};
  assert.deepEqual(f.calls,[{action:'begin'},{action:'left_click',coordinate:[5,5],scope},{action:'open_app',bundle_id:'com.apple.Notes',scope}]);
  assert.ok(f.bodies[0].tools.some(t=>t.name==='open_app'));
  assert.match(f.bodies[0].system,/only see and use these apps: Notes\./);
  const results=f.bodies[1].messages.at(-1).content;
  assert.match(results[0].content[0].text,/cmd\+space works outside the chosen apps/);
  assert.equal(results[2].content[0].text,'Opened Notes.');
  assert.match(results[3].content[0].text,/isn't one of the apps Nova may use/);
 }finally{f.close();}
});
test('a range change applies to the very next action of a running task',async()=>{
 const replies=[{stop_reason:'tool_use',usage,content:[toolUse('t1','left_click',{coordinate:[1,1]}),toolUse('t2','left_click',{coordinate:[2,2]})]},{stop_reason:'end_turn',usage,content:[{type:'text',text:'Stopped.'}]}];
 const sent=[];let f;
 f=fixture({replies,run:async request=>{sent.push(request);if(request.action==='left_click')f.store.setSetting('access_level','chat');return {text:'OK'};}});
 try{
  await f.control.task(f.owner.id,'job-000000000001','click twice',signal());
  assert.deepEqual(sent.map(c=>c.coordinate),[undefined,[1,1]]);
  assert.match(f.bodies[1].messages.at(-1).content[1].content[0].text,/Just chat/);
 }finally{f.close();}
});
test('taking over pauses Nova before its next action, and Hand back resumes it from a fresh look',async()=>{
 let open;const gate=new Promise(ok=>open=ok);
 const replies=[{stop_reason:'tool_use',usage,content:[toolUse('t1','left_click',{coordinate:[1,1]}),toolUse('t2','left_click',{coordinate:[2,2]})]},{stop_reason:'end_turn',usage,content:[{type:'text',text:'Continuing.'}]}];
 const bodies=[];
 const f=fixture({replies,call:async body=>{bodies.push(structuredClone(body));if(bodies.length===1)await gate;return replies.shift();}});
 try{
  const id=f.store.createJob(f.owner.id,'computer.task',{message:'click'});
  const running=f.control.task(f.owner.id,id,'click',signal());
  await new Promise(ok=>setTimeout(ok,10));
  assert.deepEqual(f.control.takeOver(f.owner.id),{paused:true});
  assert.equal(f.control.status(f.owner.id).paused,true);
  open();
  await new Promise(ok=>setTimeout(ok,300));
  assert.deepEqual(f.calls,[{action:'begin'}]);
  f.control.release(f.owner.id);
  assert.equal((await running).message,'Continuing.');
  assert.deepEqual(f.calls,[{action:'begin'}]);
  const results=bodies[1].messages.at(-1).content;
  assert.match(results[0].content[0].text,/handed it back/);
  assert.match(results[1].content[0].text,/Skipped because Matthew took over/);
  const kinds=f.store.events(id).map(e=>e.kind);
  assert.ok(kinds.includes('paused')&&kinds.includes('resumed'));
 }finally{f.close();}
});
test('a takeover that lapses without Hand back ends the task instead of resuming it',async()=>{
 let open;const gate=new Promise(ok=>open=ok);
 const replies=[{stop_reason:'tool_use',usage,content:[toolUse('t1','left_click',{coordinate:[1,1]})]},{stop_reason:'end_turn',usage,content:[{type:'text',text:'never'}]}];
 let n=0;
 const f=fixture({replies,controlMs:150,call:async()=>{if(n++===0)await gate;return replies.shift();}});
 try{
  const running=f.control.task(f.owner.id,'job-000000000001','click',signal());
  await new Promise(ok=>setTimeout(ok,10));
  f.control.takeOver(f.owner.id);open();
  await assert.rejects(running,/didn't hand it back/);
  assert.deepEqual(f.calls,[{action:'begin'}]);
 }finally{f.close();}
});
test('with OpenAI chosen, tasks use the OpenAI loop, translated actions, the same range checks and OpenAI pricing',async()=>{
 const usageO={input_tokens:1000,input_tokens_details:{cached_tokens:200},output_tokens:100};
 const replies=[
  {id:'r1',usage:usageO,output:[{type:'computer_call',call_id:'c1',actions:[{type:'click',button:'left',x:10,y:20},{type:'type',text:'hi'}],pending_safety_checks:[]}]},
  {id:'r2',usage:usageO,output:[{type:'message',content:[{type:'output_text',text:'Typed it.'}]}]}];
 const bodies=[];
 const f=fixture({keyStore:memoryKeyStore({openai:'sk-test-000000000000000000000000'}),openai:{call:async body=>{bodies.push(structuredClone(body));return replies.shift();}}});
 f.store.setSetting('ai_provider','openai');
 try{
  const result=await f.control.task(f.owner.id,'job-000000000001','type hi',signal());
  assert.equal(result.message,'Typed it.');assert.equal(f.bodies.length,0);
  assert.equal(bodies[0].model,OPENAI_MODEL);assert.deepEqual(bodies[0].tools.slice(0,2),[{type:'computer'},{type:'web_search'}]);
  assert.match(bodies[0].instructions,/Range: Whole Mac/);
  assert.equal(bodies[1].previous_response_id,'r1');assert.equal(bodies[1].input[0].type,'computer_call_output');
  assert.deepEqual(f.calls,[{action:'begin'},{action:'left_click',coordinate:[10,20],scope:FULL},{action:'type',text:'hi',scope:FULL},{action:'screenshot',scope:FULL}]);
  assert.equal(f.store.aiSpent(),2*openaiCost({usage:usageO}));
  assert.equal(openaiCost({usage:usageO}),800*2+200*0.1+100*10);
 }finally{f.close();}
});
