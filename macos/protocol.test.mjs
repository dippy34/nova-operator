import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import {randomBytes} from 'node:crypto';
import {binary,socketPath,operatorRequest,signedEnvelope} from '../core/computer.mjs';
import {paths} from '../core/paths.mjs';

const keyFile=paths.operatorKey;
// A clean checkout may share the user's socket path with a different installation.
// Never invent a new key or probe that installation without this checkout's app/key.
const nativeReady=process.platform==='darwin'&&existsSync(binary)&&existsSync(keyFile)&&existsSync(socketPath);
test('signed native executor denies forged, expired, replayed and unsupported input before GUI access',{skip:nativeReady?false:'Requires this checkout’s built app, existing key and running native helper'},async()=>{
 const key=readFileSync(keyFile);
 const rejected=async envelope=>{
  const response=await operatorRequest({command:'execute',envelope},{timeout:10000});
  assert.equal(typeof response.error,'string','Native executor accepted unsafe input');
  return response.error;
 };
 const action={action:'shell',scope:{mode:'full'}}; // Deliberately unsupported; never generates GUI events.
 assert.match(await rejected(signedEnvelope(action,randomBytes(32))),/Invalid or expired/);
 assert.match(await rejected(signedEnvelope(action,key,Date.now()-20000)),/Invalid or expired/);
 const valid=signedEnvelope(action,key);
 assert.match(await rejected(valid),/Unsupported action/);
 assert.match(await rejected(valid),/already used/);
 const changed=signedEnvelope(action,key);changed.payload=Buffer.from(JSON.stringify({...action,action:'screenshot'})).toString('base64');
 assert.match(await rejected(changed),/Invalid or expired/);
 assert.match((await operatorRequest({command:'shell'})).error,/Unsupported request/);
 // Every signed action carries the range, and "Chosen apps" is enforced by the Mac app too.
 assert.match(await rejected(signedEnvelope({action:'screenshot'},key)),/no range/);
 assert.match(await rejected(signedEnvelope({action:'screenshot',scope:{mode:'apps',apps:['not a bundle']}},key)),/Invalid range/);
 const notes={mode:'apps',apps:['com.apple.Notes']};
 assert.match(await rejected(signedEnvelope({action:'open_app',bundle_id:'com.apple.Terminal',scope:notes},key)),/isn't one Nova may use|Allow Nova Operator/);
 assert.match(await rejected(signedEnvelope({action:'key',text:'cmd+space',scope:notes},key)),/outside the chosen apps|Allow Nova Operator/);
});
