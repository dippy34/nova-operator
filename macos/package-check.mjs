// B2 acceptance check for a packaged app (issue #4). Packages into a temporary folder, copies the
// app to a path with spaces, then runs its bundled Core under a macOS sandbox that denies reading
// this checkout, the development Node and the live Nova data. Uses a temporary HOME, so the app's
// default Application Support data is isolated too. Never touches running services or saved data.
//
//   npm run package:check            (ad-hoc signed; first run downloads the pinned runtime)
import assert from 'node:assert/strict';
import {execFileSync,spawn,spawnSync} from 'node:child_process';
import {copyFileSync,existsSync,mkdtempSync,readFileSync,realpathSync,rmSync,statSync,mkdirSync,writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {paths,APP_SUPPORT,FILES,resolvePaths} from '../core/paths.mjs';
import {packageApp,audit,runtime} from './package.mjs';
import {infoPlist} from './build.mjs';

// /tmp keeps the temporary socket path under the 104-byte sun_path limit.
const work=realpathSync(mkdtempSync('/tmp/nova pkg '));
const results=[];
const pass=name=>{results.push(name);console.log(`✔ ${name}`);};
const literal=value=>JSON.stringify(value);
const devNode=realpathSync(process.execPath);
const liveSupport=join(homedir(),'Library','Application Support',APP_SUPPORT);
const profile=`(version 1)
(allow default)
(deny file-read* (subpath ${literal(realpathSync(paths.root))}) (literal ${literal(devNode)}) (subpath ${literal(liveSupport)}))
(deny process-exec (literal ${literal(devNode)}))`;
const home=join(work,'home');
const env={HOME:home,PATH:'/usr/bin:/bin:/usr/sbin:/sbin',NOVA_PORT:'0'};
const sandboxed=(args,options={})=>spawnSync('/usr/bin/sandbox-exec',['-p',profile,...args],{cwd:work,env,encoding:'utf8',timeout:20000,...options});

let core;
try{
  const built=await packageApp({out:join(work,'build output'),adhoc:true});
  pass(`packaged with pinned Node ${runtime.version} (ad-hoc signed, local check only)`);
  const app=join(work,'Copied Apps','Nova Operator.app');
  mkdirSync(join(work,'Copied Apps'));
  execFileSync('/usr/bin/ditto',[built.app,app]);
  rmSync(join(work,'build output'),{recursive:true});
  audit(app);
  execFileSync('/usr/bin/codesign',['--verify','--strict','--deep',app]);
  pass('copied app passes its exact file audit and signature check');
  const node=join(app,'Contents','Helpers',FILES.runtime),coreDir=join(app,'Contents','Resources','core');
  for(const rel of ['Contents/Info.plist','Contents/Resources/nova-runtime.json'])
    assert(!readFileSync(join(app,rel),'utf8').includes(paths.root),`${rel} names the checkout`);
  pass('signed configuration and manifest contain no checkout path');

  // The sandbox must really block the checkout and the development Node.
  assert.notEqual(sandboxed([node,'-e',`require('fs').readFileSync(${literal(join(paths.root,'package.json'))})`]).status,0,'Sandbox did not block the checkout');
  assert.notEqual(sandboxed([devNode,'-e','0']).status,0,'Sandbox did not block the development Node');
  pass('sandbox blocks the checkout, development Node and live Nova data');

  const resolved=sandboxed([node,'--input-type=module','-e',`import {paths} from './Copied Apps/Nova Operator.app/Contents/Resources/core/paths.mjs';console.log(JSON.stringify(paths));`]);
  assert.equal(resolved.status,0,resolved.stderr);
  const p=JSON.parse(resolved.stdout),data=join(home,'Library','Application Support',APP_SUPPORT);
  assert.equal(p.layout,'app');assert.equal(p.runtime,node);assert.equal(p.data,data);assert.equal(p.operatorBinary,join(app,'Contents','MacOS',FILES.operatorExecutable));
  pass('bundled Core resolves the app layout, bundled runtime and Application Support data');

  const native=JSON.parse(execFileSync(join(app,'Contents','MacOS',FILES.operatorExecutable),['paths'],{encoding:'utf8'}));
  const expected=resolvePaths({root:join(app,'Contents','Resources'),env:{},home:homedir()});
  assert.deepEqual(native,{layout:'app',node:expected.runtime,root:expected.root,data:expected.data,socket:expected.socket});
  pass('native executor derives the same locations as Core from its own bundle');

  // The same binary in a development bundle must keep the live install's checkout locations.
  // Built in the temporary folder and ad-hoc signed; the installed signed app is not touched.
  const devApp=join(work,'Dev Layout','Nova Operator.app');
  mkdirSync(join(devApp,'Contents','MacOS'),{recursive:true});
  writeFileSync(join(devApp,'Contents','Info.plist'),infoPlist(paths));
  copyFileSync(join(app,'Contents','MacOS',FILES.operatorExecutable),join(devApp,'Contents','MacOS',FILES.operatorExecutable));
  execFileSync('/usr/bin/codesign',['--force','--sign','-','--identifier','dev.nova.operator.macos',devApp],{stdio:'ignore'});
  const devNative=JSON.parse(execFileSync(join(devApp,'Contents','MacOS',FILES.operatorExecutable),['paths'],{encoding:'utf8'}));
  assert.deepEqual(devNative,{layout:'development',node:paths.runtime,root:paths.root,data:paths.data,socket:paths.socket});
  pass('a development bundle still resolves the live checkout, data and Node paths');

  const cli=sandboxed([node,join(coreDir,'cli.mjs'),'devices','--json']);
  assert.equal(cli.status,0,cli.stderr);
  assert.deepEqual(JSON.parse(cli.stdout),{devices:[]});
  assert.equal(statSync(join(data,FILES.db)).mode&0o777,0o600);
  assert.equal(statSync(data).mode&0o777,0o700);
  pass('bundled CLI creates owner-only data in the temporary Application Support folder');

  core=spawn('/usr/bin/sandbox-exec',['-p',profile,node,join(coreDir,'server.mjs')],{cwd:work,env,stdio:['ignore','pipe','pipe']});
  let output='';
  const port=await new Promise((ok,reject)=>{
    const timer=setTimeout(()=>reject(new Error('Core did not start: '+output)),15000);
    core.stdout.on('data',chunk=>{output+=chunk;const found=output.match(/listening on http:\/\/127\.0\.0\.1:(\d+)/);if(found){clearTimeout(timer);ok(Number(found[1]));}});
    core.stderr.on('data',chunk=>{output+=chunk;});
    core.on('exit',code=>{clearTimeout(timer);reject(new Error(`Core exited ${code}: ${output}`));});
  });
  assert.equal((await (await fetch(`http://127.0.0.1:${port}/v1/health`)).json()).service,'nova-core');
  assert.equal((await fetch(`http://127.0.0.1:${port}/v1/status`)).status,401);
  const exited=new Promise(ok=>core.once('exit',(code,signal)=>ok({code,signal})));
  core.kill('SIGTERM');
  assert.deepEqual(await exited,{code:0,signal:null});
  pass('bundled Core starts, rejects unauthenticated status and stops cleanly');
  assert(!existsSync(join(work,'.nova-data')),'No data may be written next to the working directory');
  console.log(`\nAll ${results.length} packaged-app checks passed.`);
}catch(error){
  console.error(`\n✖ ${error.message}`);
  process.exitCode=1;
}finally{
  if(core&&core.exitCode===null)core.kill('SIGKILL');
  rmSync(work,{recursive:true,force:true});
}
