import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync,existsSync,statSync} from 'node:fs';
import {spawn,execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {resolvePaths,paths,FILES,MANIFEST,APP_SUPPORT} from './paths.mjs';
import {servicePlist} from './service.mjs';
import {infoPlist} from '../macos/build.mjs';

const checkout=resolve(dirname(fileURLToPath(import.meta.url)),'..');
// Spaces and an ampersand catch unquoted paths and unescaped plist values.
const temp=()=>mkdtempSync(join(tmpdir(),'nova paths & data '));
// Child processes must not inherit a developer's own Nova settings.
const cleanEnv=extra=>{const env={...process.env};for(const k of Object.keys(env))if(k.startsWith('NOVA_'))delete env[k];return {...env,...extra};};
function appLayout(dir,manifest={layout:'app',version:'0.2.0'}){
  const resources=join(dir,'Copied Apps','Nova Operator.app','Contents','Resources');
  mkdirSync(join(resources,'core'),{recursive:true});
  writeFileSync(join(resources,MANIFEST),typeof manifest==='string'?manifest:JSON.stringify(manifest));
  return resources;
}

test('a source checkout keeps its data in .nova-data, wherever a command starts',()=>{
  const dir=temp();
  try{
    const p=resolvePaths({root:dir,env:{},home:'/Users/someone',execPath:'/opt/node/bin/node'});
    assert.equal(p.layout,'development');
    assert.equal(p.data,join(dir,'.nova-data'));
    assert.equal(p.db,join(dir,'.nova-data','nova.sqlite'));
    assert.equal(p.operatorKey,join(dir,'.nova-data','operator.key'));
    assert.equal(p.operatorNonces,join(dir,'.nova-data','operator-nonces'));
    assert.equal(p.operatorBinary,join(dir,'.nova-data','Nova Operator.app','Contents','MacOS','NovaOperator'));
    assert.equal(p.log,join(dir,'.nova-data','core.log'));
    assert.equal(p.socket,'/Users/someone/Library/Application Support/Nova Operator/operator.sock');
    assert.equal(p.legacyEnv,join(dir,'.env.local'));
    assert.equal(p.runtime,'/opt/node/bin/node');
    assert.equal(p.workspace,null);
    assert.equal(p.port,8787);
    assert(Object.isFrozen(p));
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('this checkout resolves to the same locations the installed development services use',()=>{
  // These were hard-coded before paths.mjs; a refactor must not move the live install's data.
  const p=resolvePaths({env:{}});
  assert.equal(p.root,checkout);
  assert.equal(p.layout,'development');
  assert.equal(p.data,join(checkout,'.nova-data'));
  assert.equal(p.operatorBinary,join(checkout,'.nova-data','Nova Operator.app','Contents','MacOS','NovaOperator'));
  assert.equal(p.operatorKey,join(checkout,'.nova-data','operator.key'));
  assert(Buffer.byteLength(paths.socket)<104,'The native socket path exceeds sun_path');
});

test('NOVA_DATA_DIR moves every saved file; NOVA_DB still moves only the database',()=>{
  const p=resolvePaths({root:'/src/nova',env:{NOVA_DATA_DIR:'/tmp/isolated',NOVA_PORT:'0',NOVA_WORKSPACE:'/src/project'},home:'/Users/someone'});
  assert.deepEqual([p.data,p.db,p.operatorKey,p.errorLog,p.operatorApp],
    ['/tmp/isolated','/tmp/isolated/nova.sqlite','/tmp/isolated/operator.key','/tmp/isolated/core-error.log','/tmp/isolated/Nova Operator.app']);
  assert.equal(p.port,0);
  assert.equal(p.workspace,'/src/project');
  const db=resolvePaths({root:'/src/nova',env:{NOVA_DB:'/elsewhere/nova.sqlite'}});
  assert.equal(db.db,'/elsewhere/nova.sqlite');
  assert.equal(db.operatorKey,'/src/nova/.nova-data/operator.key');
  // Relative overrides follow normal shell meaning; empty values are unset.
  assert.equal(resolvePaths({root:'/src/nova',env:{NOVA_DATA_DIR:'rel'}}).data,resolve('rel'));
  assert.equal(resolvePaths({root:'/src/nova',env:{NOVA_DATA_DIR:'',NOVA_DB:''}}).db,'/src/nova/.nova-data/nova.sqlite');
});

test('a packaged app keeps code in the bundle and saved data in Application Support',()=>{
  const dir=temp();
  try{
    const resources=appLayout(dir),bundle=dirname(dirname(resources)),home=join(dir,'home');
    const p=resolvePaths({root:resources,env:{},home,execPath:'/usr/local/bin/node'});
    assert.equal(p.layout,'app');
    assert.equal(p.bundle,bundle);
    assert.equal(p.manifest.version,'0.2.0');
    assert.equal(p.core,join(resources,'core'));
    assert.equal(p.runtime,join(bundle,'Contents','Helpers','node'),'Packaged Core must not use a development Node');
    assert.equal(p.data,join(home,'Library','Application Support',APP_SUPPORT));
    assert.equal(p.db,join(p.data,'nova.sqlite'));
    assert.equal(p.operatorBinary,join(bundle,'Contents','MacOS','NovaOperator'));
    assert.equal(p.socket,join(p.data,'operator.sock'));
    assert.equal(p.legacyEnv,null,'A packaged app never reads a checkout .env.local');
    assert.equal(p.workspace,null);
    assert.equal(resolvePaths({root:resources,env:{NOVA_DATA_DIR:join(dir,'test data')},home}).data,join(dir,'test data'));
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('a damaged or misplaced runtime manifest fails closed instead of using development paths',()=>{
  const dir=temp();
  try{
    assert.throws(()=>resolvePaths({root:appLayout(join(dir,'a'),'{not json'),env:{}}),/unreadable/);
    assert.throws(()=>resolvePaths({root:appLayout(join(dir,'b'),{layout:'development'}),env:{}}),/unsupported layout/);
    const loose=join(dir,'loose');mkdirSync(loose);writeFileSync(join(loose,MANIFEST),'{"layout":"app"}');
    assert.throws(()=>resolvePaths({root:loose,env:{}}),/Contents\/Resources/);
    const resources=appLayout(join(dir,'c'));
    assert.throws(()=>resolvePaths({root:resources,env:{NOVA_DATA_DIR:join(resources,'data')}}),/cannot live inside the app/);
    assert.throws(()=>resolvePaths({root:resources,env:{NOVA_DB:join(resources,'nova.sqlite')}}),/cannot live inside the app/);
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('the login service and native executor configuration come from the same paths',()=>{
  const dir=temp();
  try{
    const dev=resolvePaths({root:dir,env:{},home:join(dir,'home'),execPath:'/opt/node/bin/node'});
    const esc=value=>value.replaceAll('&','&amp;');
    const service=servicePlist(dev);
    assert(service.includes(`<string>/opt/node/bin/node</string><string>${esc(join(dir,'core','server.mjs'))}</string>`));
    for(const [key,value] of [['NOVA_DATA_DIR',dev.data],['NOVA_DB',dev.db],['NOVA_WORKSPACE',dir]])
      assert(service.includes(`<key>${key}</key><string>${esc(value)}</string>`),key);
    assert(service.includes(`<key>StandardErrorPath</key><string>${esc(dev.errorLog)}</string>`));
    assert(!service.includes(' & '),'Plist values must be escaped');
    const plist=infoPlist(dev);
    for(const [key,value] of [['NovaCoreDataDirectory',dev.data],['NovaCoreRoot',dev.root],['NovaNodePath',dev.runtime]])
      assert(plist.includes(`<key>${key}</key><string>${esc(value)}</string>`),key);

    const app=resolvePaths({root:appLayout(dir),env:{},home:join(dir,'home')});
    const packaged=servicePlist(app);
    assert(packaged.includes(`<string>${esc(app.runtime)}</string>`));
    assert(!packaged.includes('NOVA_WORKSPACE'),'A packaged app has no checkout to report on');
    assert(packaged.includes(`<key>WorkingDirectory</key><string>${esc(app.data)}</string>`));
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('the native executor derives the same file names from its signed data directory',()=>{
  const swift=readFileSync(join(checkout,'macos','Operator.swift'),'utf8');
  for(const fragment of [`appendingPathComponent("${FILES.operatorKey}")`,`appendingPathComponent("${FILES.nonces}")`,
    `appendingPathComponent("${APP_SUPPORT}",isDirectory:true).appendingPathComponent("${FILES.socket}")`,
    `"NOVA_DATA_DIR":data`,`"NOVA_DB":data+"/${FILES.db}"`,`root+"/core/cli.mjs"`])
    assert(swift.includes(fragment),`Operator.swift no longer contains ${fragment}`);
});

test('a CLI started from another folder uses only the isolated data directory it is given',()=>{
  const dir=temp(),cwd=join(dir,'some folder'),data=join(dir,'isolated data');
  mkdirSync(cwd);
  try{
    const output=execFileSync(process.execPath,[join(checkout,'core','cli.mjs'),'devices','--json'],{cwd,env:cleanEnv({NOVA_DATA_DIR:data}),encoding:'utf8'});
    assert.deepEqual(JSON.parse(output),{devices:[]});
    assert.equal(statSync(join(data,'nova.sqlite')).mode&0o777,0o600);
    assert.equal(statSync(data).mode&0o777,0o700);
    assert(!existsSync(join(cwd,'.nova-data')),'The working directory must not receive Nova data');
    // Without an override, the checkout's data is used rather than the working directory's.
    const resolved=JSON.parse(execFileSync(process.execPath,['--input-type=module','-e',
      `import {paths} from ${JSON.stringify(pathToFileURL(join(checkout,'core','paths.mjs')).href)};console.log(JSON.stringify(paths));`],
      {cwd,env:cleanEnv({}),encoding:'utf8'}));
    assert.equal(resolved.db,join(checkout,'.nova-data','nova.sqlite'));
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('Core starts from another folder against isolated data and stops cleanly',async()=>{
  const dir=temp(),data=join(dir,'isolated data');
  const core=spawn(process.execPath,[join(checkout,'core','server.mjs')],{cwd:dir,env:cleanEnv({NOVA_DATA_DIR:data,NOVA_PORT:'0'}),stdio:['ignore','pipe','pipe']});
  try{
    let output='';
    const port=await new Promise((ok,fail)=>{
      const timer=setTimeout(()=>fail(new Error('Core did not start: '+output)),10000);
      core.stdout.on('data',chunk=>{output+=chunk;const found=output.match(/listening on http:\/\/127\.0\.0\.1:(\d+)/);if(found){clearTimeout(timer);ok(Number(found[1]));}});
      core.stderr.on('data',chunk=>{output+=chunk;});
      core.on('exit',code=>{clearTimeout(timer);fail(new Error(`Core exited ${code}: ${output}`));});
    });
    const health=await (await fetch(`http://127.0.0.1:${port}/v1/health`)).json();
    assert.equal(health.service,'nova-core');
    assert.equal((await fetch(`http://127.0.0.1:${port}/v1/status`)).status,401);
    assert.equal(statSync(join(data,'nova.sqlite')).mode&0o777,0o600);
    assert(!existsSync(join(dir,'.nova-data')));
    const exited=new Promise(ok=>core.once('exit',(code,signal)=>ok({code,signal})));
    core.kill('SIGTERM');
    assert.deepEqual(await exited,{code:0,signal:null});
  }finally{if(core.exitCode===null)core.kill('SIGKILL');rmSync(dir,{recursive:true,force:true});}
});
