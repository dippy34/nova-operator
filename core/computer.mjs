import {connect} from 'node:net';
import {existsSync,writeFileSync,readFileSync,chmodSync} from 'node:fs';
import {randomBytes,createHmac} from 'node:crypto';
import {homedir} from 'node:os';
import {resolve,dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runAgent,agentCost} from './agent.mjs';
import {AI_BUDGET_MICROS} from './ai.mjs';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
export const binary=join(root,'.nova-data','Nova Operator.app','Contents','MacOS','NovaOperator');
const keyFile=join(root,'.nova-data','operator.key');
export const socketPath=join(homedir(),'Library','Application Support','Nova Operator','operator.sock');
export const TURN_RESERVATION_MICROS=300_000; // Upper bound for one Sonnet turn, settled to actual usage.
export const TASK_CAP_MICROS=1_500_000;
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
const describe=(name,input)=>{
  const at=input.coordinate?` at ${input.coordinate.join(', ')}`:'';
  if(name==='type')return `Typed ${JSON.stringify(String(input.text).slice(0,80))}`;
  if(name==='key')return `Pressed ${input.text}`;
  if(name==='scroll')return `Scrolled ${input.scroll_direction}${at}`;
  if(name==='left_click_drag')return `Dragged to ${input.coordinate?.join(', ')}`;
  return `${name.replaceAll('_',' ')}${at}`;
};

export function createComputer(store,{run=native,permissionCheck=permissions,agent=runAgent,call}={}) {
  let current=null,liveBusy=false;
  const screens=new Map(), memory=new Map(), conversations=new Map();
  const owner=()=>store.db.prepare("SELECT value FROM settings WHERE key='computer_owner'").get()?.value;
  const authorize=device=>{
    if(owner()!==device || !store.devices().some(d=>d.id===device))fail('Computer control is available only to the locally designated owner iPhone');
    if(store.stopped())fail('Nova is emergency stopped');
  };
  return {
    status(device){return {owner:owner()===device,busy:Boolean(current),task:current?.device===device?current.id:null};},
    permissions:permissionCheck,
    // Memory lasts for one conversation: the iPhone starts a new one each time the app opens.
    async task(device,id,message,signal,conversation='default'){
      authorize(device);
      if(current)fail('Nova is already working on something. Stop it or wait for it to finish.');
      current={id,device};
      try{
        const permission=await permissionCheck();
        if(!permission.installed&&permission.installed!==undefined)fail('Build the signed Nova Operator Mac app first.');
        if(permission.running===false)fail(NOT_RUNNING);
        const missing=[!permission.accessibility&&'Accessibility',!permission.screenRecording&&'Screen Recording'].filter(Boolean);
        if(missing.length)fail(`Nova Operator still needs ${missing.join(' and ')} access on the Mac. Open System Settings → Privacy & Security → ${missing[0]} and allow Nova Operator.`);
        await run({action:'begin'},signal);
        if(conversations.get(device)!==conversation){memory.delete(conversations.get(device));conversations.set(device,conversation);}
        const key=`${device}:${conversation}`;
        let spent=0;
        const result=await agent({task:message,history:memory.get(key)??[],signal,call,
          execute:async request=>{authorize(device);if(signal.aborted)fail('Task cancelled');return await run(request,signal);},
          spend:async(turn,request)=>{
            authorize(device);
            if(spent+TURN_RESERVATION_MICROS>TASK_CAP_MICROS)fail(`I stopped because this task reached its $${TASK_CAP_MICROS/1e6} limit. Ask me to keep going if you want.`);
            const reservation=`${id}:${turn}`;
            if(!store.reserveAI(reservation,TURN_RESERVATION_MICROS,AI_BUDGET_MICROS))fail(`Nova reached its $${AI_BUDGET_MICROS/1e6} AI allowance.`);
            let data;
            // Unbilled provider errors release the hold; timeouts keep it because billing is unknown.
            try{data=await request();}catch(error){if(error.unbilled)store.settleAI(reservation,0);throw error;}
            const cost=agentCost(data.usage);
            store.settleAI(reservation,cost);spent+=cost;
            return data;
          },
          onNarration:text=>store.event(id,'narration',text.slice(0,600)),
          onAction:(name,input)=>store.event(id,'action',describe(name,input)),
          onScreen:jpeg=>screens.set(device,{id,jpeg}),
          onVisual:spec=>store.event(id,'visual',spec)});
        const shown=result.visual?`\n[Shown on the iPhone: ${JSON.stringify(result.visual).slice(0,3000)}]`:'';
        memory.set(key,[...(memory.get(key)??[]),{role:'user',content:message.slice(0,1000)},{role:'assistant',content:result.message.slice(0,1500)+shown}].slice(-24));
        return {message:result.message,estimatedUSD:spent/1e6,actions:result.actions};
      }finally{current=null;}
    },
    stop(){current=null;screens.clear();memory.clear();},
    // A fresh screenshot for the iPhone's live view. Never goes to Claude.
    async live(device){
      authorize(device);
      if(liveBusy)fail('A live screenshot is already being captured');
      liveBusy=true;
      try{const shot=await run({action:'screenshot'});return Buffer.from(shot.image,'base64');}
      finally{liveBusy=false;}
    },
    screen(device,id){authorize(device);const screen=screens.get(device);if(screen?.id!==id)fail('Screen not found');return Buffer.from(screen.jpeg,'base64');}
  };
}
