import { resolve } from 'node:path';
import { Store } from './db.mjs';
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
} else { console.error('Usage: npm run pair | npm run resume | node core/cli.mjs devices | node core/cli.mjs revoke DEVICE_ID'); process.exitCode=1; }
store.close();
