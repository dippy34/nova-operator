import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('The login service requires macOS');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const label = 'dev.nova.operator.core';
const domain = `gui/${process.getuid()}`;
const target = `${domain}/${label}`;
const plist = join(homedir(), 'Library', 'LaunchAgents', `${label}.plist`);
const data = join(root, '.nova-data');
const xml = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
const launch = (...args) => execFileSync('/bin/launchctl', args, {encoding:'utf8', stdio:['ignore','pipe','pipe']});
const loaded = () => { try { launch('print', target); return true; } catch { return false; } };
const wait = ms => new Promise(ok => setTimeout(ok, ms));
const command = process.argv[2];
if (command === 'install') {
  mkdirSync(dirname(plist), {recursive:true});
  mkdirSync(data, {recursive:true, mode:0o700});
  const env = {
    NOVA_DB: resolve(process.env.NOVA_DB ?? join(data, 'nova.sqlite')),
    NOVA_WORKSPACE: resolve(process.env.NOVA_WORKSPACE ?? root),
    NOVA_PORT: process.env.NOVA_PORT ?? '8787',
    PATH: `${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`
  };
  if (loaded()) launch('bootout', target);
  writeFileSync(plist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${label}</string>
<key>ProgramArguments</key><array><string>${xml(process.execPath)}</string><string>${xml(join(root,'core/server.mjs'))}</string></array>
<key>WorkingDirectory</key><string>${xml(root)}</string>
<key>EnvironmentVariables</key><dict>${Object.entries(env).map(([k,v])=>`<key>${k}</key><string>${xml(v)}</string>`).join('')}</dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
<key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>${xml(join(data,'core.log'))}</string>
<key>StandardErrorPath</key><string>${xml(join(data,'core-error.log'))}</string>
</dict></plist>
`, {mode:0o600});
  execFileSync('/usr/bin/plutil', ['-lint', plist], {stdio:'inherit'});
  // bootout can return before launchd releases the old job registration.
  // Retry only that transient bootstrap error, without elevated privileges.
  for (let attempt = 0; ; attempt++) {
    try { launch('bootstrap', domain, plist); break; }
    catch (error) {
      if (attempt >= 20 || !String(error.stderr).includes('Bootstrap failed: 5:')) throw error;
      await wait(250);
    }
  }
  let ready = false;
  for (let attempt = 0; attempt < 150; attempt++) {
    try {
      const response = await fetch(`http://127.0.0.1:${env.NOVA_PORT}/v1/health`, {signal:AbortSignal.timeout(1000)});
      if (response.ok && (await response.json()).service === 'nova-core') { ready = true; break; }
    } catch { /* launchd may still be starting Node */ }
    await wait(100);
  }
  if (!ready) throw new Error(`Login service registered but Core is not healthy. Inspect ${join(data, 'core-error.log')}`);
  console.log('Nova Core login service installed. It restarts after crashes and at login.');
  console.log(`Logs: ${data}`);
} else if (command === 'remove') {
  if (loaded()) launch('bootout', target);
  if (existsSync(plist)) unlinkSync(plist);
  console.log('Nova Core login service removed. Saved data is preserved.');
} else if (command === 'status') {
  console.log(loaded() ? launch('print', target) : 'Nova Core login service is not loaded.');
} else {
  console.error('Usage: node core/service.mjs install | status | remove');
  process.exitCode = 1;
}
