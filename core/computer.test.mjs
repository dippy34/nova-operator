import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {Store} from './db.mjs';
import {createComputer,validateAction,signedEnvelope} from './computer.mjs';
import {createHmac} from 'node:crypto';
import {planComputer} from './claude-worker.mjs';
import {makeNova} from './server.mjs';

function fixture(options={}){
 const dir=mkdtempSync(join(tmpdir(),'nova-control-')),store=new Store(join(dir,'db'));
 const owner=store.redeemInvitation(store.issueInvitation(),'owner'),other=store.redeemInvitation(store.issueInvitation(),'other');
 store.db.prepare("INSERT INTO settings(key,value) VALUES('computer_owner',?)").run(owner.id);
 let now=100000,calls=[];
 let step=0;
 const ai={computer:async()=>({costMicros:1,estimatedUSD:.000001,action:step++===0?{kind:'click',x:500,y:500}:{kind:'done',message:'Visible result'}})};
 const run=async request=>{calls.push(request);return request.kind==='observe'?{snapshot:'immutable-screen',png:'cG5n'}:{message:'input delivered'};};
 const control=createComputer(store,ai,{run,clock:()=>now,permissionCheck:async()=>({accessibility:true,screenRecording:true}),...options});
 return {store,owner,other,control,calls,setTime:value=>now=value,close(){store.close();rmSync(dir,{recursive:true,force:true});}};
}
const signal=()=>new AbortController().signal;
test('model outputs cannot select another app, shell, arbitrary keys, or out-of-window input',()=>{
 for(const input of [{kind:'exec',command:'whoami'},{kind:'click',x:1,y:500},{kind:'click',x:500,y:500,app:'Terminal'},{kind:'key',key:'cmd+space'},{kind:'type',text:'line\nreturn'},{kind:'type',text:'a'.repeat(501)},null])assert.throws(()=>validateAction(input));
 assert.deepEqual(validateAction({kind:'type',text:'Hello Nova'}),{kind:'type',text:'Hello Nova'});
});
test('owner session and review are required before any input, and approvals cannot replay',async()=>{
 const f=fixture();
 try{
  await assert.rejects(f.control.start(f.other.id,'Calculator',signal()),/owner/);
  await assert.rejects(f.control.start(f.owner.id,'Terminal',signal()),/scope/);
  await assert.rejects(f.control.plan(f.owner.id,'job','click',signal()),/session/);
  await f.control.start(f.owner.id,'Calculator',signal());
  const result=await f.control.plan(f.owner.id,'job','click the button',signal());
  assert.equal(result.needsApproval,true);
  assert.deepEqual(f.calls.map(r=>r.kind),['activate','observe']);
  await assert.rejects(f.control.approve(f.other.id,'job',signal()),/owner/);
  await assert.rejects(f.control.approve(f.owner.id,'job',signal(),'wrong-action'),/another action/);
  const done=await f.control.approve(f.owner.id,'job',signal(),result.approvalID);
  assert.equal(done.message,'Visible result');
  assert.deepEqual(f.calls.map(r=>r.kind),['activate','observe','click','observe']);
  assert.equal(f.calls[2].snapshot,'immutable-screen');assert.equal(f.calls[2].app,'Calculator');
  await assert.rejects(f.control.approve(f.owner.id,'job',signal()),/already used/);
 }finally{f.close();}
});
test('expired, revoked and stopped sessions cannot dispatch input',async()=>{
 for(const kind of ['expired','revoked','stop']){
  const f=fixture();
  try{
   await f.control.start(f.owner.id,'Calculator',signal());await f.control.plan(f.owner.id,'job','task',signal());
   if(kind==='expired')f.setTime(100000+120001);
   if(kind==='revoked')f.store.revokeDevice(f.owner.id);
   if(kind==='stop'){f.store.stop();f.control.stop();}
   await assert.rejects(f.control.approve(f.owner.id,'job',signal()));
   assert.equal(f.calls.filter(r=>r.kind==='click').length,0);
  }finally{f.close();}
 }
});
test('session replacement invalidates prior actions, and screenshots are owner-only',async()=>{
 const f=fixture();try{
  await f.control.start(f.owner.id,'Calculator',signal());await f.control.plan(f.owner.id,'job','task',signal());
  assert.equal(f.control.screen(f.owner.id,'job').toString(),'png');
  assert.throws(()=>f.control.screen(f.other.id,'job'));
  await f.control.start(f.owner.id,'TextEdit',signal());
  await assert.rejects(f.control.approve(f.owner.id,'job',signal()));
  assert.equal(f.calls.some(r=>r.kind==='click'),false);
 }finally{f.close();}
});
test('uncertain or stale input is never automatically retried',async()=>{
 const attempts=[];const f=fixture({run:async r=>{attempts.push(r.kind);if(r.kind==='click')throw new Error('Stale snapshot');return r.kind==='observe'?{snapshot:'old',png:'cG5n'}:{};}});
 try{
  await f.control.start(f.owner.id,'Calculator',signal());const proposal=await f.control.plan(f.owner.id,'job','task',signal());
  await assert.rejects(f.control.approve(f.owner.id,'job',signal(),proposal.approvalID),/Stale/);
  await assert.rejects(f.control.approve(f.owner.id,'job',signal()),/already used/);
  assert.equal(attempts.filter(k=>k==='click').length,1);
 }finally{f.close();}
});
test('action envelope authenticates exact arguments and has short expiry',()=>{
 const key=Buffer.alloc(32,7),envelope=signedEnvelope({kind:'type',app:'TextEdit',text:'reviewed'},key,100000);
 const payload=Buffer.from(envelope.payload,'base64');
 assert.equal(envelope.mac,createHmac('sha256',key).update(payload).digest('base64'));
 assert.equal(JSON.parse(payload).expires,105);assert.match(JSON.parse(payload).nonce,/^[a-f0-9]{32}$/);
 const modified=Buffer.from(payload.toString().replace('reviewed','changed'));
 assert.notEqual(envelope.mac,createHmac('sha256',key).update(modified).digest('base64'));
});
test('screen planner receives an image and returns proposals only, never an execution interface',async()=>{
 const result=await planComputer({app:'Calculator',task:'2 + 2',previous:[],image:'cG5n'},{key:'fake',fetchImpl:async(url,options)=>{
  const body=JSON.parse(options.body);assert.equal(options.redirect,'error');assert.equal(body.tools.length,1);
  assert.equal(body.tools[0].name,'computer_action');assert.equal(body.messages[0].content[1].type,'image');
  return Response.json({content:[{type:'tool_use',name:'computer_action',input:{kind:'key',key:'return'}}],usage:{input_tokens:1000,output_tokens:20}});
 }});
 assert.deepEqual(result.action,{kind:'key',key:'return'});assert.equal(result.costMicros,110);
});
test('HTTP approvals bind the exact proposal; simultaneous and old approvals cannot execute again',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'nova-control-http-'));let clicks=0,proposals=0;
 const app=makeNova({dbFile:join(dir,'db'),aiOptions:{configured:()=>true,request:async()=>({costMicros:1,action:proposals++<2?{kind:'click',x:500,y:500}:{kind:'done',message:'finished'}})},computerOptions:{permissionCheck:async()=>({accessibility:true,screenRecording:true}),run:async r=>{if(r.kind==='click')clicks++;return r.kind==='observe'?{snapshot:'screen',png:'cG5n'}:{};}}});
 try{
  const port=await app.listen(0),owner=app.store.redeemInvitation(app.store.issueInvitation(),'owner');
  app.store.db.prepare("INSERT INTO settings(key,value) VALUES('computer_owner',?)").run(owner.id);
  const post=(path,body)=>fetch(`http://127.0.0.1:${port}${path}`,{method:'POST',headers:{authorization:`Bearer ${owner.token}`,'content-type':'application/json'},body:JSON.stringify(body)});
  assert.equal((await post('/v1/computer/session',{app:'Calculator'})).status,200);
  const {id}=await (await post('/v1/jobs',{type:'computer.task',message:'click twice'})).json();
  const waiting=async()=>{for(let i=0;i<100;i++){const j=app.store.getJob(id,owner.id);if(j.status==='awaiting_approval'||j.status==='failed'||j.status==='succeeded')return j;await new Promise(ok=>setTimeout(ok,5));}throw new Error('no result');};
  let job=await waiting();assert.equal(job.status,'awaiting_approval');const first=job.result.approvalID;
  assert.equal((await post('/v1/computer/approve/'+id,{})).status,409);
  const responses=await Promise.all([post('/v1/computer/approve/'+id,{approvalID:first}),post('/v1/computer/approve/'+id,{approvalID:first})]);
  assert.deepEqual(responses.map(r=>r.status).sort(),[202,409]);
  job=await waiting();assert.equal(job.status,'awaiting_approval');assert.notEqual(job.result.approvalID,first);assert.equal(clicks,1);
  assert.equal((await post('/v1/computer/approve/'+id,{approvalID:first})).status,409);
  assert.equal(clicks,1);
  await post('/v1/stop',{});
  assert.equal((await post('/v1/computer/approve/'+id,{approvalID:job.result.approvalID})).status,423);
  assert.equal(clicks,1);
 }finally{await app.close();rmSync(dir,{recursive:true,force:true});}
});
