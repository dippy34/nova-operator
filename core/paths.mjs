// One place decides where Nova's code, runtime and saved data live, so Core, the CLI, the
// login service and the native executor's build agree. Code and runtime are read-only;
// everything Nova writes goes in the data directory.
//
// Two layouts:
// - development (default): a source checkout. Data stays in <checkout>/.nova-data, as before.
// - app: Core packaged at Nova Operator.app/Contents/Resources, marked by a signed
//   nova-runtime.json. Data lives in ~/Library/Application Support/Nova Operator.
// NOVA_DATA_DIR moves all data (isolated tests use it). NOVA_DB still overrides only the
// database, which existing development services set.
import {existsSync,readFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {basename,dirname,join,relative,resolve,isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';

export const MANIFEST='nova-runtime.json';
export const APP_SUPPORT='Nova Operator';
// The native executor builds the same names from its signed Info.plist; paths.test.mjs checks both.
export const FILES=Object.freeze({db:'nova.sqlite',operatorKey:'operator.key',nonces:'operator-nonces',socket:'operator.sock',
  log:'core.log',errorLog:'core-error.log',operatorApp:'Nova Operator.app',operatorExecutable:'NovaOperator',runtime:'node'});
const sourceRoot=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const fail=text=>{throw new Error(text);};
const inside=(parent,child)=>{const path=relative(parent,child);return path===''||(!path.startsWith('..')&&!isAbsolute(path));};

/// Returns null for a source checkout. A present but unreadable or unknown manifest is an error,
/// never a silent fallback that would put saved data inside the app.
export function readManifest(root){
  const file=join(root,MANIFEST);
  if(!existsSync(file))return null;
  let manifest;
  try{manifest=JSON.parse(readFileSync(file,'utf8'));}catch{fail(`Nova's ${MANIFEST} is unreadable. Reinstall Nova.`);}
  if(manifest?.layout!=='app')fail(`Nova's ${MANIFEST} has an unsupported layout. Reinstall Nova.`);
  return manifest;
}

export function resolvePaths({root=sourceRoot,env=process.env,home=homedir(),execPath=process.execPath}={}){
  root=resolve(root);
  const manifest=readManifest(root);
  const layout=manifest?'app':'development';
  let bundle=null;
  if(layout==='app'){
    bundle=resolve(root,'..','..');
    if(basename(root)!=='Resources'||basename(dirname(root))!=='Contents'||!bundle.endsWith('.app'))fail('Packaged Nova Core must be inside an app’s Contents/Resources.');
  }
  const support=join(home,'Library','Application Support',APP_SUPPORT);
  const data=env.NOVA_DATA_DIR?resolve(env.NOVA_DATA_DIR):layout==='app'?support:join(root,'.nova-data');
  const db=env.NOVA_DB?resolve(env.NOVA_DB):join(data,FILES.db);
  if(bundle&&(inside(bundle,data)||inside(bundle,db)))fail('Nova’s saved data cannot live inside the app.');
  const operatorApp=bundle??join(data,FILES.operatorApp);
  return Object.freeze({
    layout,root,bundle,manifest,
    core:join(root,'core'),
    // The packaged service starts the app's own runtime; development uses whichever Node runs this.
    runtime:bundle?join(bundle,'Contents','Helpers',FILES.runtime):execPath,
    data,
    db,
    operatorKey:join(data,FILES.operatorKey),
    operatorNonces:join(data,FILES.nonces),
    log:join(data,FILES.log),
    errorLog:join(data,FILES.errorLog),
    operatorApp,
    operatorBinary:join(operatorApp,'Contents','MacOS',FILES.operatorExecutable),
    // Short fixed location: sun_path allows 104 bytes, which a checkout path can exceed.
    socket:join(support,FILES.socket),
    // The private pre-Keychain key file only exists in development checkouts.
    legacyEnv:layout==='development'?join(root,'.env.local'):null,
    workspace:env.NOVA_WORKSPACE?resolve(env.NOVA_WORKSPACE):null,
    port:Number(env.NOVA_PORT??8787)
  });
}

export const paths=resolvePaths();
