import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,rmSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {brainProfile,sandboxBinary} from './brain-sandbox.mjs';
import {callWorker,brokerBodyValid} from './ai.mjs';
test('target macOS sandbox blocks protected reads, writes, subprocesses, direct TCP and DNS',{skip:process.platform!=='darwin'||!existsSync(sandboxBinary)},()=>{
 const directory=mkdtempSync(join(tmpdir(),'nova-containment-'));
 const canary=join(directory,'private.txt'),output=join(directory,'forbidden.txt');writeFileSync(canary,'private canary');
 const script=`
 const fs=require('node:fs'),cp=require('node:child_process'),net=require('node:net'),dns=require('node:dns').promises;
 const result={};
 for(const [name,fn] of Object.entries({read:()=>fs.readFileSync(${JSON.stringify(canary)}),write:()=>fs.writeFileSync(${JSON.stringify(output)},'bad'),shell:()=>cp.execFileSync('/bin/sh',['-c','exit 0']),childNode:()=>cp.execFileSync(process.execPath,['-e','process.exit(0)'])})){
  try{fn();result[name]=false;}catch{result[name]=true;}
 }
 const tcp=host=>new Promise(ok=>{const s=net.connect({host,port:443});s.setTimeout(1000);s.once('connect',()=>{s.destroy();ok(false)});s.once('error',e=>ok(e.code==='EPERM'||e.code==='EACCES'));s.once('timeout',()=>{s.destroy();ok(false)});});
 (async()=>{result.localTCP=await tcp('127.0.0.1');result.directIP=await tcp('1.1.1.1');try{await dns.resolve4('example.com');result.dns=false;}catch{result.dns=true;}console.log(JSON.stringify(result));})();`;
 try{
  const result=JSON.parse(execFileSync(sandboxBinary,['-p',brainProfile,process.execPath,'-e',script],{env:{},encoding:'utf8',timeout:10000,stdio:['ignore','pipe','pipe']}));
  assert.deepEqual(result,{read:true,write:true,shell:true,childNode:true,localTCP:true,directIP:true,dns:true});
  assert.equal(existsSync(output),false);
 }finally{rmSync(directory,{recursive:true,force:true});}
});
test('contained real worker uses inherited IPC and broker keeps keys and billing in Core',{skip:process.platform!=='darwin'},async()=>{
 let calls=0;
 const result=await callWorker([{role:'user',content:'hello'}],new AbortController().signal,{keyProvider:()=> 'fake-parent-only',fetchImpl:async(url,options)=>{
  calls++;assert.equal(url,'https://api.anthropic.com/v1/messages');assert.equal(options.headers['x-api-key'],'fake-parent-only');
  return Response.json({content:[{type:'text',text:'IPC verified'}],usage:{input_tokens:100,output_tokens:10},stop_reason:'end_turn'});
 }});
 assert.equal(result.message,'IPC verified');assert.equal(result.costMicros,15);assert.equal(calls,1);
});
test('provider broker blocks expensive models, oversized text and server tools',()=>{
 const body={model:'claude-haiku-5-5',max_tokens:512,thinking:{type:'disabled'},system:'Nova',messages:[{role:'user',content:'hello'}]};
 assert.equal(brokerBodyValid(body),true);
 assert.equal(brokerBodyValid({...body,model:'claude-opus-5-5'}),false);
 assert.equal(brokerBodyValid({...body,max_tokens:100000}),false);
 assert.equal(brokerBodyValid({...body,messages:[{role:'user',content:'x'.repeat(12001)}]}),false);
 assert.equal(brokerBodyValid({...body,tools:[{type:'web_search_20260209',name:'web_search'}]}),false);
});
