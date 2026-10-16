import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {Store} from './db.mjs';
import {createComputer} from './computer.mjs';
import {createWork,scheduleSpec,nextRun,MAX_PARALLEL} from './work.mjs';

const usage={input_tokens:100,output_tokens:20};
const text=(t,stop='end_turn')=>({stop_reason:stop,usage,content:[{type:'text',text:t}]});
const signal=()=>new AbortController().signal;
const tick=()=>new Promise(ok=>setTimeout(ok,5));

/// `answer(body)` plays Claude: it sees each request and returns a reply.
function fixture(answer){
  const dir=mkdtempSync(join(tmpdir(),'nova-work-')),store=new Store(join(dir,'db'));
  const owner=store.redeemInvitation(store.issueInvitation(),'owner');
  store.db.prepare("INSERT INTO settings(key,value) VALUES('computer_owner',?)").run(owner.id);
  const bodies=[],calls=[],notes=[],spawned=[];
  const call=(body,{signal})=>{
    bodies.push(structuredClone(body));
    return Promise.race([answer(body,bodies.length),new Promise((ok,no)=>signal.addEventListener('abort',()=>no(new Error('Task cancelled')),{once:true}))]);
  };
  const run=async request=>{calls.push(request);return request.action==='screenshot'?{image:'anBn'}:{text:'OK'};};
  const computer=createComputer(store,{run,call,permissionCheck:async()=>({installed:true,running:true,accessibility:true,screenRecording:true})});
  const spawnImpl=(cmd,args)=>{const child={cmd,args,killed:false,on(){},kill(){child.killed=true;}};spawned.push(child);return child;};
  const work=createWork(store,computer,{call,notify:(title,message)=>notes.push({title,message}),spawnImpl,tickMs:1e9,wakeMs:0});
  return {store,owner,computer,work,bodies,calls,notes,spawned,async close(){await work.close();store.close();rmSync(dir,{recursive:true,force:true});}};
}
const lastUser=body=>body.messages.at(-1).content.map(b=>b.text??'').join('');

test('schedule times are validated and repeat correctly in local time',()=>{
  const at=new Date('2026-10-16T17:00').getTime();
  const daily=scheduleSpec({title:'News',task:'brief me',daily_at:'08:00',days:['mon','fri']},at);
  assert.equal(new Date(daily.first).toString(),new Date('2026-10-19T08:00').toString()); // Friday 5pm, so next Monday
  assert.equal(new Date(nextRun(daily.spec,daily.first)).toString(),new Date('2026-10-23T08:00').toString());
  const every=scheduleSpec({title:'Price',task:'check',every_minutes:30,monitor:true},at);
  assert.equal(every.first,at);assert.equal(nextRun(every.spec,at),at+30*60_000);
  assert.equal(scheduleSpec({title:'Once',task:'x',at:'2026-10-17T09:30'},at).first,new Date('2026-10-17T09:30').getTime());
  assert.throws(()=>scheduleSpec({title:'Old',task:'x',at:'2026-10-15T09:30'},at),/already passed/);
  assert.throws(()=>scheduleSpec({title:'Busy',task:'x',every_minutes:1,uses_computer:true},at),/every 5 minutes/);
  assert.throws(()=>scheduleSpec({title:'None',task:'x'},at),/Give a time/);
  assert.throws(()=>scheduleSpec({title:'Bad',task:'x',daily_at:'25:00'},at),/08:30/);
});

test('background agents research in parallel without the Mac and report with visuals',async()=>{
  let release;const gate=new Promise(ok=>{release=ok;});
  const chart={type:'chart',title:'Prices',kind:'bar',labels:['A','B'],series:[{values:[1,2]}]};
  const f=fixture(async(body)=>{
    if(body.messages.length===1){await gate;return {stop_reason:'tool_use',usage,content:[{type:'text',text:'Comparing.'},{type:'tool_use',id:'v1',name:'show',input:chart}]};}
    return text(`Report for ${body.messages[0].content[0].text}`);
  });
  try{
    const ids=['phones','laptops','tablets'].map(task=>f.work.startAgent(f.owner.id,{title:task,task}));
    await tick();
    assert.equal(f.work.status(f.owner.id).running.length,3);
    assert.ok(f.spawned.some(c=>c.cmd==='caffeinate'&&c.args[0]==='-is'&&!c.killed),'Mac kept awake while agents run');
    assert.equal(f.work.status(f.owner.id).awake,true);
    for(const body of f.bodies){
      assert.equal(body.tools.some(t=>t.type?.startsWith('computer_')),false);
      assert.deepEqual(body.tools.map(t=>t.name??t.type),['web_search','web_fetch','show']);
    }
    release();
    while(f.work.status(f.owner.id).running.length)await tick();
    const reports=f.work.status(f.owner.id).reports;
    assert.deepEqual(reports.map(r=>r.title).sort(),['laptops','phones','tablets']);
    assert.deepEqual(reports[0].visuals,[chart]);
    assert.equal(f.notes.length,3);
    assert.equal(f.calls.length,0,'research agents never touch the Mac');
    assert.ok(ids.every(id=>f.store.getJob(id,f.owner.id).status==='succeeded'));
    assert.ok(f.spawned.filter(c=>c.args[0]==='-is').every(c=>c.killed),'battery wake released once work is done');
    assert.ok(f.spawned.some(c=>c.args[0]==='-s'&&!c.killed),'still awake while plugged in');
  }finally{await f.close();}
});

test('at most four background agents run at once',async()=>{
  const f=fixture(()=>new Promise(()=>{}));
  try{
    for(let i=0;i<MAX_PARALLEL;i++)f.work.startAgent(f.owner.id,{title:`a${i}`,task:'x'});
    assert.throws(()=>f.work.startAgent(f.owner.id,{title:'one more',task:'x'}),/already running/);
  }finally{await f.close();}
});

test('a monitor stays quiet until something happens, then reports and ends itself',async()=>{
  const replies=['NOTHING_NEW','The price dropped to $89. STOP_MONITOR'];
  const f=fixture(async()=>text(replies.shift()));
  try{
    const {id}=f.work.addSchedule(f.owner.id,{title:'Headphones',task:'Tell me when they drop below $90',every_minutes:30,monitor:true});
    f.work.tick();
    while(f.work.status(f.owner.id).running.length||f.bodies.length<1)await tick();
    assert.equal(f.work.status(f.owner.id).reports.length,0);
    assert.match(lastUser(f.bodies[0]),/Scheduled run 1 of "Headphones".*monitor/s);
    f.store.db.prepare('UPDATE schedules SET next_ms=? WHERE id=?').run(Date.now()-1,id);
    f.work.tick();
    while(f.work.status(f.owner.id).running.length||f.bodies.length<2)await tick();
    assert.equal(f.bodies[1].messages.length,3,'the monitor remembers its previous check');
    const [report]=f.work.status(f.owner.id).reports;
    assert.equal(report.message,'The price dropped to $89.');assert.equal(report.source,'monitor');
    assert.equal(f.work.status(f.owner.id).schedules.length,0,'monitor ended');
  }finally{await f.close();}
});

test('scheduled Mac work waits for Matthew and yields to his requests',async()=>{
  let hold;
  const f=fixture(async(body)=>{
    if(lastUser(body).includes('Scheduled')&&!hold)await new Promise((ok,no)=>{hold=no;});
    return text('Checked the inbox.');
  });
  try{
    await f.computer.input(f.owner.id,{action:'left_click',coordinate:[1,1]});
    const {id}=f.work.addSchedule(f.owner.id,{title:'Inbox',task:'Check Mail',every_minutes:10,uses_computer:true});
    f.work.tick();await tick();
    assert.equal(f.work.status(f.owner.id).running.length,0,'waits while Matthew controls the Mac');
    f.computer.release(f.owner.id);
    f.work.tick();
    while(!hold)await tick();
    assert.equal(f.computer.busy().background,true);
    assert.ok(f.spawned.some(c=>c.args.join(' ')==='-u -t 5'),'display woken before using the Mac');
    const yielded=f.work.yieldComputer();
    hold(new Error('aborted'));
    await yielded;
    assert.equal(f.computer.busy(),null);
    const next=f.store.db.prepare('SELECT next_ms FROM schedules WHERE id=?').get(id).next_ms;
    assert.ok(next<=Date.now()+120_000,'retried within two minutes');
    assert.equal(f.work.status(f.owner.id).reports.length,0,'a preempted run does not report a failure');
  }finally{await f.close();}
});

test("Nova's own agent can start agents, schedule, list and cancel through its tools",async()=>{
  const f=fixture(async(body,n)=>{
    if(n===1)return {stop_reason:'tool_use',usage,content:[
      {type:'tool_use',id:'a',name:'start_agent',input:{title:'Flights',task:'Find flights to Denver'}},
      {type:'tool_use',id:'b',name:'schedule',input:{title:'Standup',task:'Remind me',daily_at:'09:00',days:['mon','tue','wed','thu','fri']}}]};
    if(body.system.startsWith("You are one of Nova's background agents"))return text('Cheapest is $120.');
    if(body.messages.at(-1).content[0].type==='tool_result')return text('Started both.');
    return text('ok');
  });
  try{
    const job=f.store.createJob(f.owner.id,'computer.task',{message:'x'});
    const {tools,onTool}=f.work.tools(f.owner.id);
    const result=await f.computer.task(f.owner.id,job,'Research flights and remind me at 9 on weekdays',signal(),'conv-12345678',{tools,onTool,prefix:f.work.context(f.owner.id)});
    assert.equal(result.message,'Started both.');
    assert.match(lastUser(f.bodies[0]),/^\[Now: /);
    assert.deepEqual(f.bodies[0].tools.map(t=>t.name??t.type).slice(-6),['start_agent','schedule','open_on_iphone','list_work','cancel_work','show']);
    const results=f.bodies.find(b=>b.messages.at(-1).content[0].type==='tool_result'&&b.tools.some(t=>t.name==='start_agent')).messages.at(-1).content;
    assert.match(results[0].content[0].text,/Started background agent/);
    assert.match(results[1].content[0].text,/daily at 09:00 \(mon, tue, wed, thu, fri\)/);
    const [schedule]=f.work.status(f.owner.id).schedules;
    assert.equal(schedule.title,'Standup');
    while(f.work.status(f.owner.id).running.length)await tick();
    assert.match(f.work.context(f.owner.id),/Flights: Cheapest is \$120/);
    assert.match(await onTool('cancel_work',{id:schedule.id}),/Deleted the schedule Standup/);
    const opener=f.work.tools(f.owner.id,job).onTool;
    assert.match(await opener('open_on_iphone',{view:'control'}),/driving now/);
    assert.deepEqual(f.store.events(job).filter(e=>e.kind==='open').map(e=>e.description),['control']);
    await assert.rejects(opener('open_on_iphone',{view:'settings'}),/Unknown view/);
    assert.equal(f.work.status(f.owner.id).schedules.length,0);
    await assert.rejects(onTool('cancel_work',{id:'nope'}),/Nothing with that id/);
  }finally{await f.close();}
});

test('emergency stop halts background agents and schedules',async()=>{
  const f=fixture(()=>new Promise(()=>{}));
  try{
    f.work.addSchedule(f.owner.id,{title:'Later',task:'x',every_minutes:60});
    const id=f.work.startAgent(f.owner.id,{title:'Long',task:'x'});
    await tick();
    f.store.stop();f.work.stop();
    while(f.work.status(f.owner.id).running.length)await tick();
    assert.equal(f.store.getJob(id,f.owner.id).status,'cancelled');
    assert.throws(()=>f.work.startAgent(f.owner.id,{title:'More',task:'x'}),/emergency stopped/);
    f.work.tick();await tick();
    assert.equal(f.work.status(f.owner.id).running.length,0);
  }finally{await f.close();}
});

test('over HTTP, taking over ends Nova\'s task, and work can be listed and cancelled',async()=>{
  const {makeNova}=await import('./server.mjs');
  const dir=mkdtempSync(join(tmpdir(),'nova-work-http-')),runs=[];
  const app=makeNova({dbFile:join(dir,'db'),
    computerOptions:{permissionCheck:async()=>({installed:true,running:true,accessibility:true,screenRecording:true}),
      run:async request=>{runs.push(request);return {text:'OK'};},
      call:(body,{signal})=>new Promise((_,no)=>signal.addEventListener('abort',()=>no(new Error('Task cancelled'))))},
    workOptions:{notify:()=>{},spawnImpl:()=>({on(){},kill(){}})}});
  try{
    const port=await app.listen(0),owner=app.store.redeemInvitation(app.store.issueInvitation(),'owner'),other=app.store.redeemInvitation(app.store.issueInvitation(),'other');
    app.store.db.prepare("INSERT INTO settings(key,value) VALUES('computer_owner',?)").run(owner.id);
    const req=(path,body,who=owner)=>fetch(`http://127.0.0.1:${port}${path}`,{method:body?'POST':'GET',headers:{authorization:`Bearer ${who.token}`,'content-type':'application/json'},body:body&&JSON.stringify(body)});
    const task=(await (await req('/v1/jobs',{type:'computer.task',message:'open Safari'})).json()).id;
    while(app.store.getJob(task,owner.id).status!=='running')await tick();
    await tick();
    const input=await req('/v1/computer/input',{action:'left_click',coordinate:[10,20]});
    assert.equal(input.status,200);
    while(app.store.getJob(task,owner.id).status==='running')await tick();
    assert.equal(app.store.getJob(task,owner.id).status,'cancelled');
    assert.ok(app.store.events(task).some(e=>e.kind==='takeover'));
    assert.deepEqual(runs.at(-1),{action:'left_click',direct:true,coordinate:[10,20]});
    assert.equal((await (await req('/v1/status')).json()).computer.controlled,true);
    assert.equal((await req('/v1/computer/input',{action:'left_click',coordinate:[1,1]},other)).status,409);
    app.work.addSchedule(owner.id,{title:'Brief',task:'news',daily_at:'08:00'});
    const work=await (await req('/v1/work')).json();
    assert.equal(work.schedules[0].title,'Brief');
    assert.equal((await (await req('/v1/work',undefined,other)).json()).schedules.length,0);
    assert.equal((await req('/v1/work/cancel',{id:work.schedules[0].id},other)).status,404);
    assert.match((await (await req('/v1/work/cancel',{id:work.schedules[0].id})).json()).message,/Deleted/);
    assert.equal((await req('/v1/computer/release',{})).status,200);
    assert.equal((await (await req('/v1/status')).json()).computer.controlled,false);
  }finally{await app.close();rmSync(dir,{recursive:true,force:true});}
});
