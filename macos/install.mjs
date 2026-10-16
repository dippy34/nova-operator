import {execFileSync} from 'node:child_process';
import {mkdirSync,writeFileSync,existsSync,unlinkSync} from 'node:fs';
import {homedir} from 'node:os';
import {dirname,join} from 'node:path';
import {binary,permissions} from '../core/computer.mjs';

if(process.platform!=='darwin')throw new Error('Nova Operator requires macOS');
const label='dev.nova.operator.macos';
const domain=`gui/${process.getuid()}`;
const target=`${domain}/${label}`;
const plist=join(homedir(),'Library','LaunchAgents',`${label}.plist`);
const xml=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
const launch=(...args)=>execFileSync('/bin/launchctl',args,{encoding:'utf8',stdio:['ignore','pipe','pipe']});
const loaded=()=>{try{launch('print',target);return true;}catch{return false;}};
const wait=ms=>new Promise(ok=>setTimeout(ok,ms));
const command=process.argv[2];
if(command==='install'){
  if(!existsSync(binary))throw new Error('Build the signed Nova Operator app first: npm run operator:build');
  if(loaded())launch('bootout',target);
  mkdirSync(dirname(plist),{recursive:true});
  // launchd starts the app executable directly, so macOS treats Nova Operator as its
  // own responsible process. Quitting from the menu (exit 0) keeps it stopped.
  writeFileSync(plist,`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${label}</string>
<key>ProgramArguments</key><array><string>${xml(binary)}</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ProcessType</key><string>Interactive</string>
<key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
`,{mode:0o600});
  execFileSync('/usr/bin/plutil',['-lint',plist],{stdio:'inherit'});
  for(let attempt=0;;attempt++){
    try{launch('bootstrap',domain,plist);break;}
    catch(error){
      if(attempt>=20||!String(error.stderr).includes('Bootstrap failed: 5:'))throw error;
      await wait(250);
    }
  }
  let state;
  for(let attempt=0;attempt<50;attempt++){state=await permissions();if(state.running)break;await wait(100);}
  if(!state.running)throw new Error('Nova Operator login item registered but the app is not answering.');
  console.log('Nova Operator is running in the menu bar and starts at login.');
  console.log('Permissions: '+JSON.stringify({accessibility:state.accessibility,screenRecording:state.screenRecording}));
}else if(command==='remove'){
  if(loaded())launch('bootout',target);
  if(existsSync(plist))unlinkSync(plist);
  console.log('Nova Operator login item removed.');
}else if(command==='status'){
  console.log(JSON.stringify(await permissions()));
}else{
  console.error('Usage: node macos/install.mjs install | status | remove');
  process.exitCode=1;
}
