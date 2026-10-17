import {connect} from 'node:net';
import {existsSync,writeFileSync,readFileSync,chmodSync} from 'node:fs';
import {randomBytes,createHmac} from 'node:crypto';
import {homedir} from 'node:os';
import {resolve,dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runAgent,agentCost,systemFor} from './agent.mjs';
import {AI_BUDGET_MICROS} from './ai.mjs';
import {runOpenAIAgent,openaiCost} from './openai.mjs';
import {keys,selectedProvider} from './keys.mjs';
import {readAccess,checkAction,FILE_TOOLS,OPEN_APP_TOOL,fileTool,findApp} from './policy.mjs';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
export const binary=join(root,'.nova-data','Nova Operator.app','Contents','MacOS','NovaOperator');
const keyFile=join(root,'.nova-data','operator.key');
export const socketPath=join(homedir(),'Library','Application Support','Nova Operator','operator.sock');
export const TURN_RESERVATION_MICROS=300_000; // Upper bound for one Sonnet turn, settled to actual usage.
const NOT_RUNNING='Nova Operator is not running on the Mac. Run npm run operator:install, or open Nova Operator.app.';
const fail=text=>{throw new Error(text);};

export function signedEnvelope(request, key, now=Date.now()) {
  const payload=Buffer.from(JSON.stringify({...request,nonce:randomBytes(16).toString('hex'),expires:now/1000+5}));
  return {payload:payload.toString('base64'),mac:createHmac('sha256',key).update(payload).digest('base64')};
}
export function operatorRequest(message,{signal,timeout=15000}={}) {
  return new Promise((ok,reject)=>{
    const chunks=[];let size=0;
    const socket=connect(socketPath);
    const timer=setTimeout(()=>socket.destroy(new Error('Nova Operator did not respond in time.')),timeout);
    const abort=()=>socket.destroy(new Error('Task cancelled'));
    signal?.addEventListener('abort',abort,{once:true});
    const finish=()=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);};
    socket.on('connect',()=>socket.end(JSON.stringify(message)));
    socket.on('data',chunk=>{size+=chunk.length;if(size>8*1024*1024)socket.destroy(new Error('Nova Operator reply too large'));else chunks.push(chunk);});
    socket.on('error',error=>{finish();reject(['ENOENT','ECONNREFUSED'].includes(error.code)?new Error(NOT_RUNNING):error);});
    socket.on('end',()=>{finish();try{ok(JSON.parse(Buffer.concat(chunks)));}catch{reject(new Error('Nova Operator did not return a result. Check macOS permissions.'));}});
  });
}
export async function native(request,signal) {
  if(!existsSync(keyFile))writeFileSync(keyFile,randomBytes(32),{mode:0o600,flag:'wx'});
  chmodSync(keyFile,0o600);
  const result=await operatorRequest({command:'execute',envelope:signedEnvelope(request,readFileSync(keyFile))},{signal,timeout:60000});
  if(result.error)throw new Error(result.error);
  return result;
}
export async function permissions() {
  const installed=existsSync(binary);
  try{return {installed,running:true,...await operatorRequest({command:'permissions'},{timeout:5000})};}
  catch{return {installed,running:false,accessibility:false,screenRecording:false};}
}
/// Shows macOS's own Accessibility and Screen Recording prompts on the Mac. Granting stays a
/// person's choice in System Settings; this only opens the prompts.
export async function requestPermissions() {
  return await operatorRequest({command:'request_permissions'},{timeout:10000});
}
const describe=(name,input)=>{
  const at=input.coordinate?` at ${input.coordinate.join(', ')}`:'';
  if(name==='type')return `Typed ${JSON.stringify(String(input.text).slice(0,80))}`;
  if(name==='key')return `Pressed ${input.text}`;
  if(name==='scroll')return `Scrolled ${input.scroll_direction}${at}`;
  if(name==='left_click_drag')return `Dragged to ${input.coordinate?.join(', ')}`;
  return `${name.replaceAll('_',' ')}${at}`;
};

/// Meters one job's AI turns: reserves an upper bound before each call and settles to actual usage.
/// `price(data)` turns a provider response into micro-dollars.
export function meter(store,id,check=()=>{},price=data=>agentCost(data.usage)){
  let spent=0;
  return {
    get spent(){return spent;},
    async spend(turn,request){
      check();
      const reservation=`${id}:${turn}`;
      store.reserveAI(reservation,TURN_RESERVATION_MICROS,AI_BUDGET_MICROS);
      let data;
      // Unbilled provider errors release the hold; timeouts keep it because billing is unknown.
      try{data=await request();}catch(error){if(error.unbilled)store.settleAI(reservation,0);throw error;}
      const cost=price(data);
      store.settleAI(reservation,cost);spent+=cost;
      return data;
    }
  };
}

/// The agent loop, model call and pricing for the AI provider Matthew chose.
/// `openai` lets tests replace the OpenAI loop or call the same way `agent` and `call` do for Claude.
export function engineFor(store,{agent=runAgent,call,openai={},keyStore=keys}={}){
  const provider=selectedProvider(store,keyStore);
  return provider==='openai'
    ?{provider,run:openai.agent??runOpenAIAgent,call:openai.call,price:openaiCost}
    :{provider,run:agent,call,price:data=>agentCost(data.usage)};
}

const INPUT_ACTIONS=new Set(['left_click','double_click','right_click','left_click_drag','mouse_move','scroll','type','key']);
const CONTROL_MS=5*60_000;
const RESUMED='Matthew took over the Mac and has now handed it back. The screen may have changed, so take a screenshot before doing anything else.';
const CHAT_ONLY="Remote control is off while Nova's range is Just chat. Change the range in the Nova app to see or use the Mac.";
const pair=value=>Array.isArray(value)&&value.length===2&&value.every(n=>Number.isFinite(n)&&n>=0&&n<100000)?value.map(Math.round):null;
const sleep=ms=>new Promise(ok=>setTimeout(ok,ms));

export function createComputer(store,{run=native,permissionCheck=permissions,agent=runAgent,call,openai={},keyStore=keys,controlMs=CONTROL_MS}={}) {
  let current=null,liveBusy=false,controlledUntil=0;
  const screens=new Map(), memory=new Map(), conversations=new Map();
  const owner=()=>store.db.prepare("SELECT value FROM settings WHERE key='computer_owner'").get()?.value;
  const controlled=()=>Date.now()<controlledUntil;
  const authorize=device=>{
    if(owner()!==device || !store.devices().some(d=>d.id===device))fail('Computer control is available only to the locally designated owner iPhone');
    if(store.stopped())fail('Nova is emergency stopped');
  };
  // While Matthew drives from the iPhone, Nova's next action waits. When he hands back, Nova is
  // told the screen may have changed instead of replaying an action planned for the old screen.
  // A takeover that lapses without Hand back cancels the task, so Nova never resumes on its own.
  const waitForControl=async(id,signal)=>{
    if(!controlled())return false;
    while(controlled()){if(signal.aborted)fail('Task cancelled');await sleep(200);}
    if(controlledUntil!==0)throw Object.assign(new Error("You took over the Mac and didn't hand it back, so I stopped this task."),{fatal:true});
    return true;
  };
  const takeControl=device=>{
    authorize(device);
    if(readAccess(store).level==='chat')fail(CHAT_ONLY);
    if(!controlled()&&current)store.event(current.id,'paused','Matthew took over. Nova is waiting until he hands back control.');
    controlledUntil=Date.now()+controlMs;
  };
  // Every AI action is checked against the current range when it runs, so a range change applies
  // to the very next action, including in scheduled runs. The scope is signed into the request.
  const act=async(device,id,signal,request)=>{
    authorize(device);
    if(signal.aborted)fail('Task cancelled');
    if(await waitForControl(id,signal)&&request.action!=='screenshot')return {text:RESUMED,paused:true};
    authorize(device);
    const scope=checkAction(readAccess(store),request);
    return await run({...request,scope},signal);
  };
  return {
    status(device){return {owner:owner()===device,busy:Boolean(current),task:current?.device===device?current.id:null,controlled:controlled(),paused:Boolean(current)&&controlled()};},
    permissions:permissionCheck,
    busy(){return current?{...current}:null;},
    controlled,
    // Memory lasts for one conversation: the iPhone starts a new one each time the app opens.
    // Background runs (schedules) keep their own memory and never evict the iPhone's conversation.
    async task(device,id,message,signal,conversation='default',{tools=[],onTool,prefix='',background=false}={}){
      authorize(device);
      if(current)fail('Nova is already working on something. Stop it or wait for it to finish.');
      if(background&&controlled())fail('Matthew is controlling the Mac');
      current={id,device,background};
      if(!background)controlledUntil=0;
      try{
        const access=readAccess(store),useComputer=access.level!=='chat';
        if(background&&!useComputer)fail("Nova's range is Just chat, so it can't use the Mac for this scheduled task. Change the range in the Nova app.");
        if(useComputer){
          const permission=await permissionCheck();
          if(!permission.installed&&permission.installed!==undefined)fail('Build the signed Nova Operator Mac app first.');
          if(permission.running===false)fail(NOT_RUNNING);
          const missing=[!permission.accessibility&&'Accessibility',!permission.screenRecording&&'Screen Recording'].filter(Boolean);
          if(missing.length)fail(`Nova Operator still needs ${missing.join(' and ')} access on the Mac. Open System Settings → Privacy & Security → ${missing[0]} and allow Nova Operator.`);
          await run({action:'begin'},signal);
        }
        const extra=[...tools,...(access.level==='apps'?[OPEN_APP_TOOL]:[]),...(useComputer&&access.folders.length?FILE_TOOLS:[])];
        const handle=async(name,input)=>{
          if(name==='open_app'){
            const now=readAccess(store);
            if(now.level!=='apps')fail('open_app is only for the Chosen apps range');
            const app=findApp(now,input.app);
            const result=await act(device,id,signal,{action:'open_app',bundle_id:app.bundleId});
            if(result.paused)return result.text;
            store.event(id,'action',`Opened ${app.name}`);
            return `Opened ${app.name}.`;
          }
          if(FILE_TOOLS.some(t=>t.name===name)){authorize(device);return fileTool(readAccess(store),name,input);}
          if(!onTool)fail(`Unknown tool ${name}`);
          return await onTool(name,input);
        };
        const key=`${device}:${conversation}`;
        if(!background&&conversations.get(device)!==key){memory.delete(conversations.get(device));conversations.set(device,key);}
        const engine=engineFor(store,{agent,call,openai,keyStore});
        const metered=meter(store,id,()=>authorize(device),engine.price);
        const result=await engine.run({task:prefix+message,history:memory.get(key)??[],signal,call:engine.call,tools:extra,onTool:handle,
          computer:useComputer,system:systemFor(access),
          execute:request=>act(device,id,signal,request),
          spend:metered.spend,
          onNarration:text=>store.event(id,'narration',text.slice(0,600)),
          onAction:(name,input)=>store.event(id,'action',describe(name,input)),
          onScreen:jpeg=>screens.set(device,{id,jpeg}),
          onVisual:spec=>store.event(id,'visual',spec)});
        const shown=result.visual?`\n[Shown on the iPhone: ${JSON.stringify(result.visual).slice(0,3000)}]`:'';
        memory.set(key,[...(memory.get(key)??[]),{role:'user',content:message.slice(0,1000)},{role:'assistant',content:result.message.slice(0,1500)+shown}].slice(background?-8:-24));
        return {message:result.message,estimatedUSD:metered.spent/1e6,actions:result.actions,visuals:result.visuals};
      }finally{current=null;}
    },
    forget(conversationKey){memory.delete(conversationKey);},
    stop(){current=null;controlledUntil=0;screens.clear();memory.clear();},
    /// Matthew takes the Mac from the iPhone. Nova's running task pauses before its next action.
    takeOver(device){takeControl(device);return {paused:Boolean(current)};},
    /// Matthew's own input from the iPhone. It is human input, so it is not limited to the AI's range,
    /// but it still needs the owner iPhone, no emergency stop and a range other than Just chat.
    async input(device,request){
      authorize(device);
      if(readAccess(store).level==='chat')fail(CHAT_ONLY);
      const action=String(request?.action??'');
      if(!INPUT_ACTIONS.has(action))fail('Unsupported input');
      const clean={action,direct:true};
      if(request.coordinate!==undefined&&!(clean.coordinate=pair(request.coordinate)))fail('Invalid coordinate');
      if(action==='left_click_drag'&&!(clean.start_coordinate=pair(request.start_coordinate)))fail('Invalid drag start');
      if(['left_click','double_click','right_click','left_click_drag','mouse_move'].includes(action)&&!clean.coordinate)fail('Missing coordinate');
      if(action==='scroll'){
        if(!['up','down','left','right'].includes(request.scroll_direction))fail('Invalid scroll direction');
        clean.scroll_direction=request.scroll_direction;
        clean.scroll_amount=Math.max(1,Math.min(15,Math.round(Number(request.scroll_amount)||3)));
      }
      if(action==='type'){if(typeof request.text!=='string'||!request.text||request.text.length>1000)fail('Type 1–1000 characters');clean.text=request.text;}
      if(action==='key'){if(typeof request.text!=='string'||!/^[A-Za-z0-9_+\-=\[\];',./`\\ ]{1,40}$/.test(request.text))fail('Invalid key');clean.text=request.text;}
      takeControl(device);
      await run({action:'begin'});
      return await run({...clean,scope:{mode:'full'}});
    },
    /// Hand back: a paused task continues from a fresh screenshot.
    release(device){
      authorize(device);
      if(controlled()&&current)store.event(current.id,'resumed','Matthew handed back control');
      controlledUntil=0;
    },
    // A fresh screenshot for the iPhone's live view. Never goes to an AI provider.
    async live(device){
      authorize(device);
      if(readAccess(store).level==='chat')fail(CHAT_ONLY);
      if(liveBusy)fail('A live screenshot is already being captured');
      liveBusy=true;
      try{const shot=await run({action:'screenshot',scope:{mode:'full'}});return Buffer.from(shot.image,'base64');}
      finally{liveBusy=false;}
    },
    screen(device,id){authorize(device);const screen=screens.get(device);if(screen?.id!==id)fail('Screen not found');return Buffer.from(screen.jpeg,'base64');}
  };
}
