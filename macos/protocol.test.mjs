import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,readFileSync,writeFileSync} from 'node:fs';
import {randomBytes} from 'node:crypto';
import {join,dirname} from 'node:path';
import {binary,socketPath,operatorRequest,signedEnvelope} from '../core/computer.mjs';

test('signed native executor denies forged, expired, replayed and unsupported input before GUI access',{skip:process.platform!=='darwin'||!existsSync(socketPath)},async()=>{
 const keyFile=join(dirname(dirname(dirname(dirname(binary)))),'operator.key');
 if(!existsSync(keyFile))writeFileSync(keyFile,randomBytes(32),{mode:0o600,flag:'wx'});
 const key=readFileSync(keyFile);
 const rejected=async envelope=>{
  const response=await operatorRequest({command:'execute',envelope},{timeout:10000});
  assert.equal(typeof response.error,'string','Native executor accepted unsafe input');
  return response.error;
 };
 const action={kind:'shell',app:'TextEdit'}; // Deliberately unsupported; never generates GUI events.
 assert.match(await rejected(signedEnvelope(action,randomBytes(32))),/Invalid or expired/);
 assert.match(await rejected(signedEnvelope(action,key,Date.now()-20000)),/Invalid or expired/);
 const valid=signedEnvelope(action,key);
 assert.match(await rejected(valid),/Unknown operation/);
 assert.match(await rejected(valid),/already used/);
 const changed=signedEnvelope(action,key);changed.payload=Buffer.from(JSON.stringify({...action,kind:'activate'})).toString('base64');
 assert.match(await rejected(changed),/Invalid or expired/);
 assert.match((await operatorRequest({command:'shell'})).error,/Unsupported request/);
});
