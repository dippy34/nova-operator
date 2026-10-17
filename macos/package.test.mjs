import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,readdirSync,rmSync,symlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {CORE_FILES,runtime,expectedFiles,audit,fetchRuntime} from './package.mjs';
import {infoPlist} from './build.mjs';

const checkout=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const temp=()=>mkdtempSync(join(tmpdir(),'nova package & audit '));
function fakeApp(dir,{signed=true}={}){
  const app=join(dir,'Nova Operator.app');
  for(const rel of expectedFiles({signed})){mkdirSync(dirname(join(app,rel)),{recursive:true});writeFileSync(join(app,rel),'x');}
  return app;
}

test('the app packages exactly the Core files that Core imports, and no tests',()=>{
  const entries=['server.mjs','cli.mjs','service.mjs','claude-worker.mjs'],seen=new Set();
  const visit=file=>{
    if(seen.has(file))return;seen.add(file);
    const source=readFileSync(join(checkout,'core',file),'utf8');
    for(const [,dep] of source.matchAll(/(?:from\s+|new URL\(\s*)'\.\/([\w-]+\.mjs)'/g))visit(dep);
    assert(!/from\s+'\.\.\//.test(source),`${file} imports from outside core/`);
  };
  entries.forEach(visit);
  assert.deepEqual([...seen].sort(),[...CORE_FILES].sort());
  const sources=readdirSync(join(checkout,'core')).filter(f=>f.endsWith('.mjs')&&!f.endsWith('.test.mjs')).sort();
  assert.deepEqual(sources,[...CORE_FILES].sort(),'A new Core file must be packaged or excluded deliberately');
});

test('the pinned runtime is an official Node archive with a full checksum',()=>{
  assert.match(runtime.version,/^\d+\.\d+\.\d+$/);
  assert.equal(runtime.archive,`node-v${runtime.version}-darwin-${runtime.arch}.tar.gz`);
  assert.equal(runtime.url,`https://nodejs.org/dist/v${runtime.version}/${runtime.archive}`);
  assert.match(runtime.sha256,/^[0-9a-f]{64}$/);
  assert.match(runtime.team,/^[A-Z0-9]{10}$/);
  const [major,minor]=runtime.version.split('.').map(Number);
  assert(major>22||(major===22&&minor>=13),'Core needs Node 22.13+');
});

test('a packaged app has no absolute paths in its signed configuration',()=>{
  const plist=infoPlist({layout:'app'});
  assert(plist.includes('<key>NovaLayout</key><string>app</string>'));
  for(const key of ['NovaCoreDataDirectory','NovaCoreRoot','NovaNodePath'])assert(!plist.includes(key),key);
  assert(!plist.includes(checkout));
});

test('the file audit rejects private files, symlinks and missing pieces',()=>{
  const dir=temp();
  try{
    const app=fakeApp(dir);
    assert.equal(audit(app).length,expectedFiles().size);
    for(const name of ['.env.local','CLAUDE.local.md','Contents/Resources/nova.sqlite','Contents/Resources/operator.key',
      'Contents/Resources/.nova-data/core.log','Contents/Resources/core/paths.test.mjs','Contents/Resources/Signing.local.xcconfig']){
      const file=join(app,name);mkdirSync(dirname(file),{recursive:true});writeFileSync(file,'secret');
      assert.throws(()=>audit(app),/unexpected/,name);
      rmSync(file);
    }
    rmSync(join(app,'Contents','Resources','licenses','node-LICENSE'));
    assert.throws(()=>audit(app),/missing Contents\/Resources\/licenses\/node-LICENSE/);
    writeFileSync(join(app,'Contents','Resources','licenses','node-LICENSE'),'x');
    rmSync(join(app,'Contents','Resources','core','db.mjs'));
    symlinkSync(join(checkout,'core','db.mjs'),join(app,'Contents','Resources','core','db.mjs'));
    assert.throws(()=>audit(app),/symlink/);
    assert.throws(()=>audit(fakeApp(join(dir,'unsigned'),{signed:false})),/missing Contents\/_CodeSignature/);
    assert.equal(audit(fakeApp(join(dir,'unsigned2'),{signed:false}),{signed:false}).length,expectedFiles({signed:false}).size);
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('a runtime archive with the wrong checksum is deleted and refused',async()=>{
  const dir=temp();
  try{
    let fetched=0;
    const fetchImpl=async url=>{fetched++;assert.equal(url,runtime.url);return new Response('not node');};
    await assert.rejects(fetchRuntime({cache:dir,fetchImpl}),/does not match the pinned/);
    assert.equal(fetched,1);
    assert.deepEqual(readdirSync(dir),[],'A bad archive must not stay in the cache');
    await assert.rejects(fetchRuntime({cache:dir,fetchImpl:async()=>new Response('',{status:404})}),/HTTP 404/);
  }finally{rmSync(dir,{recursive:true,force:true});}
});
