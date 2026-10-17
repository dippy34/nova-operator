import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync,mkdirSync,writeFileSync,symlinkSync,readFileSync,chmodSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {Store,normalizeShortCode} from './db.mjs';
import {makeNova} from './server.mjs';
import {memoryKeyStore,createKeyStore,testKey,selectedProvider} from './keys.mjs';
import {readAccess,checkAction,scopedKeyAllowed,validateFolders,fileTool,findApp,executorScope} from './policy.mjs';
import {createPairingGuard,listFolders,pairingLink} from './setup.mjs';
import {serveURL,tailscaleStatus} from './tailscale.mjs';
import {translateAction,callOpenAI} from './openai.mjs';

const ANTHROPIC='sk-ant-test-0000000000000000000000000000';
const OPENAI='sk-proj-test-000000000000000000000000';
const temp=prefix=>mkdtempSync(join(tmpdir(),prefix));
const macEvents=store=>store.db.prepare('SELECT kind,description FROM events WHERE job_id IS NULL ORDER BY id').all();

test('one invitation can be redeemed once, by its QR secret or its typed short code',()=>{
  const dir=temp('nova-pair-'),store=new Store(join(dir,'db'));
  try{
    const a=store.createInvitation();
    assert.match(a.short,/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/);
    assert.equal(a.code.length,24);assert.ok(a.expiresMs>Date.now());
    // Typed codes forgive case, spaces, dashes and look-alike letters.
    const typed=` ${a.short.toLowerCase().replace('-',' ')} `;
    const device=store.redeemInvitation(typed,'Phone');
    assert.ok(device?.token);assert.equal(device.owner,false);
    assert.equal(store.redeemInvitation(a.code,'Again'),null,'the QR secret of a used invitation is dead too');
    assert.equal(store.setting('computer_owner'),null,'a member invitation never makes an owner');
    assert.equal(normalizeShortCode('o1l-I'),'0111');
    const owner=store.createInvitation({owner:true});
    const ownerDevice=store.redeemInvitation(owner.code,'Owner phone');
    assert.equal(ownerDevice.owner,true);assert.equal(store.setting('computer_owner'),ownerDevice.id);
    const late=store.createInvitation();
    store.db.prepare('UPDATE invitations SET expires_ms=0').run();
    assert.equal(store.redeemInvitation(late.short,'Late'),null);
    assert.equal(store.redeemInvitation('',''),null);
    // Revoking the owner device also ends its control of the Mac.
    assert.equal(store.revokeDevice(ownerDevice.id),true);
    assert.equal(store.setting('computer_owner'),null);
    assert.equal(store.auth(ownerDevice.token),null);
  }finally{store.close();rmSync(dir,{recursive:true,force:true});}
});

test('existing owners keep whole-Mac control after upgrading; new installs start at Just chat',()=>{
  const dir=temp('nova-migrate-'),file=join(dir,'db');
  let store=new Store(file);
  try{
    assert.equal(readAccess(store).level,'chat');assert.equal(readAccess(store).chosen,false);
    const device=store.redeemInvitation(store.issueInvitation(),'Phone');
    store.db.prepare("INSERT INTO settings(key,value) VALUES('computer_owner',?)").run(device.id);
    store.close();store=new Store(file);
    assert.deepEqual(readAccess(store),{level:'full',apps:[],folders:[],chosen:true});
    store.setSetting('access_level','chat');store.close();store=new Store(file);
    assert.equal(readAccess(store).level,'chat','a range Matthew chose is never overwritten');
  }finally{store.close();rmSync(dir,{recursive:true,force:true});}
});

test('wrong codes are limited: ten misses lock pairing and cancel outstanding codes',async()=>{
  const dir=temp('nova-pair-http-');
  const app=makeNova({dbFile:join(dir,'db'),setupOptions:{keyStore:memoryKeyStore()}});
  try{
    const port=await app.listen(0);
    const pair=body=>fetch(`http://127.0.0.1:${port}/v1/pair`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
    const good=app.store.createInvitation({owner:true});
    const ok=await pair({code:good.short,deviceName:'Owner phone'});
    assert.equal(ok.status,201);
    const body=await ok.json();
    assert.equal(body.owner,true);assert.equal(typeof body.computer,'string');assert.ok(body.computer.length>0);
    const pending=app.store.createInvitation();
    for(let i=0;i<9;i++){
      const miss=await pair({code:'ZZZZ-ZZZZ',deviceName:'Guess'});
      assert.equal(miss.status,403);assert.match((await miss.json()).error,/mistyped, expired/);
    }
    assert.equal((await pair({code:'YYYY-YYYY',deviceName:'Guess'})).status,403);
    const locked=await pair({code:pending.short,deviceName:'Phone'});
    assert.equal(locked.status,429);assert.match((await locked.json()).error,/Wait 10 minutes/);
    assert.equal(app.store.redeemInvitation(pending.code,'Phone'),null,'outstanding codes were cancelled');
  }finally{await app.close();rmSync(dir,{recursive:true,force:true});}
});

test('the pairing guard forgets old misses and unlocks after the lockout',()=>{
  let now=0;const guard=createPairingGuard({max:3,windowMs:100,lockMs:50,now:()=>now});
  assert.equal(guard.fail(),false);now=200;assert.equal(guard.fail(),false);assert.equal(guard.fail(),false);
  assert.equal(guard.fail(),true);assert.equal(guard.locked(),true);
  now=260;assert.equal(guard.locked(),false);
});

test('the QR link carries the address, a one-time code and the name, never a provider key',()=>{
  const link=pairingLink({url:'https://mac.tail.ts.net',code:'abc_DEF-123',name:"Matthew's Mac"});
  assert.equal(link,"nova://pair?v=1&u=https%3A%2F%2Fmac.tail.ts.net&c=abc_DEF-123&n=Matthew's%20Mac");
  assert.ok(!link.includes('sk-'));
});

async function setupFixture({keys=memoryKeyStore(),test:keyTest=async()=>({ok:true,code:'ok',message:'Claude is connected.'})}={}){
  const dir=temp('nova-setup-'),asked=[];
  const app=makeNova({dbFile:join(dir,'db'),
    computerOptions:{permissionCheck:async()=>({installed:true,running:true,accessibility:true,screenRecording:false})},
    setupOptions:{keyStore:keys,testKey:keyTest,requestPermissions:async()=>{asked.push(true);return {asked:true};},
      installedApps:async()=>[{bundleId:'com.apple.Notes',name:'Notes'},{bundleId:'com.apple.Safari',name:'Safari'}]}});
  const port=await app.listen(0);
  const owner=app.store.redeemInvitation(app.store.createInvitation({owner:true}).code,'Owner phone');
  const member=app.store.redeemInvitation(app.store.createInvitation().code,'Family iPad');
  const req=async(path,body,who=owner)=>{
    const response=await fetch(`http://127.0.0.1:${port}${path}`,{method:body?'POST':'GET',headers:{authorization:`Bearer ${who.token}`,'content-type':'application/json'},body:body&&JSON.stringify(body)});
    const text=await response.text();
    return {status:response.status,text,json:JSON.parse(text)};
  };
  return {app,owner,member,req,asked,keys,close:async()=>{await app.close();rmSync(dir,{recursive:true,force:true});}};
}

test('setup status shows what is left to do, and only the owner iPhone can change it',async()=>{
  const f=await setupFixture();
  try{
    const status=(await f.req('/v1/setup')).json;
    assert.equal(status.device.owner,true);assert.equal(status.access.level,'chat');
    assert.deepEqual(status.steps,{paired:true,range:false,permissions:true,ai:false});
    assert.equal(status.permissions.screenRecording,false);
    const memberView=(await f.req('/v1/setup',undefined,f.member)).json;
    assert.equal(memberView.device.owner,false);assert.equal(memberView.permissions,undefined);
    const ownerStatus=(await f.req('/v1/status')).json;
    const memberStatus=(await f.req('/v1/status',undefined,f.member)).json;
    assert.equal(ownerStatus.computer.owner,true);
    assert.ok(ownerStatus.capabilities.includes('computer.task'));
    assert.equal(memberStatus.computer.owner,false);
    assert.ok(!memberStatus.capabilities.includes('computer.task'));
    const count=f.app.store.jobs(f.member.id).length;
    assert.equal((await f.req('/v1/jobs',{type:'computer.task',message:'Open Calculator'},f.member)).status,403);
    assert.equal(f.app.store.jobs(f.member.id).length,count,'reject before creating or running a computer job');

    for(const [path,body] of [['/v1/setup/access',{level:'full'}],['/v1/setup/key',{provider:'anthropic',key:ANTHROPIC}],['/v1/devices/revoke',{id:f.owner.id}],['/v1/setup/permissions',{}]])
      assert.equal((await f.req(path,body,f.member)).status,403,path);
    assert.equal((await f.req('/v1/devices',undefined,f.member)).status,403);
    assert.equal(readAccess(f.app.store).level,'chat');
  }finally{await f.close();}
});

test('the owner chooses a range; apps must be installed and folders must be safe',async()=>{
  const f=await setupFixture();
  try{
    assert.deepEqual((await f.req('/v1/setup/apps')).json.apps.map(a=>a.name),['Notes','Safari']);
    assert.equal((await f.req('/v1/setup/access',{level:'root'})).status,400);
    assert.match((await f.req('/v1/setup/access',{level:'apps',apps:[]})).json.error,/at least one/);
    assert.match((await f.req('/v1/setup/access',{level:'apps',apps:[{bundleId:'com.evil.App',name:'Notes'}]})).json.error,/isn't installed/);
    for(const folder of ['~/.ssh','~/Library','~','/etc'])
      assert.equal((await f.req('/v1/setup/access',{level:'apps',apps:[{bundleId:'com.apple.Notes'}],folders:[folder]})).status,400,folder);
    const chosen=await f.req('/v1/setup/access',{level:'apps',apps:[{bundleId:'com.apple.Notes',name:'Spoofed name'}]});
    assert.equal(chosen.status,200);
    assert.deepEqual(readAccess(f.app.store),{level:'apps',apps:[{bundleId:'com.apple.Notes',name:'Notes'}],folders:[],chosen:true});
    const status=(await f.req('/v1/setup')).json;
    assert.equal(status.steps.range,true);assert.equal(status.steps.permissions,false,'apps need Screen Recording');
    assert.deepEqual((await f.req('/v1/setup/permissions',{})).json.asked,true);assert.equal(f.asked.length,1);
    assert.equal((await f.req('/v1/setup/access',{level:'chat',folders:['~/.ssh']})).status,200,'Just chat ignores folders');
    assert.deepEqual(readAccess(f.app.store).folders,[]);
    assert.ok(macEvents(f.app.store).some(e=>e.kind==='range'));
  }finally{await f.close();}
});

test('provider keys are tested, saved to secure storage and never sent back',async()=>{
  const tested=[];
  const results={[ANTHROPIC]:{ok:true,code:'ok',message:'Claude is connected.'},[OPENAI]:{ok:false,code:'network',message:"Couldn't reach OpenAI."},'sk-ant-rejected-00000000000000000000':{ok:false,code:'rejected',message:'Anthropic rejected that key.'}};
  const f=await setupFixture({test:async(provider,key)=>{tested.push(provider);return results[key];}});
  try{
    assert.match((await f.req('/v1/setup/key',{provider:'anthropic',key:'hello'})).json.error,/start with sk-ant-/);
    assert.equal((await f.req('/v1/setup/key',{provider:'gemini',key:ANTHROPIC})).status,400);
    const rejected=await f.req('/v1/setup/key',{provider:'anthropic',key:'sk-ant-rejected-00000000000000000000'});
    assert.equal(rejected.status,400);assert.match(rejected.json.error,/rejected/);assert.equal(f.keys.read('anthropic'),'');
    const saved=await f.req('/v1/setup/key',{provider:'anthropic',key:ANTHROPIC});
    assert.equal(saved.status,200);assert.equal(saved.json.saved,true);assert.equal(f.keys.read('anthropic'),ANTHROPIC);
    assert.ok(!saved.text.includes(ANTHROPIC),'the key is never echoed');
    assert.equal(saved.json.ai.selected,'anthropic');assert.equal(saved.json.ai.anthropic.configured,true);
    // A network failure still saves the key, with the problem explained.
    const offline=await f.req('/v1/setup/key',{provider:'openai',key:OPENAI});
    assert.equal(offline.json.saved,true);assert.equal(offline.json.test.code,'network');assert.equal(offline.json.ai.selected,'openai');
    const everything=[(await f.req('/v1/setup')).text,(await f.req('/v1/status')).text,JSON.stringify(macEvents(f.app.store))].join('');
    assert.ok(!everything.includes(ANTHROPIC)&&!everything.includes(OPENAI));
    assert.equal((await f.req('/v1/status')).json.provider.selected,'openai');
    assert.equal((await f.req('/v1/setup/provider',{provider:'anthropic'})).json.ai.selected,'anthropic');
    assert.equal((await f.req('/v1/setup/test',{provider:'anthropic'})).json.test.ok,true);
    assert.equal((await f.req('/v1/setup/key/remove',{provider:'openai'})).json.ai.openai.configured,false);
    assert.match((await f.req('/v1/setup/provider',{provider:'openai'})).json.error,/Connect your OpenAI key first/);
    assert.match((await f.req('/v1/setup/test',{provider:'openai'})).json.error,/No OpenAI key/);
    assert.deepEqual(tested,['anthropic','anthropic','openai','anthropic']);
  }finally{await f.close();}
});

test('the owner sees and revokes devices; any device can unpair itself',async()=>{
  const f=await setupFixture();
  try{
    const {devices}=(await f.req('/v1/devices')).json;
    assert.deepEqual(devices.map(d=>[d.name,d.owner,d.current]),[['Owner phone',true,true],['Family iPad',false,false]]);
    assert.equal((await f.req('/v1/devices/revoke',{id:f.member.id})).json.revoked,true);
    assert.equal((await f.req('/v1/status',undefined,f.member)).status,401);
    assert.equal((await f.req('/v1/devices/revoke',{id:'nope'})).status,404);
    assert.equal((await f.req('/v1/unpair',{})).json.unpaired,true);
    const after=await f.req('/v1/status');
    assert.equal(after.status,401);assert.equal(after.json.code,'unpaired');
    assert.equal(f.app.store.setting('computer_owner'),null);
  }finally{await f.close();}
});

test('Chosen-apps key rules refuse shortcuts that act outside the chosen apps',()=>{
  for(const ok of ['cmd+c','cmd+v','return','shift+tab','cmd+shift+z','a','escape'])assert.equal(scopedKeyAllowed(ok),true,ok);
  for(const bad of ['cmd+space','cmd+tab','ctrl+up','fn+f','cmd+alt+escape','cmd+shift+3','f11','super+space','hyper+q','cmd+shift+q','alt+space'])assert.equal(scopedKeyAllowed(bad),false,bad);
  const apps={level:'apps',apps:[{bundleId:'com.apple.Notes',name:'Notes'}],folders:[]};
  assert.deepEqual(checkAction(apps,{action:'type',text:'cmd+space'}),{mode:'apps',apps:['com.apple.Notes']},'typed text is not a shortcut');
  assert.throws(()=>checkAction(apps,{action:'left_click',coordinate:[1,1],text:'ctrl'}),/modifier/);
  assert.throws(()=>executorScope({level:'chat',apps:[],folders:[]}),/Just chat/);
  assert.equal(findApp(apps,'notes').bundleId,'com.apple.Notes');
  assert.throws(()=>findApp(apps,'Terminal'),/Allowed: Notes/);
});

test('folder tools stay inside the chosen folders and never overwrite',()=>{
  const home=temp('nova-home-'),docs=join(home,'Documents'),secret=join(home,'Secret');
  try{
    mkdirSync(join(docs,'.git'),{recursive:true});mkdirSync(join(docs,'Work'));mkdirSync(secret);mkdirSync(join(home,'Library'));mkdirSync(join(home,'.ssh'));
    writeFileSync(join(docs,'notes.txt'),'hello');writeFileSync(join(docs,'.env'),'TOKEN=x');writeFileSync(join(secret,'pw.txt'),'pw');
    writeFileSync(join(docs,'binary.bin'),Buffer.from([1,0,2]));
    symlinkSync(secret,join(docs,'escape'));
    const [real]=validateFolders(['~/Documents'],{home});
    for(const bad of ['~','~/Library','~/.ssh','relative','~/Missing','/etc'])assert.throws(()=>validateFolders([bad],{home}),undefined,bad);
    const access={level:'apps',apps:[],folders:[real]};
    const tool=(name,input)=>fileTool(access,name,input,{home});
    assert.match(tool('list_folder',{path:'~/Documents'}),/file\tnotes\.txt/);
    assert.ok(!tool('list_folder',{path:'~/Documents'}).includes('.env'));
    assert.equal(tool('read_file',{path:'~/Documents/notes.txt'}),'hello');
    for(const path of ['~/Documents/.env','~/Documents/escape/pw.txt','~/Secret/pw.txt','~/Documents/../Secret/pw.txt'])assert.throws(()=>tool('read_file',{path}),/outside/,path);
    assert.throws(()=>tool('read_file',{path:'~/Documents/binary.bin'}),/not text/);
    assert.match(tool('create_file',{path:'~/Documents/new.txt',text:'made by Nova'}),/Created/);
    assert.equal(readFileSync(join(docs,'new.txt'),'utf8'),'made by Nova');
    assert.throws(()=>tool('create_file',{path:'~/Documents/notes.txt',text:'x'}),/already exists/);
    assert.throws(()=>tool('create_file',{path:'~/Documents/escape/new.txt',text:'x'}),/outside/);
    assert.throws(()=>tool('create_file',{path:'~/Documents/.hidden',text:'x'}),/outside/);
    assert.throws(()=>fileTool({level:'chat',apps:[],folders:[real]},'read_file',{path:'~/Documents/notes.txt'},{home}),/no folders/);
    assert.deepEqual(listFolders('~',{home}).map(f=>f.path),['~/Documents']);
    assert.deepEqual(listFolders('~/Documents',{home}).map(f=>f.name),['Work'],'hidden folders and symlinks are not offered');
  }finally{rmSync(home,{recursive:true,force:true});}
});

test('keys go to the Keychain through stdin, are cached briefly and fall back to a private .env.local',async()=>{
  const dir=temp('nova-keys-'),file=join(dir,'.env.local'),commands=[];
  let stored='';
  const run=(args,input)=>{
    commands.push({args,input});
    if(args[0]==='-i'){stored=input.match(/-w (\S+)/)[1];return {status:0};}
    if(args[0]==='find-generic-password')return stored?{status:0,stdout:`${stored}\n`}:{status:44,stdout:''};
    if(args[0]==='delete-generic-password'){stored='';return {status:0};}
    return {status:1};
  };
  try{
    writeFileSync(file,`ANTHROPIC_API_KEY=${ANTHROPIC}\n`,{mode:0o600});
    const store=createKeyStore({run,file});
    assert.equal(store.read('anthropic'),ANTHROPIC);assert.equal(store.storage('anthropic'),'file');
    chmodSync(file,0o644);
    assert.equal(createKeyStore({run,file}).read('anthropic'),'','a readable .env.local is ignored');
    chmodSync(file,0o600);
    store.importLegacy();
    const add=commands.find(c=>c.args[0]==='-i');
    assert.deepEqual(add.args,['-i'],'the key is not in the process arguments');
    assert.match(add.input,/^add-generic-password -U -s dev\.nova\.provider -a anthropic /);
    assert.equal(store.storage('anthropic'),'keychain');
    assert.throws(()=>store.save('openai','not a key'),/starts with sk-/);
    assert.throws(()=>store.save('openai','sk-abc; rm -rf ~ 000000000000000000'),/starts with sk-/,'no shell metacharacters reach security -i');
    store.remove('anthropic');assert.equal(store.storage('anthropic'),'file');
    const memory=memoryKeyStore({openai:OPENAI});
    assert.equal(selectedProvider({setting:()=>null},memory),'openai');
    assert.equal(selectedProvider({setting:()=>'anthropic'},memory),'anthropic');
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('key tests use free model lists and explain failures without the key or response body',async()=>{
  const seen=[];
  const fetchWith=status=>async(url,init)=>{seen.push({url,init});return new Response(JSON.stringify({data:[{id:'claude-sonnet-5-5'},{id:'gpt-6.1-sol'}],error:{message:`echo ${ANTHROPIC}`}}),{status});};
  const ok=await testKey('anthropic',ANTHROPIC,{fetchImpl:fetchWith(200)});
  assert.deepEqual([ok.ok,ok.code],[true,'ok']);
  assert.equal(seen[0].url,'https://api.anthropic.com/v1/models?limit=100');assert.equal(seen[0].init.method,undefined,'GET only');
  const openai=await testKey('openai',OPENAI,{fetchImpl:fetchWith(200)});
  assert.match(openai.message,/bills API use separately from ChatGPT Plus or Pro/);
  assert.equal(seen[1].url,'https://api.openai.com/v1/models');
  for(const [status,code] of [[401,'rejected'],[403,'forbidden'],[429,'limited'],[500,'unavailable']]){
    const result=await testKey('anthropic',ANTHROPIC,{fetchImpl:fetchWith(status)});
    assert.equal(result.code,code);assert.ok(!result.message.includes(ANTHROPIC)&&!result.message.includes('echo'));
  }
  assert.equal((await testKey('openai',OPENAI,{fetchImpl:async()=>{throw new Error('offline');}})).code,'network');
});

test('OpenAI errors explain billing, release the turn reservation and never include the key',async()=>{
  const quota=async()=>Response.json({error:{code:'insufficient_quota',message:'You exceeded your current quota'}},{status:429});
  const original=console.error;const logged=[];console.error=line=>logged.push(line);
  try{
    await assert.rejects(callOpenAI({},{signal:new AbortController().signal,fetchImpl:quota,key:OPENAI}),error=>error.unbilled&&/ChatGPT Plus or Pro doesn't include API use/.test(error.message));
    await assert.rejects(callOpenAI({},{signal:new AbortController().signal,fetchImpl:async()=>Response.json({},{status:401}),key:OPENAI}),/rejected the API key/);
    await assert.rejects(callOpenAI({},{signal:new AbortController().signal,key:''}),error=>error.unbilled&&/Connect your OpenAI API key/.test(error.message));
    assert.ok(logged.every(line=>!line.includes(OPENAI)&&!line.includes('exceeded')));
  }finally{console.error=original;}
});

test('OpenAI computer actions translate to the executor actions Nova already checks',()=>{
  assert.deepEqual(translateAction({type:'click',button:'left',x:3,y:4,keys:['SHIFT']}),{action:'left_click',coordinate:[3,4],text:'shift'});
  assert.deepEqual(translateAction({type:'click',button:'right',x:3,y:4}),{action:'right_click',coordinate:[3,4]});
  assert.deepEqual(translateAction({type:'double_click',x:1,y:2}),{action:'double_click',coordinate:[1,2]});
  assert.deepEqual(translateAction({type:'drag',path:[{x:1,y:1},{x:5,y:6}]}),{action:'left_click_drag',start_coordinate:[1,1],coordinate:[5,6]});
  assert.deepEqual(translateAction({type:'scroll',x:9,y:9,scroll_x:0,scroll_y:-300}),{action:'scroll',coordinate:[9,9],scroll_direction:'up',scroll_amount:3});
  assert.deepEqual(translateAction({type:'keypress',keys:['CMD','SPACE']}),{action:'key',text:'cmd+space'});
  assert.deepEqual(translateAction({type:'type',text:'hi'}),{action:'type',text:'hi'});
  assert.equal(translateAction({type:'screenshot'}),null);
  assert.throws(()=>translateAction({type:'click',button:'back',x:1,y:1}),/isn't supported/);
  assert.throws(()=>translateAction({type:'teleport'}),/Unsupported/);
  assert.equal(scopedKeyAllowed(translateAction({type:'keypress',keys:['CMD','SPACE']}).text),false,'a translated Spotlight shortcut is still refused');
});

test('Tailscale Serve is read from its own status, and Funnel is reported',async()=>{
  const serve={TCP:{'443':{HTTPS:true}},Web:{'mac.tail5b15a3.ts.net:443':{Handlers:{'/':{Proxy:'http://127.0.0.1:8787'}}}}};
  assert.equal(serveURL(serve,8787),'https://mac.tail5b15a3.ts.net');
  assert.equal(serveURL(serve,9999),null);
  assert.equal(serveURL({Web:{'mac.ts.net:8443':{Handlers:{'/':{Proxy:'http://127.0.0.1:8787'}}}}},8787),'https://mac.ts.net:8443');
  const exec=async(binary,args)=>({stdout:JSON.stringify(args[0]==='status'?{BackendState:'Running',Self:{DNSName:'mac.tail5b15a3.ts.net.'}}:{...serve,AllowFunnel:{'mac.tail5b15a3.ts.net:443':true}})});
  assert.deepEqual(await tailscaleStatus(8787,{exec,binary:'/fake/tailscale'}),{installed:true,running:true,dnsName:'mac.tail5b15a3.ts.net',url:'https://mac.tail5b15a3.ts.net',funnel:true});
  assert.deepEqual(await tailscaleStatus(8787,{exec,binary:null}),{installed:false,running:false,url:null,dnsName:null});
});
