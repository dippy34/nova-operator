import { resolve } from 'node:path';
import { Store } from './db.mjs';
import { IMESSAGE_HANDLE } from './work.mjs';
const dbFile = resolve(process.env.NOVA_DB ?? './.nova-data/nova.sqlite');
const store = new Store(dbFile);
const command = process.argv[2];
if (command === 'pair') {
  const code=store.issueInvitation();
  console.log('Pairing code (valid 10 minutes; one use):',code);
  console.log('Enter this code in the Nova iPhone app. Never commit or share it.');
} else if (command === 'resume') {
  store.resume(); console.log('Nova resumed.');
} else if (command === 'devices') {
  console.table(store.devices());
} else if (command === 'revoke' && process.argv[3]) {
  const revoked = store.revokeDevice(process.argv[3]);
  console.log(revoked ? 'Device revoked.' : 'Device not found.');
  if (!revoked) process.exitCode = 1;
} else if (command === 'imessage' && process.argv[3] === 'off') {
  store.setSetting('imessage_to', null); console.log('Reports will no longer be texted.');
} else if (command === 'imessage' && process.argv[3]) {
  const to = process.argv.slice(3).join('').replace(/[\s()-]/g, '');
  if (IMESSAGE_HANDLE.test(to)) { store.setSetting('imessage_to', to); console.log(`Reports will be texted to ${to}.`); }
  else { console.error('Give a phone number with its country code (+12245551234) or an Apple ID email.'); process.exitCode = 1; }
} else if (command === 'imessage') {
  console.log(store.setting('imessage_to') ? `Reports are texted to ${store.setting('imessage_to')}.` : 'Reports are not texted.');
} else { console.error('Usage: npm run pair | npm run resume | node core/cli.mjs devices | node core/cli.mjs revoke DEVICE_ID | node core/cli.mjs imessage [+NUMBER|EMAIL|off]'); process.exitCode=1; }
store.close();
