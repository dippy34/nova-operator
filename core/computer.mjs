import {execFile} from 'node:child_process';
import {existsSync,writeFileSync,readFileSync,chmodSync} from 'node:fs';
import {randomBytes,createHmac} from 'node:crypto';
import {resolve,dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';

export const APPS=['Chrome','Safari','TextEdit','Calculator','Notes','Finder'];
export const KEYS=['return','tab','escape','backspace','up','down','left','right','cmd+a','cmd+l','cmd+n','cmd+s'];
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
export const binary=join(root,'.nova-data','Nova Operator.app','Contents','MacOS','NovaOperator');
const keyFile=join(root,'.nova-data','operator.key');
const fail=text=>{throw new Error(text);};

export function validateAction(input) {
  if(!input || typeof input!=='object' || Array.isArray(input))fail('Invalid computer action');
  const allowed={click:['kind','x','y'],type:['kind','text'],key:['kind','key'],scroll:['kind','x','y','direction'],done:['kind','message']};
  if(!allowed[input.kind] || Object.keys(input).some(k=>!allowed[input.kind].includes(k)))fail('Computer action outside supported scope');
  if(['click','scroll'].includes(input.kind) && ![input.x,input.y].every(n=>typeof n==='number' && Number.isFinite(n) && n>=2 && n<=998))fail('Coordinates must stay inside the selected window');
  if(input.kind==='type' && (typeof input.text!=='string'||!input.text.length||input.text.length>500||/[\x00-\x1f\x7f]/.test(input.text)))fail('Only printable text of 1–500 characters is allowed');
  if(input.kind==='key'&&!KEYS.includes(input.key))fail('Key combination outside allowed scope');
  if(input.kind==='scroll'&&!['up','down'].includes(input.direction))fail('Invalid scroll direction');
  if(input.kind==='done'&&(typeof input.message!=='string'||input.message.length>1000))fail('Invalid completion message');
  return structuredClone(input);
}
export function signedEnvelope(request, key, now=Date.now()) {
  const payload=Buffer.from(JSON.stringify({...request,nonce:randomBytes(16).toString('hex'),expires:now/1000+5}));
  return {payload:payload.toString('base64'),mac:createHmac('sha256',key).update(payload).digest('base64')};
}
export function native(request,signal) {
  if(!existsSync(binary))return Promise.reject(new Error('Build the Nova Operator Mac helper first.'));
  if(!existsSync(keyFile))writeFileSync(keyFile,randomBytes(32),{mode:0o600,flag:'wx'});
  chmodSync(keyFile,0o600);
  const envelope=signedEnvelope(request,readFileSync(keyFile));
  return new Promise((ok,reject)=>{
    const process=execFile(binary,['execute'],{signal,timeout:15000,maxBuffer:8*1024*1024,env:{}},(error,stdout)=>{
      let result;try{result=JSON.parse(stdout);}catch{return reject(new Error('Nova Operator did not return a result. Check macOS permissions.'));}
      if(error||result.error)reject(new Error(result.error??'Computer action failed'));
      else ok(result);
    });
    process.stdin.end(JSON.stringify(envelope));
  });
}
export function permissions() {
  return new Promise(ok=>{
    if(!existsSync(binary))return ok({installed:false,accessibility:false,screenRecording:false});
    execFile(binary,['permissions'],{timeout:5000,env:{}},(error,stdout)=>{
      try{ok({installed:true,...JSON.parse(stdout)});}catch{ok({installed:true,accessibility:false,screenRecording:false});}
    });
  });
}

export function createComputer(store,ai,{run=native,clock=Date.now,permissionCheck=permissions}={}) {
  let session=null,busy=false;
  const pending=new Map(),screens=new Map(),tasks=new Map();
  const owner=()=>store.db.prepare("SELECT value FROM settings WHERE key='computer_owner'").get()?.value;
  const authorize=device=>{
    if(owner()!==device || !store.devices().some(d=>d.id===device))fail('Computer control is available only to the locally designated owner iPhone');
    if(store.stopped())fail('Nova is emergency stopped');
  };
  const grant=device=>{
    authorize(device);
    if(!session||session.device!==device||session.expires<=clock())fail('Start a new computer session on your iPhone');
    return session;
  };
  const lock=()=>{if(busy)fail('Another computer request is running');busy=true;};
  const describe=(action,app)=>action.kind==='type'?`Type in ${app}: ${action.text}`:action.kind==='key'?`Press ${action.key} in ${app}`:action.kind==='scroll'?`Scroll ${action.direction} in ${app}`:`Click in ${app} at ${action.x}, ${action.y} (0–1000 window coordinates)`;
  async function propose(device,id,signal) {
    const allowed=grant(device), task=tasks.get(id);
    if(!task||task.device!==device||task.session!==allowed.id)fail('Computer task session ended');
    if(task.step>=8)fail('Eight-step limit reached. Start a new task to continue.');
    const screen=await run({kind:'observe',app:allowed.app},signal);
    grant(device);
    if(!screen.snapshot||typeof screen.png!=='string'||screen.png.length>6_000_000)fail('Invalid window capture');
    screens.set(id,{device,png:screen.png});
    const result=await ai.computer(`${id}:${task.step}`,{app:allowed.app,task:task.message,previous:task.previous,image:screen.png},signal);
    grant(device);
    if(session.id!==task.session||signal.aborted)fail('Computer session changed or was cancelled');
    const action=validateAction(result.action);
    if(action.kind==='done'){tasks.delete(id);return {...result,message:action.message};}
    const summary=describe(action,allowed.app);
    const approvalID=randomBytes(16).toString('hex');
    pending.set(id,{approvalID,device,session:allowed.id,action,snapshot:screen.snapshot,expires:Math.min(clock()+120000,allowed.expires)});
    store.event(id,'approval_requested',summary);
    return {message:'Review this action on your iPhone. Nothing has been clicked or typed yet.',needsApproval:true,approvalID,summary,action,estimatedUSD:result.estimatedUSD};
  }
  return {
    status(device){return {owner:owner()===device,active:session?.device===device&&session.expires>clock(),app:session?.device===device?session.app:null,expires:session?.device===device?session.expires:null,apps:APPS,busy};},
    permissions:permissionCheck,
    async start(device,app,signal){
      authorize(device);if(!APPS.includes(app))fail('App is outside supported scope');lock();
      try{
        const permission=await permissionCheck();
        if(!permission.accessibility||!permission.screenRecording)fail('Grant Nova Operator Accessibility and Screen Recording access on the Mac first.');
        authorize(device);if(signal.aborted)fail('Session cancelled');
        await run({kind:'activate',app},signal);authorize(device);
        session={id:randomBytes(16).toString('hex'),device,app,expires:clock()+20*60000};pending.clear();tasks.clear();screens.clear();
        return this.status(device);
      }finally{busy=false;}
    },
    async plan(device,id,message,signal){
      const allowed=grant(device);lock();
      try{
        if([...pending.values()].some(p=>p.expires>clock()))fail('Approve or reject the waiting action before starting another task');
        tasks.set(id,{device,session:allowed.id,message,step:0,previous:[]});
        return await propose(device,id,signal);
      }finally{busy=false;}
    },
    checkApproval(device,id,approvalID){
      const allowed=grant(device), approval=pending.get(id);
      if(!approval||approval.device!==device||approval.session!==allowed.id||approval.expires<=clock()||approval.approvalID!==approvalID)fail('Approval expired, already used, or belongs to another action/session');
    },
    async approve(device,id,signal,approvalID){
      const allowed=grant(device);lock();
      try{
        const approval=pending.get(id);
        this.checkApproval(device,id,approvalID);
        pending.delete(id); // Consume before execution: never replay uncertain input.
        const action=validateAction(approval.action);
        authorize(device);
        await run({...action,app:allowed.app,snapshot:approval.snapshot},signal);
        store.event(id,'input_delivered',describe(action,allowed.app));
        const task=tasks.get(id);task.step++;task.previous.push(describe(action,allowed.app));
        if(signal.aborted)fail('Computer task cancelled');
        return await propose(device,id,signal);
      }finally{busy=false;}
    },
    reject(device,id,approvalID){this.checkApproval(device,id,approvalID);pending.delete(id);tasks.delete(id);screens.delete(id);store.updateJob(id,'cancelled');},
    end(device){authorize(device);session=null;pending.clear();tasks.clear();screens.clear();},
    stop(){session=null;pending.clear();tasks.clear();screens.clear();},
    screen(device,id){grant(device);const screen=screens.get(id);if(screen?.device!==device)fail('Screen not found');return Buffer.from(screen.png,'base64');}
  };
}
