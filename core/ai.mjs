import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { configuredKey, MODEL, pricedUsage } from './claude-worker.mjs';
import {workerLaunch} from './brain-sandbox.mjs';

export const AI_BUDGET_MICROS = 1_000_000; // $1 lifetime allowance, not a daily reset.
export const RESERVATION_MICROS = 10_000; // $0.01 retained on unknown outcomes.
const errors = {
  KEY: 'Add a Claude API key to the private .env.local file on your Mac (permissions 600).',
  AUTH: 'Claude rejected the API key. Check the key and access in Claude Console.',
  LIMIT: 'Claude quota or rate limit reached. Check credits; Nova did not retry.',
  PROVIDER: 'Claude could not complete this request. Nova did not retry.',
  NETWORK: 'Claude connection failed or timed out. Nova did not retry.',
  USAGE: 'Unexpected Claude usage. AI paused for this request; check model pricing and limits.',
  EMPTY: 'Claude returned no reply. Nova did not retry.',
  REQUEST: 'Conversation is too large. Try a shorter message.'
};

export function brokerBodyValid(body) {
  if(!body||body.model!==MODEL||body.max_tokens!==512||body.thinking?.type!=='disabled'||
    Object.keys(body).some(k=>!['model','max_tokens','thinking','system','messages','tools','tool_choice'].includes(k))||
    typeof body.system!=='string'||body.system.length>4000||!Array.isArray(body.messages)||body.messages.length>7||JSON.stringify(body).length>6_100_000)return false;
  if(body.tools&&(!Array.isArray(body.tools)||body.tools.length!==1||body.tools[0].name!=='computer_action'||body.tools[0].type||JSON.stringify(body.tools).length>5000))return false;
  let textLength=0,images=0;
  for(const message of body.messages){
    if(!['user','assistant'].includes(message.role))return false;
    if(typeof message.content==='string'){textLength+=message.content.length;continue;}
    if(!Array.isArray(message.content))return false;
    for(const block of message.content){
      if(block.type==='text'&&typeof block.text==='string')textLength+=block.text.length;
      else if(block.type==='image'&&block.source?.type==='base64'&&block.source.media_type==='image/png'&&typeof block.source.data==='string'){
        const png=Buffer.from(block.source.data,'base64');
        if(++images>1||png.length<24||png.subarray(0,8).toString('hex')!=='89504e470d0a1a0a'||png.readUInt32BE(16)>1200||png.readUInt32BE(20)>900)return false;
      }else return false;
    }
  }
  return textLength<=12000;
}
export function callWorker(messages, signal, {fetchImpl=fetch,keyProvider=configuredKey}={}) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(new Error('AI request cancelled'));
    const worker = fork(fileURLToPath(new URL('./claude-worker.mjs', import.meta.url)), [], {
      // Do not inherit service credentials, NODE_OPTIONS or unrelated API keys.
      env: {}, ...workerLaunch(), stdio: ['ignore','ignore','ignore','ipc']
    });
    let finished = false;
    const finish = (error, result) => {
      if (finished) return;
      finished = true; clearTimeout(timer); signal.removeEventListener('abort', abort); worker.kill();
      if (error) reject(error); else resolve(result);
    };
    const abort = () => finish(new Error('AI request cancelled'));
    const timer = setTimeout(() => finish(new Error(errors.NETWORK)), 30000);
    signal.addEventListener('abort', abort, {once:true});
    worker.once('error', () => finish(new Error(errors.NETWORK)));
    worker.once('exit', () => finish(new Error(errors.NETWORK)));
    let dispatched=false,trustedUsage;
    worker.on('message', async data => {
      if(data.api){
        if(dispatched)return finish(new Error(errors.REQUEST));
        dispatched=true;
        try {
          const body=data.api;
          if(!brokerBodyValid(body))throw new Error('REQUEST');
          const response=await fetchImpl('https://api.anthropic.com/v1/messages',{
            method:'POST',redirect:'error',signal:AbortSignal.any([signal,AbortSignal.timeout(25000)]),
            headers:{'content-type':'application/json','x-api-key':keyProvider(),'anthropic-version':'2023-06-01'},body:JSON.stringify(body)
          });
          const result=await response.json();
          if(response.ok)trustedUsage=pricedUsage(result);
          if(!finished&&worker.connected)worker.send({apiResponse:{status:response.status,body:result}},error=>{if(error)finish(new Error(errors.NETWORK));});
        } catch {finish(new Error(errors.NETWORK));}
        return;
      }
      data.result&&trustedUsage ? finish(null,{...data.result,...trustedUsage}) : finish(new Error(errors[data.code] ?? errors.PROVIDER));
    });
    worker.send(messages, error => { if (error) finish(new Error(errors.NETWORK)); });
  });
}

export function createAI(store, { request = callWorker, configured = () => Boolean(configuredKey()) } = {}) {
  let busy = false;
  return {
    status() { return { configured: configured(), model: MODEL, usedUSD: store.aiSpent()/1e6, allowanceUSD: AI_BUDGET_MICROS/1e6, busy }; },
    async computer(id,computer,signal) {
      if(!configured())throw new Error(errors.KEY);
      if(busy)throw new Error('Nova is already answering a request. Please wait.');
      busy=true;
      try{
        if(!store.reserveAI(id,RESERVATION_MICROS,AI_BUDGET_MICROS))throw new Error('Nova reached its $1 AI allowance.');
        const result=await request({computer},signal);
        if(!Number.isSafeInteger(result.costMicros)||result.costMicros<0||result.costMicros>RESERVATION_MICROS)throw new Error(errors.USAGE);
        store.settleAI(id,result.costMicros);
        return {...result,estimatedUSD:result.costMicros/1e6};
      }finally{busy=false;}
    },
    async chat(id, deviceId, message, signal) {
      if (!configured()) throw new Error(errors.KEY);
      if (busy) throw new Error('Nova is already answering a message. Please wait.');
      busy = true;
      try {
        const messages = store.aiHistory(deviceId);
        messages.push({role:'user',content:message});
        if (!store.reserveAI(id, RESERVATION_MICROS, AI_BUDGET_MICROS)) throw new Error('Nova reached its $1 AI allowance. Change it locally on the Mac before continuing.');
        // Reserve before dispatch. Timeout/stop/crash retains it because billing is unknown.
        const result = await request(messages, signal);
        if (!Number.isSafeInteger(result.costMicros) || result.costMicros < 0 || result.costMicros > RESERVATION_MICROS) throw new Error(errors.USAGE);
        store.settleAI(id, result.costMicros);
        return { ...result, estimatedUSD: result.costMicros/1e6 };
      } finally { busy = false; }
    }
  };
}
