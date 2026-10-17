// The same Nova agent on OpenAI's Responses API: the built-in `computer` tool for screenshots,
// mouse and keyboard, `web_search`, and Nova's own function tools. Actions go through the same
// executor, range checks and metering as the Claude agent.
import {SHOW_TOOL,MAX_TURNS} from './agent.mjs';
import {keys} from './keys.mjs';

export const OPENAI_MODEL='gpt-6.1-sol';
// USD per million tokens for GPT-6.1 Sol (verified 2026-10-16), i.e. micro-dollars per token.
const RATES={input:2,cached:0.1,write:2.5,output:10};
const SEARCH_MICROS=10_000; // Web search calls: $10 per 1,000 (verify against OpenAI pricing).
const fail=text=>{throw new Error(text);};

export function openaiCost(data){
  const u=data?.usage??{};
  const count=value=>{const n=value??0;if(!Number.isSafeInteger(n)||n<0)fail('Unexpected OpenAI usage report');return n;};
  const input=count(u.input_tokens),cached=count(u.input_tokens_details?.cached_tokens),write=count(u.input_tokens_details?.cache_write_tokens),output=count(u.output_tokens);
  const searches=(data?.output??[]).filter(item=>item?.type==='web_search_call').length;
  return Math.ceil(Math.max(0,input-cached-write)*RATES.input+cached*RATES.cached+write*RATES.write+output*RATES.output+searches*SEARCH_MICROS);
}

export async function callOpenAI(body,{signal,fetchImpl=fetch,key=keys.read('openai')}={}){
  if(!key)throw Object.assign(new Error('Connect your OpenAI API key in the Nova app first.'),{unbilled:true});
  let response;
  try{
    response=await fetchImpl('https://api.openai.com/v1/responses',{method:'POST',redirect:'error',
      signal:AbortSignal.any([signal,AbortSignal.timeout(300000)]),
      headers:{'content-type':'application/json',authorization:`Bearer ${key}`},body:JSON.stringify(body)});
  }catch(error){
    if(error.name==='TimeoutError')fail('OpenAI took more than five minutes to answer.');
    throw error;
  }
  const data=await response.json().catch(()=>null);
  if(!response.ok){
    // Provider error bodies can echo request content; log only the type.
    const code=String(data?.error?.code??data?.error?.type??'');
    console.error(`OpenAI request failed: HTTP ${response.status} ${code}`);
    const error=new Error(code==='insufficient_quota'?"Your OpenAI API account is out of credits. ChatGPT Plus or Pro doesn't include API use; add credits at platform.openai.com."
      :[401,403].includes(response.status)?'OpenAI rejected the API key. Check it in the Nova app.'
      :response.status===429?'OpenAI is rate limiting your key. Try again in a minute.'
      :code==='model_not_found'?`Your OpenAI project can't use ${OPENAI_MODEL}.`
      :'OpenAI could not complete this request.');
    error.unbilled=true;
    throw error;
  }
  return data;
}

const KEYS={ENTER:'return',RETURN:'return',ESC:'escape',ESCAPE:'escape',TAB:'tab',SPACE:'space',BACKSPACE:'backspace',DELETE:'delete',DEL:'delete',
  HOME:'home',END:'end',PAGEUP:'page_up',PAGEDOWN:'page_down',UP:'up',DOWN:'down',LEFT:'left',RIGHT:'right',ARROWUP:'up',ARROWDOWN:'down',
  ARROWLEFT:'left',ARROWRIGHT:'right',CTRL:'ctrl',CONTROL:'ctrl',SHIFT:'shift',OPTION:'alt',ALT:'alt',META:'cmd',CMD:'cmd',COMMAND:'cmd',SUPER:'cmd',WIN:'cmd',CAPSLOCK:'capslock'};
const keyName=k=>KEYS[String(k).toUpperCase()]??String(k).toLowerCase();
const modifiers=keys=>Array.isArray(keys)&&keys.length?{text:keys.map(keyName).join('+')}:{};
const point=(x,y)=>{if(!Number.isFinite(x)||!Number.isFinite(y))fail('Missing coordinates');return [x,y];};
const pathPoint=p=>Array.isArray(p)?point(p[0],p[1]):point(p?.x,p?.y);

/// Translates one OpenAI computer action into Nova's executor actions (the Claude toolset's names).
export function translateAction(action){
  switch(action?.type){
    case 'screenshot':return null;
    case 'wait':return {action:'wait'};
    case 'click':{
      const name={left:'left_click',right:'right_click',wheel:'middle_click',middle:'middle_click'}[action.button??'left'];
      if(!name)fail(`The ${action.button} mouse button isn't supported`);
      return {action:name,coordinate:point(action.x,action.y),...modifiers(action.keys)};
    }
    case 'double_click':return {action:'double_click',coordinate:point(action.x,action.y),...modifiers(action.keys)};
    case 'move':return {action:'mouse_move',coordinate:point(action.x,action.y)};
    case 'drag':{
      const path=(action.path??[]).map(pathPoint);
      if(path.length<2)fail('A drag needs at least two points');
      return {action:'left_click_drag',start_coordinate:path[0],coordinate:path.at(-1),...modifiers(action.keys)};
    }
    case 'scroll':{
      const dx=Number(action.scroll_x)||0,dy=Number(action.scroll_y)||0;
      const vertical=Math.abs(dy)>=Math.abs(dx),amount=Math.max(1,Math.min(15,Math.round(Math.abs(vertical?dy:dx)/100)||1));
      return {action:'scroll',coordinate:point(action.x,action.y),scroll_direction:vertical?(dy>0?'down':'up'):(dx>0?'right':'left'),scroll_amount:amount,...modifiers(action.keys)};
    }
    case 'keypress':{
      if(!Array.isArray(action.keys)||!action.keys.length)fail('No keys to press');
      return {action:'key',text:action.keys.map(keyName).join('+')};
    }
    case 'type':return {action:'type',text:String(action.text??'')};
    default:fail(`Unsupported computer action ${action?.type}`);
  }
}

const asFunction=tool=>({type:'function',name:tool.name,description:tool.description,parameters:tool.input_schema,strict:false});
const textOf=output=>output.filter(i=>i.type==='message').flatMap(i=>i.content??[])
  .map(c=>c.type==='output_text'?c.text:c.type==='refusal'?c.refusal:'').join('').trim();

/// One agent loop with the same contract as runAgent in agent.mjs.
export async function runOpenAIAgent({task,history=[],execute,spend,onNarration=()=>{},onAction=()=>{},onScreen=()=>{},onVisual=()=>{},onTool,tools:extra=[],computer=true,system,signal,maxTurns=MAX_TURNS,call=callOpenAI}){
  const custom=new Set(extra.map(t=>t.name));
  const tools=[...(computer?[{type:'computer'}]:[]),{type:'web_search'},...[...extra,SHOW_TOOL].map(asFunction)];
  let input=[...history.map(m=>({role:m.role,content:typeof m.content==='string'?m.content:JSON.stringify(m.content)})),{role:'user',content:task}];
  let previous=null,actions=0,visual=null;
  const visuals=[];
  for(let turn=0;turn<maxTurns;turn++){
    if(signal.aborted)fail('Task cancelled');
    const body={model:OPENAI_MODEL,instructions:system,input,tools,reasoning:{effort:'low'},max_output_tokens:8192,truncation:'auto',...(previous?{previous_response_id:previous}:{})};
    const data=await spend(turn,()=>call(body,{signal}));
    if(!Array.isArray(data?.output)||typeof data.id!=='string')fail('OpenAI returned an unexpected response.');
    previous=data.id;
    const text=textOf(data.output);
    const calls=data.output.filter(i=>i.type==='computer_call'||i.type==='function_call');
    if(!calls.length)return {message:text||'Done.',turns:turn+1,actions,visual,visuals};
    if(text)onNarration(text);
    input=[];
    let paused=false;
    for(const item of calls){
      if(item.type==='function_call'){
        let args,output,failed=false;
        try{args=JSON.parse(item.arguments||'{}');}catch{args=null;}
        try{
          if(!args)fail('Arguments were not valid JSON');
          if(item.name==='show'){
            const spec=JSON.stringify(args);
            if(spec.length>30000||!['graph','chart','board','cards','table'].includes(args.type))fail('Visual too large or of unknown type.');
            visual=args;visuals.push(args);onVisual(spec);output="Shown on Matthew's iPhone.";
          }else if(custom.has(item.name))output=String(await onTool(item.name,args));
          else fail(`Unknown tool ${item.name}`);
        }catch(error){failed=true;output=String(error.message);}
        input.push({type:'function_call_output',call_id:item.call_id,output:(failed?`Error: ${output}`:output).slice(0,4000)});
        continue;
      }
      if(!computer)fail('OpenAI asked to use the computer, which is off in this range.');
      // A safety check means OpenAI wants a person to confirm this step. Nova stops instead of auto-approving.
      if(item.pending_safety_checks?.length)fail(`OpenAI paused for a safety check (${item.pending_safety_checks.map(c=>c.message||c.code).join('; ').slice(0,200)}). I stopped so you can decide.`);
      let problem=null;
      for(const raw of item.actions??(item.action?[item.action]:[])){
        if(signal.aborted)fail('Task cancelled');
        // Actions planned before a takeover would land on a screen that has since changed.
        if(paused){problem='Skipped because Matthew took over. Look at the new screenshot before acting again.';break;}
        try{
          const request=translateAction(raw);
          if(!request)continue;
          if(request.action==='wait'){await new Promise(ok=>setTimeout(ok,1000));continue;}
          actions++;
          const {action:name,...shown}=request;onAction(name,shown);
          const result=await execute(request);
          if(result?.paused){paused=true;problem=result.text;break;}
        }catch(error){
          if(signal.aborted||error.fatal||/Stopped on the Mac/.test(error.message))throw error;
          problem=`That action failed: ${String(error.message).slice(0,400)}`;
          break;
        }
      }
      const shot=await execute({action:'screenshot'});
      if(typeof shot?.image!=='string')fail('The Mac did not return a screenshot.');
      onScreen(shot.image);
      input.push({type:'computer_call_output',call_id:item.call_id,output:{type:'computer_screenshot',image_url:`data:image/jpeg;base64,${shot.image}`,detail:'original'}});
      if(problem)input.push({role:'user',content:[{type:'input_text',text:problem}]});
    }
  }
  return {message:`I stopped after ${maxTurns} rounds. Ask me to keep going if you want me to continue.`,turns:maxTurns,actions,visual,visuals};
}
