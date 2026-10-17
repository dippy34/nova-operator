// Read-only setup checks. Reports are assembled from fixed messages and a small
// allowlist of version strings; never serialize subprocess output or DB records.
import {DatabaseSync} from 'node:sqlite';
import {existsSync,statSync} from 'node:fs';
import {tailscaleStatus} from './tailscale.mjs';
import {permissions} from './computer.mjs';

const VERSION=/^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/;
const safeVersion=value=>typeof value==='string'&&VERSION.test(value)?value:'unknown';
const enumValue=(value,allowed)=>allowed.includes(value)?value:'unknown';

/// Do not use Store here: its constructor creates files and runs migrations.
/// Only the settings needed for setup and a count of devices are read.
export function inspectDiagnosticDatabase(file){
  if(!existsSync(file))return {state:'missing'};
  let db;
  try{
    const privateFile=(statSync(file).mode&0o077)===0;
    db=new DatabaseSync(file,{readOnly:true});
    db.exec('PRAGMA busy_timeout=1000');
    const get=key=>db.prepare('SELECT value FROM settings WHERE key=?').get(key)?.value;
    const owner=get('computer_owner');
    return {
      state:'ok',privateFile,
      paired:Number(db.prepare('SELECT COUNT(*) AS n FROM devices').get().n)>0,
      ownerPaired:typeof owner==='string'&&Number(db.prepare('SELECT COUNT(*) AS n FROM devices WHERE id=?').get(owner).n)===1,
      range:enumValue(get('access_level'),['chat','apps','full']),
      stopped:get('stopped')==='1'
    };
  }catch{return {state:'unreadable'};}
  finally{db?.close();}
}

function privateOrigin(value){
  try{
    const url=new URL(value);
    if(url.protocol!=='https:'||!url.hostname.endsWith('.ts.net')||url.username||url.password||url.pathname!=='/'||url.search||url.hash)return null;
    return url.origin;
  }catch{return null;}
}

async function probe(origin,fetchImpl){
  const options=()=>({redirect:'error',signal:AbortSignal.timeout(3000)});
  try{
    const health=await fetchImpl(`${origin}/v1/health`,options());
    if(!health.ok)return {healthy:false};
    const body=await health.json();
    if(body?.service!=='nova-core'||body?.ready!==true)return {healthy:false};
    // A healthy listener alone is insufficient: protected routes must refuse a
    // request with no pairing credential. No credentials are sent by this check.
  }catch{return {healthy:false};}
  try{
    const auth=await fetchImpl(`${origin}/v1/status`,options());
    await auth.body?.cancel();
    return {healthy:true,protected:auth.status===401};
  }catch{return {healthy:true,protected:null};}
}

export async function collectDiagnostics({
  dbFile,port=8787,fetchImpl=fetch,
  tailStatus=()=>tailscaleStatus(port),permissionCheck=permissions,
  inspectDatabase=inspectDiagnosticDatabase,
  nodeVersion=process.versions.node,platform=process.platform,arch=process.arch
}={}){
  if(!Number.isInteger(port)||port<1||port>65535)throw new Error('Nova has an invalid local port setting.');
  const check=(id,title,status,message,hint)=>({id,title,status,message,...(hint?{hint}:{})});
  const checks=[];
  const version=safeVersion(nodeVersion),[major,minor]=version.split('.').map(Number);
  checks.push(check('runtime','Runtime',major>22||(major===22&&minor>=13)?'pass':'fail',
    major>22||(major===22&&minor>=13)?'The runtime meets Nova’s requirements.':'Nova needs Node 22.13 or newer.',
    major>22||(major===22&&minor>=13)?null:'Update Nova’s runtime, then check again.'));
  // A failed probe is a check result, never an exception message copied into a
  // support report. These operations do not start services or change settings.
  const [localResult,tailResult,permissionResult,databaseResult]=await Promise.allSettled([
    probe(`http://127.0.0.1:${port}`,fetchImpl),Promise.resolve().then(tailStatus),Promise.resolve().then(permissionCheck),Promise.resolve().then(()=>inspectDatabase(dbFile))
  ]);
  const local=localResult.status==='fulfilled'?localResult.value:{};
  checks.push(check('core','Nova Core',local.healthy?'pass':'fail',
    local.healthy?'Nova Core answers on this Mac.':'Nova Core is not answering on this Mac.',
    local.healthy?null:'Start Nova Core on the Mac, then check again.'));
  checks.push(check('local-auth','Pairing protection',!local.healthy||local.protected===null?'unknown':local.protected?'pass':'fail',
    !local.healthy?'Core must be reachable before pairing protection can be checked.':local.protected===null?'Core is reachable, but pairing protection could not be checked.':local.protected?'Core refuses requests without a paired device.':'Core did not refuse an unpaired request.',
    local.healthy&&local.protected===false?'Stop using remote access until pairing protection is repaired.':local.protected===null?'Try the check again before using remote access.':null));

  const tail=tailResult.status==='fulfilled'?tailResult.value:null;
  checks.push(check('vpn','Private network',!tail?'unknown':tail.installed===true&&tail.running===true?'pass':'fail',
    !tail?'The private network could not be checked.':tail.installed!==true?'Tailscale is not installed.':tail.running!==true?'Tailscale is not connected on this Mac.':'Tailscale is connected on this Mac.',
    !tail||tail.installed!==true?'Open Tailscale on the Mac, sign in, then check again.':tail.running!==true?'Connect Tailscale on the Mac. On the iPhone, use the same account and connect its VPN.':null));
  checks.push(check('funnel','Public access',!tail||typeof tail.funnel!=='boolean'?'unknown':tail.funnel?'fail':'pass',
    !tail||typeof tail.funnel!=='boolean'?'Public Funnel status is unavailable.':tail.funnel?'Tailscale reports public Funnel access.':'Tailscale reports no public Funnel access.',
    tail?.funnel===true?'Turn off Funnel in Tailscale before using Nova remotely.':null));
  const origin=tail?.running===true?privateOrigin(tail.url):null;
  const remote=origin?await probe(origin,fetchImpl):null;
  checks.push(check('private-route','Private HTTPS route',!origin?'unknown':remote.healthy&&remote.protected?'pass':'fail',
    !origin?'A private Nova HTTPS route is not available.':remote.healthy&&remote.protected?'This Mac reaches Nova through private HTTPS, with pairing protection.':'Nova’s private HTTPS route did not pass the connection and pairing checks.',
    !origin?'In Nova setup, turn on private access after connecting Tailscale.':'If the iPhone cannot connect, confirm its Tailscale VPN is connected using the same account.'));

  const state=databaseResult.status==='fulfilled'?databaseResult.value:{state:'unreadable'};
  const readable=state?.state==='ok';
  checks.push(check('saved-setup','Saved setup',readable?'pass':'fail',
    readable?'Saved setup can be read.':state?.state==='missing'?'Nova has no saved setup yet.':'Nova’s saved setup could not be read.',
    readable?null:'Start Nova Core and finish setup. If this continues, keep the existing data and ask for support.'));
  checks.push(check('data-permissions','Private data',!readable?'unknown':state.privateFile===true?'pass':'fail',
    !readable?'Saved data must be readable before its permissions can be checked.':state.privateFile===true?'The database file is restricted to its owner.':'The database file allows access to other users.',
    readable&&state.privateFile!==true?'Repair the database file permissions on the Mac before using Nova.':null));
  checks.push(check('paired-phone','Paired iPhone',!readable?'unknown':state.paired===true?'pass':'warning',
    !readable?'Paired devices could not be checked.':state.paired===true?'At least one device is paired.':'No device is paired.',
    readable&&state.paired!==true?'Show a new pairing code in Nova setup and scan it on your iPhone.':null));
  checks.push(check('owner-phone','Controlling iPhone',!readable?'unknown':state.ownerPaired===true?'pass':'warning',
    !readable?'The controlling device could not be checked.':state.ownerPaired===true?'A controlling device is paired.':'No controlling device is paired; a chat-only phone cannot control the Mac.',
    readable&&state.ownerPaired!==true?'Pair your iPhone using “This iPhone controls the Mac” on the Mac. This transfers control from a previous owner.':null));
  const native=permissionResult.status==='fulfilled'?permissionResult.value:null;
  const chat=readable&&state.range==='chat';
  checks.push(check('mac-permissions','Mac control',chat?'pass':!readable||state.range==='unknown'||!native?'unknown':native.running===true&&native.accessibility===true&&native.screenRecording===true?'pass':'fail',
    chat?'Mac permissions are not required for Just chat.':!readable||state.range==='unknown'?'Choose a range before checking Mac control.':!native?'Mac permissions could not be checked.':native.running!==true?'Nova Operator is not running.':native.accessibility!==true?'Nova Operator needs Accessibility access.':native.screenRecording!==true?'Nova Operator needs Screen Recording access.':'Nova Operator is running with its required Mac permissions.',
    chat?null:!native||native.running!==true?'Open Nova Operator on the Mac, then check again.':native.accessibility!==true||native.screenRecording!==true?'In Nova setup, review Mac permissions and approve the missing permission in System Settings.':null));
  checks.push(check('stop-state','Emergency stop',!readable?'unknown':state.stopped===true?'warning':'pass',
    !readable?'Emergency stop state could not be checked.':state.stopped===true?'Nova is stopped.':'Emergency stop is not active.',
    readable&&state.stopped===true?'Resume from Nova setup on the Mac only when you are ready.':null));
  const summary=Object.fromEntries(['pass','fail','warning','unknown'].map(status=>[status,checks.filter(c=>c.status===status).length]));
  return {
    schemaVersion:1,
    runtime:{node:version,platform:enumValue(platform,['darwin','linux','win32']),arch:enumValue(arch,['arm64','x64'])},
    summary,checks,
    scope:'Mac setup checks only. This does not verify the iPhone connection, provider key or an AI task.',
    privacy:'No keys, pairing codes, hostnames, addresses, device names, task text, screenshots or logs are included.'
  };
}

export function formatDiagnostics(report){
  return ['Nova connection check',...report.checks.map(c=>`${c.status.toUpperCase()}: ${c.title} — ${c.message}${c.hint?` ${c.hint}`:''}`),'',report.scope,report.privacy].join('\n');
}
