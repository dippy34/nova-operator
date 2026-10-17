// Packages a self-contained Nova Operator.app into a chosen output folder: the native executor,
// an explicit list of Core files and a pinned Node runtime whose archive checksum and Developer ID
// signature are verified. The finished bundle is audited against an exact list of expected files,
// so .env.local, .nova-data, databases, keys, signing files and local notes cannot enter it.
//
// This is a build mode, not an installer: it never touches the running development services,
// LaunchAgents, saved data or the existing signed app.
import {execFileSync,spawnSync} from 'node:child_process';
import {createHash,randomBytes} from 'node:crypto';
import {copyFileSync,existsSync,lstatSync,mkdirSync,readFileSync,readdirSync,renameSync,rmSync,writeFileSync,chmodSync} from 'node:fs';
import {homedir} from 'node:os';
import {join,relative,resolve,isAbsolute} from 'node:path';
import {pathToFileURL} from 'node:url';
import {paths as defaultPaths,MANIFEST,FILES} from '../core/paths.mjs';
import {infoPlist} from './build.mjs';

export const runtime=JSON.parse(readFileSync(new URL('./runtime.json',import.meta.url),'utf8')).node;
// Adding a Core file to the app is deliberate; package.test.mjs checks this matches Core's imports.
export const CORE_FILES=Object.freeze(['agent.mjs','ai.mjs','brain-sandbox.mjs','claude-worker.mjs','cli.mjs','computer.mjs','db.mjs',
  'diagnostics.mjs','keys.mjs','openai.mjs','paths.mjs','policy.mjs','server.mjs','service.mjs','setup.mjs','tailscale.mjs','work.mjs']);
export const APP_VERSION='0.2.0';
const BUNDLE_ID='dev.nova.operator.macos';
const CACHE=join(homedir(),'Library','Caches','dev.nova.build');
const fail=text=>{throw new Error(text);};
const inside=(parent,child)=>{const path=relative(parent,child);return path===''||(!path.startsWith('..')&&!isAbsolute(path));};
const run=(file,args,options={})=>execFileSync(file,args,{encoding:'utf8',stdio:['ignore','pipe','pipe'],...options});

/// Every file a packaged app may contain, relative to the .app. Nothing else is allowed.
export function expectedFiles({signed=true}={}){
  return new Set(['Contents/Info.plist',`Contents/MacOS/${FILES.operatorExecutable}`,`Contents/Helpers/${FILES.runtime}`,
    `Contents/Resources/${MANIFEST}`,'Contents/Resources/licenses/node-LICENSE',...CORE_FILES.map(f=>`Contents/Resources/core/${f}`),
    ...(signed?['Contents/_CodeSignature/CodeResources']:[])]);
}

/// Fails on any unexpected file, missing file or symlink, naming the first problems.
export function audit(app,{signed=true}={}){
  const expected=expectedFiles({signed}),found=new Set(),problems=[];
  const walk=dir=>{for(const name of readdirSync(dir)){
    const full=join(dir,name),rel=relative(app,full),stat=lstatSync(full);
    if(stat.isSymbolicLink())problems.push(`symlink ${rel}`);
    else if(stat.isDirectory())walk(full);
    else if(expected.has(rel))found.add(rel);
    else problems.push(`unexpected ${rel}`);
  }};
  walk(app);
  for(const rel of expected)if(!found.has(rel))problems.push(`missing ${rel}`);
  if(problems.length)fail(`Packaged app failed its file audit: ${problems.slice(0,8).join(', ')}`);
  return [...found].sort();
}

export const sha256=file=>createHash('sha256').update(readFileSync(file)).digest('hex');

/// Downloads the pinned Node archive once into the build cache and refuses any other bytes.
export async function fetchRuntime({cache=CACHE,fetchImpl=fetch}={}){
  const archive=join(cache,runtime.archive);
  if(!existsSync(archive)){
    mkdirSync(cache,{recursive:true});
    const response=await fetchImpl(runtime.url);
    if(!response.ok)fail(`Could not download ${runtime.url}: HTTP ${response.status}`);
    const partial=`${archive}.${randomBytes(4).toString('hex')}.partial`;
    writeFileSync(partial,Buffer.from(await response.arrayBuffer()));
    renameSync(partial,archive);
  }
  const actual=sha256(archive);
  if(actual!==runtime.sha256){rmSync(archive,{force:true});fail(`${runtime.archive} checksum ${actual} does not match the pinned ${runtime.sha256}. It was deleted.`);}
  return archive;
}

/// Node's own notarized Developer ID signature is kept; re-signing would discard that provenance.
export function verifyRuntimeSignature(binary){
  run('/usr/bin/codesign',['--verify','--strict',binary]);
  // codesign prints its details on stderr.
  const info=spawnSync('/usr/bin/codesign',['-dv',binary],{encoding:'utf8'}).stderr;
  if(!info.split('\n').includes(`TeamIdentifier=${runtime.team}`))fail(`The bundled runtime is not signed by the expected team ${runtime.team}.`);
}

function buildInfo(root){
  try{return {commit:run('/usr/bin/git',['-C',root,'rev-parse','--short','HEAD']).trim(),
    modified:run('/usr/bin/git',['-C',root,'status','--porcelain','--untracked-files=no']).trim()!==''};}
  catch{return {commit:null,modified:null};}
}

/// Builds <out>/Nova Operator.app. Signs with `identity`; `adhoc` is for isolated local checks only.
export async function packageApp({out,identity=process.env.NOVA_MAC_SIGN_IDENTITY,adhoc=false,paths=defaultPaths,cache=CACHE}={}){
  if(process.platform!=='darwin'||process.arch!==runtime.arch)fail(`Packaging currently supports macOS ${runtime.arch} only.`);
  if(paths.layout!=='development')fail('Package Nova from a source checkout.');
  if(!out)fail('Choose an output folder with --out.');
  out=resolve(out);
  if(inside(paths.data,out))fail('The output folder cannot be inside Nova’s saved data.');
  const sign=adhoc?'-':identity;
  if(!sign)fail('Set NOVA_MAC_SIGN_IDENTITY, or pass --adhoc for a local check that is not distributable.');
  const target=join(out,FILES.operatorApp);
  if(existsSync(target)&&!existsSync(join(target,'Contents','Resources',MANIFEST)))fail(`${target} exists and is not a packaged Nova app. Choose another output folder.`);

  const archive=await fetchRuntime({cache});
  mkdirSync(out,{recursive:true});
  const staging=join(out,`.nova-package-${randomBytes(4).toString('hex')}`);
  const app=join(staging,FILES.operatorApp),contents=join(app,'Contents'),resources=join(contents,'Resources');
  try{
    for(const dir of ['MacOS','Helpers','Resources/core','Resources/licenses'])mkdirSync(join(contents,dir),{recursive:true});
    writeFileSync(join(contents,'Info.plist'),infoPlist({layout:'app'}));
    for(const file of CORE_FILES)copyFileSync(join(paths.core,file),join(resources,'core',file));
    const prefix=runtime.archive.replace(/\.tar\.gz$/,'');
    const unpack=join(staging,'runtime');mkdirSync(unpack);
    run('/usr/bin/tar',['-xzf',archive,'-C',unpack,`${prefix}/bin/node`,`${prefix}/LICENSE`]);
    copyFileSync(join(unpack,prefix,'bin','node'),join(contents,'Helpers',FILES.runtime));
    chmodSync(join(contents,'Helpers',FILES.runtime),0o755);
    copyFileSync(join(unpack,prefix,'LICENSE'),join(resources,'licenses','node-LICENSE'));
    rmSync(unpack,{recursive:true});
    verifyRuntimeSignature(join(contents,'Helpers',FILES.runtime));
    const pkg=JSON.parse(readFileSync(join(paths.root,'package.json'),'utf8'));
    // Only versions that exist today. The database has no schema version yet (B2 open item).
    writeFileSync(join(resources,MANIFEST),JSON.stringify({layout:'app',version:APP_VERSION,coreVersion:pkg.version,pairingProtocol:1,
      build:buildInfo(paths.root),runtime:{name:'node',version:runtime.version,arch:runtime.arch,archiveSha256:runtime.sha256}},null,2)+'\n');
    execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-O','-o',join(contents,'MacOS',FILES.operatorExecutable),join(paths.root,'macos','Operator.swift')],{stdio:['ignore','inherit','inherit']});
    audit(app,{signed:false});
    run('/usr/bin/codesign',['--force','--sign',sign,'--identifier',BUNDLE_ID,app]);
    run('/usr/bin/codesign',['--verify','--strict','--deep',app]);
    audit(app);
    if(existsSync(target))rmSync(target,{recursive:true});
    renameSync(app,target);
  }finally{rmSync(staging,{recursive:true,force:true});}
  return {app:target,signing:adhoc?'adhoc':'identity'};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
  const args=process.argv.slice(2),at=args.indexOf('--out');
  const result=await packageApp({out:at>=0?args[at+1]:null,adhoc:args.includes('--adhoc')});
  console.log(`Packaged ${result.app}`);
  console.log(result.signing==='adhoc'?'Ad-hoc signed: for local checks only. Not a distributable or notarized build.'
    :'Signed with the local identity. Notarization and distribution are separate release steps.');
}
