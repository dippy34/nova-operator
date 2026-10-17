import { resolve } from 'node:path';
import { Store } from './db.mjs';
import { IMESSAGE_HANDLE } from './work.mjs';
import { keys, PROVIDERS, providerStatus, testKey } from './keys.mjs';
import { readAccess } from './policy.mjs';
import { tailscaleStatus, enableServe } from './tailscale.mjs';
import { computerName, pairingLink } from './setup.mjs';
const dbFile = resolve(process.env.NOVA_DB ?? './.nova-data/nova.sqlite');
const store = new Store(dbFile);
const args = process.argv.slice(2);
const json = args.includes('--json');
const [command, ...rest] = args.filter(a => a !== '--json');
const out = (object, text) => console.log(json ? JSON.stringify(object) : text);
const failed = message => { if (json) console.log(JSON.stringify({ error: message })); else console.error(message); process.exitCode = 1; };
const readStdin = async () => { let text = ''; for await (const chunk of process.stdin) { text += chunk; if (text.length > 2000) break; } return text.trim(); };

try {
  if (command === 'pair') {
    const owner = rest.includes('--owner');
    const invitation = store.createInvitation({ owner });
    const { url } = await tailscaleStatus();
    const name = computerName();
    if (json) out({ ...invitation, url, computer: name, link: url ? pairingLink({ url, code: invitation.code, name }) : null });
    else {
      console.log(`Pairing code (valid 10 minutes; one use${owner ? '; this iPhone will control the Mac' : ''}): ${invitation.short}`);
      console.log(`Long code for the QR or a paste: ${invitation.code}`);
      if (url) console.log(`Mac address: ${url}`);
      console.log('Enter it in the Nova iPhone app. Never commit or share it.');
    }
  } else if (command === 'setup') {
    const access = readAccess(store), ownerId = store.setting('computer_owner');
    out({ computer: computerName(), tailscale: await tailscaleStatus(), stopped: store.stopped(), access, ai: providerStatus(store),
      devices: store.devices().map(d => ({ ...d, owner: d.id === ownerId })) }, JSON.stringify({ access: access.level, ai: providerStatus(store).selected }, null, 2));
  } else if (command === 'serve' && rest[0] === 'on') {
    const status = await enableServe();
    out({ tailscale: status }, status.url ? `Private access is on: ${status.url}` : 'Tailscale Serve is on.');
  } else if (command === 'key' && rest[0] === 'set' && PROVIDERS[rest[1]]) {
    // The key comes from stdin so it never appears in a process list or shell history.
    const provider = rest[1], key = await readStdin();
    if (!PROVIDERS[provider].pattern.test(key)) failed(`That doesn't look like a ${PROVIDERS[provider].label} API key.`);
    else {
      const test = await testKey(provider, key);
      if (test.code === 'rejected') failed(test.message);
      else { keys.save(provider, key); store.setSetting('ai_provider', provider); out({ saved: true, test, ai: providerStatus(store) }, `Saved in the Keychain. ${test.message}`); }
    }
  } else if (command === 'key' && rest[0] === 'remove' && PROVIDERS[rest[1]]) {
    keys.remove(rest[1]);
    if (store.setting('ai_provider') === rest[1]) store.setSetting('ai_provider', null);
    out({ ai: providerStatus(store) }, `Removed the ${PROVIDERS[rest[1]].label} key from the Keychain.`);
  } else if (command === 'key' && rest[0] === 'import') {
    keys.importLegacy();
    out({ ai: providerStatus(store) }, 'Moved the Claude key from .env.local into the Keychain. You can delete .env.local now.');
  } else if (command === 'key' && rest[0] === 'test' && PROVIDERS[rest[1]]) {
    const key = keys.read(rest[1]);
    if (!key) failed(`No ${PROVIDERS[rest[1]].label} key is connected.`);
    else { const test = await testKey(rest[1], key); out({ test }, test.message); if (!test.ok) process.exitCode = 1; }
  } else if (command === 'provider' && PROVIDERS[rest[0]]) {
    if (!keys.storage(rest[0])) failed(`Connect your ${PROVIDERS[rest[0]].label} key first.`);
    else { store.setSetting('ai_provider', rest[0]); out({ ai: providerStatus(store) }, `Nova now uses ${PROVIDERS[rest[0]].label}.`); }
  } else if (command === 'access' && ['chat', 'full'].includes(rest[0])) {
    store.setSetting('access_level', rest[0]); store.setSetting('access_apps', '[]'); store.setSetting('access_chosen', '1');
    if (rest[0] === 'chat') store.setSetting('access_folders', '[]');
    store.event(null, 'range', `Range set to ${rest[0]} on the Mac`);
    out({ access: readAccess(store) }, `Nova's range is now ${rest[0] === 'chat' ? 'Just chat' : 'Whole Mac'}. Choose apps and folders from the iPhone.`);
  } else if (command === 'resume') {
    store.resume(); out({ resumed: true }, 'Nova resumed.');
  } else if (command === 'devices') {
    const ownerId = store.setting('computer_owner'), devices = store.devices().map(d => ({ ...d, owner: d.id === ownerId }));
    if (json) out({ devices }); else console.table(devices);
  } else if (command === 'revoke' && rest[0]) {
    const revoked = store.revokeDevice(rest[0]);
    if (revoked) out({ revoked }, 'Device revoked.'); else failed('Device not found.');
  } else if (command === 'imessage' && rest[0] === 'off') {
    store.setSetting('imessage_to', null); console.log('Reports will no longer be texted.');
  } else if (command === 'imessage' && rest[0]) {
    const to = rest.join('').replace(/[\s()-]/g, '');
    if (IMESSAGE_HANDLE.test(to)) { store.setSetting('imessage_to', to); console.log(`Reports will be texted to ${to}.`); }
    else failed('Give a phone number with its country code (+12245551234) or an Apple ID email.');
  } else if (command === 'imessage') {
    console.log(store.setting('imessage_to') ? `Reports are texted to ${store.setting('imessage_to')}.` : 'Reports are not texted.');
  } else {
    failed('Usage: node core/cli.mjs pair [--owner] | setup | serve on | key set|remove|test anthropic|openai | key import | provider anthropic|openai | access chat|full | resume | devices | revoke DEVICE_ID | imessage [+NUMBER|EMAIL|off]  (add --json for machine output)');
  }
} catch (error) { failed(error.message); }
store.close();
