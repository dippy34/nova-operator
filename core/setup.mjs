// Setup helpers shared by Core's HTTP API, the CLI and the Mac app: what the phone shows
// while pairing, choosing a range and connecting an AI. Nothing here grants access by itself;
// every change still goes through an authenticated owner request or a local command.
import {execFile,execFileSync} from 'node:child_process';
import {promisify} from 'node:util';
import {homedir,hostname} from 'node:os';
import {readdirSync,existsSync} from 'node:fs';
import {join,basename} from 'node:path';
import {readAccess,validateFolders,LEVEL_TEXT} from './policy.mjs';
import {providerStatus} from './keys.mjs';

const execFileAsync=promisify(execFile);

let name=null;
/// The name people know this computer by, like "Matthew's MacBook Air".
export function computerName(){
  if(name)return name;
  try{name=execFileSync('/usr/sbin/scutil',['--get','ComputerName'],{encoding:'utf8',timeout:3000,stdio:['ignore','pipe','ignore']}).trim();}catch{}
  return name||=hostname().replace(/\.local$/,'');
}

/// The QR code holds the Core address, a one-time code and the computer's name. Never a provider key.
export const pairingLink=({url,code,name})=>`nova://pair?v=1&u=${encodeURIComponent(url)}&c=${encodeURIComponent(code)}&n=${encodeURIComponent(name)}`;

/// Wrong pairing codes are limited per Core: after `max` failures in `windowMs`, pairing is
/// refused for `lockMs` and every outstanding code is cancelled, so a typed 8-character code
/// can't be guessed.
export function createPairingGuard({max=10,windowMs=10*60_000,lockMs=10*60_000,now=Date.now}={}){
  let failures=[],lockedUntil=0;
  return {
    locked(){return now()<lockedUntil;},
    /// Records a failure. Returns true when this failure starts a lockout.
    fail(){
      const t=now();
      failures=[...failures.filter(at=>t-at<windowMs),t];
      if(failures.length<max)return false;
      failures=[];lockedUntil=t+lockMs;
      return true;
    }
  };
}

let apps=null;
const APP_DIRS=()=>['/Applications','/Applications/Utilities','/System/Applications','/System/Applications/Utilities',join(homedir(),'Applications')];
/// Apps installed on this Mac, for choosing which ones Nova may use. Cached for 5 minutes.
export async function installedApps({dirs=APP_DIRS(),read=readBundle}={}){
  if(apps&&Date.now()-apps.at<5*60_000)return apps.list;
  const paths=dirs.filter(existsSync).flatMap(dir=>{try{return readdirSync(dir).filter(n=>n.endsWith('.app')&&!n.startsWith('.')).map(n=>join(dir,n));}catch{return [];}});
  const found=new Map();
  for(let i=0;i<paths.length;i+=8){
    for(const app of await Promise.all(paths.slice(i,i+8).map(read)))
      if(app&&app.bundleId!=='dev.nova.operator.macos'&&!found.has(app.bundleId))found.set(app.bundleId,app);
  }
  const list=[...found.values()].sort((a,b)=>a.name.localeCompare(b.name));
  apps={at:Date.now(),list};
  return list;
}
async function readBundle(path){
  try{
    const {stdout}=await execFileAsync('/usr/bin/plutil',['-convert','json','-o','-',join(path,'Contents','Info.plist')],{timeout:5000,maxBuffer:4*1024*1024});
    const info=JSON.parse(stdout);
    if(typeof info.CFBundleIdentifier!=='string'||info.LSBackgroundOnly===true)return null;
    const shown=[info.CFBundleDisplayName,info.CFBundleName].find(v=>typeof v==='string'&&v.trim())??basename(path,'.app');
    return {bundleId:info.CFBundleIdentifier,name:String(shown).trim().slice(0,60)};
  }catch{return null;}
}

const COMMON=['Desktop','Documents','Downloads','Pictures','Music','Movies'];
/// Folders the owner can choose from: the usual home folders, or the subfolders of one of them.
/// Only paths that would pass the same check as the final choice are listed.
export function listFolders(parent,{home=homedir()}={}){
  const tilde=path=>path.startsWith(home+'/')?`~/${path.slice(home.length+1)}`:path;
  if(!parent||parent==='~'){
    return COMMON.map(n=>join(home,n)).filter(existsSync).map(path=>({path:tilde(path),name:basename(path)}));
  }
  const [real]=validateFolders([parent],{home});
  let entries;
  try{entries=readdirSync(real,{withFileTypes:true});}catch{return [];}
  return entries.filter(e=>e.isDirectory()&&!e.name.startsWith('.')).slice(0,200)
    .map(e=>({path:tilde(join(real,e.name)),name:e.name})).sort((a,b)=>a.name.localeCompare(b.name));
}

/// Everything the phone needs to show where setup stands. Never includes a key.
export async function setupStatus(store,device,{keyStore,permissionCheck,owner}){
  const access=readAccess(store),ai=providerStatus(store,keyStore);
  const status={
    computer:{name:computerName(),platform:'macos'},
    device:{id:device.id,name:device.name,owner},
    stopped:store.stopped(),
    access:{...access,folders:access.folders.map(f=>f.startsWith(homedir()+'/')?`~/${f.slice(homedir().length+1)}`:f),levels:LEVEL_TEXT},
    ai
  };
  if(!owner)return status;
  const permission=await permissionCheck();
  status.permissions={installed:permission.installed!==false,running:permission.running!==false,accessibility:Boolean(permission.accessibility),screenRecording:Boolean(permission.screenRecording)};
  status.steps={
    paired:true,
    range:access.chosen,
    permissions:access.level==='chat'||(status.permissions.accessibility&&status.permissions.screenRecording),
    ai:ai[ai.selected].configured
  };
  return status;
}
