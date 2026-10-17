// Nova's range: what the AI may access on this computer. Platform-neutral so other
// clients (Android) and executors (Windows) can share the same contract; see
// docs/PAIRING-PROTOCOL.md. Every check here is deterministic code, never a model.
import {homedir} from 'node:os';
import {realpathSync,statSync,lstatSync,readdirSync,readFileSync,writeFileSync} from 'node:fs';
import {resolve,relative,isAbsolute,sep,dirname,basename,join} from 'node:path';

export const LEVELS=['chat','apps','full'];
export const MAX_APPS=30, MAX_FOLDERS=10;
const fail=text=>{throw new Error(text);};

export const LEVEL_TEXT={
  chat:'Just chat: Nova talks, searches the web and runs research agents. It cannot see or use the Mac.',
  apps:'Chosen apps & folders: Nova sees and uses only the chosen apps and reads only the chosen folders.',
  full:'Whole Mac: Nova sees the whole screen and uses any app with the mouse and keyboard, without asking.'
};

/// Reads the current range. Installs from before ranges existed were migrated to "full" by the Store.
export function readAccess(store){
  const level=store.setting('access_level');
  const json=(key)=>{try{return JSON.parse(store.setting(key)??'[]');}catch{return [];}};
  return {level:LEVELS.includes(level)?level:'chat',apps:json('access_apps'),folders:json('access_folders'),chosen:store.setting('access_chosen')==='1'};
}

export function validateApps(apps){
  if(!Array.isArray(apps)||apps.length>MAX_APPS)fail(`Choose at most ${MAX_APPS} apps`);
  const seen=new Set();
  return apps.map(app=>{
    const bundleId=String(app?.bundleId??''),name=String(app?.name??'').trim().slice(0,60);
    if(!/^[A-Za-z0-9][A-Za-z0-9.-]{1,154}$/.test(bundleId))fail('Unknown app');
    if(['dev.nova.operator.macos'].includes(bundleId))fail('Nova Operator cannot be one of the chosen apps');
    if(seen.has(bundleId))return null;
    seen.add(bundleId);
    return {bundleId,name:name||bundleId};
  }).filter(Boolean);
}

// Hidden files and folders often hold secrets (.env, .ssh, .aws, .git), so they are never reachable.
const hiddenSegment=path=>path.split(sep).some(part=>part.startsWith('.'));
export function sensitiveRoots(home=homedir()){
  return [join(home,'Library'),join(home,'Applications')];
}

export function validateFolders(folders,{home=homedir()}={}){
  if(!Array.isArray(folders)||folders.length>MAX_FOLDERS)fail(`Choose at most ${MAX_FOLDERS} folders`);
  const realHome=realpathSync(home),out=[];
  for(const raw of folders){
    const text=String(raw??'').trim();
    const path=text==='~'?home:text.startsWith('~/')?join(home,text.slice(2)):text;
    if(!isAbsolute(path))fail('Folders must be full paths like ~/Documents');
    let real;
    try{real=realpathSync(path);}catch{fail(`${text} doesn't exist on the Mac`);}
    if(!statSync(real).isDirectory())fail(`${text} is not a folder`);
    const inside=relative(realHome,real);
    if(real!==realHome&&(inside.startsWith('..')||isAbsolute(inside)))fail('Folders must be inside your home folder');
    if(real===realHome)fail('Choose specific folders, not your whole home folder');
    if(hiddenSegment(inside))fail('Hidden folders cannot be chosen');
    if(sensitiveRoots(realHome).some(root=>real===root||real.startsWith(root+sep)))fail('That folder holds app data and cannot be chosen');
    if(!out.includes(real))out.push(real);
  }
  return out;
}

/// The scope Core signs into every request to the Mac executor. The model never sets it.
export function executorScope(access){
  if(access.level==='full')return {mode:'full'};
  if(access.level==='apps')return {mode:'apps',apps:access.apps.map(a=>a.bundleId)};
  fail("Nova's range is Just chat, so it can't see or use the Mac. Change it in the Nova app.");
}

// Shortcuts that act outside the frontmost app (Spotlight, app switching, Mission Control,
// screenshots, logging out) are refused in "Chosen apps" mode. The Mac executor repeats this check.
const BLOCKED_COMBOS=new Set(['cmd+space','cmd+tab','cmd+shift+tab','cmd+shift+3','cmd+shift+4','cmd+shift+5','cmd+shift+6','cmd+shift+q','alt+space','cmd+alt+escape','cmd+alt+d']);
const MODIFIERS={ctrl:'ctrl',control:'ctrl',alt:'alt',option:'alt',opt:'alt',shift:'shift',super:'cmd',cmd:'cmd',command:'cmd',meta:'cmd',win:'cmd',fn:'fn'};
export function scopedKeyAllowed(text){
  const parts=String(text).toLowerCase().split('+').filter(Boolean);
  if(!parts.length)return false;
  const key=parts.at(-1),mods=new Set(parts.slice(0,-1).map(m=>MODIFIERS[m]??'?'));
  if(mods.has('?')||mods.has('ctrl')||mods.has('fn'))return false;
  if(mods.has('cmd')&&mods.has('alt'))return false;
  if(/^f\d{1,2}$/.test(key))return false;
  const canonical=[...['cmd','alt','shift'].filter(m=>mods.has(m)),key==='esc'?'escape':key].join('+');
  return !BLOCKED_COMBOS.has(canonical);
}

/// Checks one computer action against the range before it is signed and sent.
export function checkAction(access,request){
  const scope=executorScope(access);
  if(scope.mode==='apps'){
    if(['key','hold_key'].includes(request.action)&&!scopedKeyAllowed(request.text))fail(`${request.text} works outside the chosen apps, so Nova can't press it in this range`);
    if(request.text&&['left_click','right_click','middle_click','double_click','triple_click','scroll','left_click_drag'].includes(request.action)&&!scopedKeyAllowed(`${request.text}+a`))fail('Those modifier keys are not available in this range');
  }
  return scope;
}

// ---- Folder tools -------------------------------------------------------------------------

const MAX_READ=100_000, MAX_WRITE=200_000, MAX_LIST=200;

function locate(folders,raw,{home=homedir()}={}){
  const text=String(raw??'').trim();
  if(!text)fail('Give a path');
  const path=text.startsWith('~/')?join(home,text.slice(2)):text;
  if(!isAbsolute(path))fail('Use a full path, like ~/Documents/notes.txt');
  return resolve(path);
}
function within(folders,real){
  return folders.some(folder=>{
    const inside=relative(folder,real);
    return real===folder||(!inside.startsWith('..')&&!isAbsolute(inside)&&!hiddenSegment(inside));
  });
}
const outside="That path is outside the folders Nova may use";

export const FILE_TOOLS=[
  {name:'list_folder',description:"List files in one of the folders Matthew chose for Nova. Hidden files are not shown.",
    input_schema:{type:'object',additionalProperties:false,required:['path'],properties:{path:{type:'string',description:'Full path, e.g. ~/Documents'}}}},
  {name:'read_file',description:'Read a text file inside the folders Matthew chose (up to 100 KB).',
    input_schema:{type:'object',additionalProperties:false,required:['path'],properties:{path:{type:'string'}}}},
  {name:'create_file',description:'Create a new text file inside the chosen folders. Never overwrites an existing file.',
    input_schema:{type:'object',additionalProperties:false,required:['path','text'],properties:{path:{type:'string'},text:{type:'string',maxLength:MAX_WRITE}}}}
];

export function fileTool(access,name,input,{home=homedir()}={}){
  if(access.level==='chat'||!access.folders.length)fail('Nova has no folders to use. Choose folders in the Nova app.');
  const folders=access.folders.map(f=>{try{return realpathSync(f);}catch{return null;}}).filter(Boolean);
  const path=locate(folders,input?.path,{home});
  if(name==='create_file'){
    const text=String(input?.text??'');
    if(Buffer.byteLength(text)>MAX_WRITE)fail('That file is too large');
    let parent;
    try{parent=realpathSync(dirname(path));}catch{fail("That folder doesn't exist");}
    const target=join(parent,basename(path));
    if(basename(path).startsWith('.')||!within(folders,target))fail(outside);
    try{writeFileSync(target,text,{flag:'wx',mode:0o644});}
    catch(error){fail(error.code==='EEXIST'?'A file with that name already exists':'Could not create the file');}
    return `Created ${target}`;
  }
  let real;
  try{real=realpathSync(path);}catch{fail("That path doesn't exist");}
  if(!within(folders,real))fail(outside);
  if(name==='list_folder'){
    if(!statSync(real).isDirectory())fail('That is a file, not a folder');
    const entries=readdirSync(real,{withFileTypes:true}).filter(e=>!e.name.startsWith('.')).slice(0,MAX_LIST).map(e=>{
      const full=join(real,e.name);let size=null,modified=null;
      try{const s=lstatSync(full);size=s.isFile()?s.size:null;modified=s.mtime.toISOString().slice(0,16);}catch{}
      return `${e.isDirectory()?'folder':'file'}\t${e.name}${size!==null?`\t${size} bytes`:''}${modified?`\t${modified}`:''}`;
    });
    return entries.length?entries.join('\n'):'The folder is empty.';
  }
  if(name==='read_file'){
    const stats=statSync(real);
    if(!stats.isFile())fail('That is a folder, not a file');
    if(stats.size>MAX_READ)fail('That file is larger than 100 KB');
    const data=readFileSync(real);
    if(data.includes(0))fail('That file is not text');
    return data.toString('utf8');
  }
  fail(`Unknown tool ${name}`);
}

export const OPEN_APP_TOOL={name:'open_app',description:'Open or switch to one of the apps Matthew chose for Nova. Use this instead of Spotlight, the Dock or app switching, which are not available in this range.',
  input_schema:{type:'object',additionalProperties:false,required:['app'],properties:{app:{type:'string',description:'App name, e.g. Notes'}}}};

export function findApp(access,name){
  const wanted=String(name??'').trim().toLowerCase();
  const app=access.apps.find(a=>a.name.toLowerCase()===wanted||a.bundleId.toLowerCase()===wanted)
    ??access.apps.find(a=>a.name.toLowerCase().includes(wanted)&&wanted.length>=3);
  if(!app)fail(`${name} isn't one of the apps Nova may use. Allowed: ${access.apps.map(a=>a.name).join(', ')||'none'}`);
  return app;
}

/// One line for the model's instructions. Enforcement does not depend on the model reading it.
export function rangeNote(access){
  if(access.level==='chat')return "Range: Just chat. You cannot see or use the Mac, and remote control is off. If Matthew asks for something on the Mac, explain that he can change Nova's range in the Nova app (press and hold the face, then Range).";
  const folders=access.folders.length?` You may read and create files in these folders with the file tools: ${access.folders.join(', ')}.`:'';
  if(access.level==='apps')return `Range: Chosen apps & folders. You can only see and use these apps: ${access.apps.map(a=>a.name).join(', ')||'none'}. Other apps, the menu bar, the Dock and the desktop are hidden from your screenshots and blocked. Open allowed apps with open_app; global shortcuts like Spotlight and app switching are blocked.${folders}`;
  return `Range: Whole Mac.${folders}`;
}
