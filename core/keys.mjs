// AI provider keys live in the Mac's login Keychain. They are never logged, returned by the API,
// put in QR codes or written to the repository. The old private .env.local file still works
// for Claude so existing setups keep running.
import {execFileSync,spawnSync} from 'node:child_process';
import {readFileSync,statSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {fileURLToPath} from 'node:url';

export const PROVIDERS={
  anthropic:{label:'Claude',company:'Anthropic',pattern:/^sk-ant-[A-Za-z0-9_-]{20,300}$/,legacy:'ANTHROPIC_API_KEY',keysURL:'https://console.anthropic.com/settings/keys'},
  openai:{label:'OpenAI',company:'OpenAI',pattern:/^sk-[A-Za-z0-9_-]{20,400}$/,keysURL:'https://platform.openai.com/api-keys'}
};
const SERVICE='dev.nova.provider';
const legacyFile=fileURLToPath(new URL('../.env.local',import.meta.url));
const CACHE_MS=30_000;
const fail=text=>{throw new Error(text);};

function legacyKey(provider,file){
  const name=PROVIDERS[provider]?.legacy;
  if(!name)return '';
  try{
    if(statSync(file).mode&0o077)return '';
    const key=parseEnv(readFileSync(file,'utf8'))[name];
    return typeof key==='string'&&PROVIDERS[provider].pattern.test(key)?key:'';
  }catch{return '';}
}

/// `run(args, input)` runs /usr/bin/security and returns {status, stdout}. Tests replace it.
export function createKeyStore({run=securityRun,file=legacyFile}={}){
  const cache=new Map();
  const keychain=provider=>{
    const hit=cache.get(provider);
    if(hit&&Date.now()-hit.at<CACHE_MS)return hit.value;
    const result=run(['find-generic-password','-s',SERVICE,'-a',provider,'-w']);
    const value=result.status===0?String(result.stdout).trim():'';
    const valid=PROVIDERS[provider].pattern.test(value)?value:'';
    cache.set(provider,{value:valid,at:Date.now()});
    return valid;
  };
  const known=provider=>{if(!PROVIDERS[provider])fail('Unknown AI provider');};
  return {
    read(provider){known(provider);return keychain(provider)||legacyKey(provider,file);},
    storage(provider){known(provider);return keychain(provider)?'keychain':legacyKey(provider,file)?'file':null;},
    save(provider,key){
      known(provider);
      const value=String(key??'').trim();
      if(!PROVIDERS[provider].pattern.test(value))fail(provider==='anthropic'?'That doesn\'t look like a Claude API key. It starts with sk-ant-.':'That doesn\'t look like an OpenAI API key. It starts with sk-.');
      // `security -i` reads the command from stdin, so the key never appears in a process list.
      // The pattern above allows only characters that need no quoting.
      const result=run(['-i'],`add-generic-password -U -s ${SERVICE} -a ${provider} -l "Nova ${PROVIDERS[provider].label} API key" -w ${value}\n`);
      cache.delete(provider);
      if(result.status!==0||keychain(provider)!==value)fail('Could not save the key in the Mac\'s Keychain');
    },
    remove(provider){
      known(provider);
      run(['delete-generic-password','-s',SERVICE,'-a',provider]);
      cache.delete(provider);
    },
    /// Moves the legacy .env.local key into the Keychain. The file is left for Matthew to delete.
    importLegacy(){
      const key=legacyKey('anthropic',file);
      if(!key)fail('No Claude key found in .env.local');
      this.save('anthropic',key);
    }
  };
}

function securityRun(args,input){
  if(input===undefined){
    try{return {status:0,stdout:execFileSync('/usr/bin/security',args,{encoding:'utf8',stdio:['ignore','pipe','ignore'],timeout:5000})};}
    catch(error){return {status:error.status??1,stdout:''};}
  }
  const result=spawnSync('/usr/bin/security',args,{input,encoding:'utf8',stdio:['pipe','ignore','ignore'],timeout:10000});
  return {status:result.status??1,stdout:''};
}

export const keys=createKeyStore();

/// A key store held in memory, for tests and for platforms whose secure storage isn't wired yet.
export function memoryKeyStore(initial={}){
  const saved={...initial};
  const known=provider=>{if(!PROVIDERS[provider])fail('Unknown AI provider');};
  return {
    read(provider){known(provider);return saved[provider]??'';},
    storage(provider){known(provider);return saved[provider]?'keychain':null;},
    save(provider,key){known(provider);if(!PROVIDERS[provider].pattern.test(String(key)))fail('Invalid key');saved[provider]=String(key);},
    remove(provider){known(provider);delete saved[provider];},
    importLegacy(){fail('No Claude key found in .env.local');}
  };
}

export function selectedProvider(store,keyStore=keys){
  const chosen=store.setting('ai_provider');
  if(PROVIDERS[chosen])return chosen;
  return keyStore.read('anthropic')||!keyStore.read('openai')?'anthropic':'openai';
}

export function providerStatus(store,keyStore=keys){
  return {selected:selectedProvider(store,keyStore),
    anthropic:{configured:Boolean(keyStore.storage('anthropic')),storage:keyStore.storage('anthropic'),label:'Claude',model:'claude-sonnet-5-5'},
    openai:{configured:Boolean(keyStore.storage('openai')),storage:keyStore.storage('openai'),label:'OpenAI',model:'gpt-6.1-sol'}};
}

/// Checks a key with each provider's free model list. It never runs a billed request.
/// Messages are written for people and never include the key or the provider's response body.
export async function testKey(provider,key,{fetchImpl=fetch,timeout=15000}={}){
  const signal=AbortSignal.timeout(timeout);
  let response;
  try{
    response=provider==='anthropic'
      ?await fetchImpl('https://api.anthropic.com/v1/models?limit=100',{redirect:'error',signal,headers:{'x-api-key':key,'anthropic-version':'2023-06-01'}})
      :await fetchImpl('https://api.openai.com/v1/models',{redirect:'error',signal,headers:{authorization:`Bearer ${key}`}});
  }catch{
    return {ok:false,code:'network',message:`Couldn't reach ${PROVIDERS[provider].company} from your Mac. Check the Mac's internet connection and try again.`};
  }
  const name=PROVIDERS[provider].company;
  if(response.status===401)return {ok:false,code:'rejected',message:`${name} rejected that key. Copy it again from ${provider==='anthropic'?'Claude Console':'the OpenAI API dashboard'}; it may have been deleted or mistyped.`};
  if(response.status===403)return {ok:false,code:'forbidden',message:`${name} accepted the key but it doesn't have permission to list models. Check the key's project and permissions.`};
  if(response.status===429)return {ok:false,code:'limited',message:`${name} is rate limiting this key right now. Wait a minute and try again.`};
  if(!response.ok)return {ok:false,code:'unavailable',message:`${name} had a problem (HTTP ${response.status}). Try again in a few minutes.`};
  const data=await response.json().catch(()=>null);
  const ids=new Set((data?.data??[]).map(m=>m?.id));
  if(provider==='anthropic')return {ok:true,code:'ok',message:ids.has('claude-sonnet-5-5')||!ids.size?'Claude is connected.':'Claude is connected, but this key doesn\'t list Claude Sonnet 5.5. Nova may not be able to use your Mac.'};
  return {ok:true,code:'ok',message:(ids.has('gpt-6.1-sol')||!ids.size?'OpenAI accepted the key.':'OpenAI accepted the key, but this project doesn\'t list GPT-6.1 Sol, which Nova uses.')
    +' OpenAI bills API use separately from ChatGPT Plus or Pro, so make sure your API account has credits.'};
}
