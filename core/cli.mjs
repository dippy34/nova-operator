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
} else { console.error('Usage: npm run pair | npm run resume'); process.exitCode=1; }
store.close();
