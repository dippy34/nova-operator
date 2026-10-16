import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {existsSync,readFileSync,writeFileSync} from 'node:fs';
import {randomBytes} from 'node:crypto';
import {join,dirname} from 'node:path';
import {binary,signedEnvelope} from '../core/computer.mjs';

test('signed native executor denies forged, expired, replayed and unsupported input before GUI access',{skip:process.platform!=='darwin'||!existsSync(binary)},()=>{
 const keyFile=join(dirname(dirname(dirname(dirname(binary)))),'operator.key');
 if(!existsSync(keyFile))writeFileSync(keyFile,randomBytes(32),{mode:0o600,flag:'wx'});
 const key=readFileSync(keyFile);
 const rejected=envelope=>{
  try{execFileSync(binary,['execute'],{input:JSON.stringify(envelope),timeout:10000,stdio:['pipe','pipe','pipe']});assert.fail('Native executor accepted unsafe input');}
  catch(error){assert.equal(error.status,1);const response=JSON.parse(error.stdout);assert.equal(typeof response.error,'string');return response.error;}
 };
 const action={kind:'shell',app:'TextEdit'}; // Deliberately unsupported; never generates GUI events.
 assert.match(rejected(signedEnvelope(action,randomBytes(32))),/Invalid or expired/);
 assert.match(rejected(signedEnvelope(action,key,Date.now()-20000)),/Invalid or expired/);
 const valid=signedEnvelope(action,key);
 assert.match(rejected(valid),/Unknown operation/);
 assert.match(rejected(valid),/already used/);
 const changed=signedEnvelope(action,key);changed.payload=Buffer.from(JSON.stringify({...action,kind:'activate'})).toString('base64');
 assert.match(rejected(changed),/Invalid or expired/);
});
