import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { paths as defaultPaths } from './paths.mjs';

export const label = 'dev.nova.operator.core';
const xml = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));

/// Core's LaunchAgent, built only from the shared paths so the service, CLI and native
/// executor use the same runtime, database, key and logs.
export function servicePlist(paths = defaultPaths) {
  // Development keeps reporting the checkout's Git status, as before. A packaged app has no checkout.
  const workspace = paths.workspace ?? (paths.layout === 'development' ? paths.root : null);
  const env = {
    NOVA_DATA_DIR: paths.data,
    NOVA_DB: paths.db,
    ...(workspace ? { NOVA_WORKSPACE: workspace } : {}),
    NOVA_PORT: String(paths.port),
    PATH: `${dirname(paths.runtime)}:/usr/bin:/bin:/usr/sbin:/sbin`
  };
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${label}</string>
<key>ProgramArguments</key><array><string>${xml(paths.runtime)}</string><string>${xml(join(paths.core,'server.mjs'))}</string></array>
<key>WorkingDirectory</key><string>${xml(paths.layout === 'development' ? paths.root : paths.data)}</string>
<key>EnvironmentVariables</key><dict>${Object.entries(env).map(([k,v])=>`<key>${k}</key><string>${xml(v)}</string>`).join('')}</dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
<key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>${xml(paths.log)}</string>
<key>StandardErrorPath</key><string>${xml(paths.errorLog)}</string>
</dict></plist>
`;
}

async function main(paths = defaultPaths) {
  if (process.platform !== 'darwin') throw new Error('The login service requires macOS');
  const domain = `gui/${process.getuid()}`;
  const target = `${domain}/${label}`;
  const plist = join(homedir(), 'Library', 'LaunchAgents', `${label}.plist`);
  const launch = (...args) => execFileSync('/bin/launchctl', args, {encoding:'utf8', stdio:['ignore','pipe','pipe']});
  const loaded = () => { try { launch('print', target); return true; } catch { return false; } };
  const wait = ms => new Promise(ok => setTimeout(ok, ms));
  const command = process.argv[2];
  if (command === 'install') {
    mkdirSync(dirname(plist), {recursive:true});
    mkdirSync(paths.data, {recursive:true, mode:0o700});
    if (loaded()) launch('bootout', target);
    writeFileSync(plist, servicePlist(paths), {mode:0o600});
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
        const response = await fetch(`http://127.0.0.1:${paths.port}/v1/health`, {signal:AbortSignal.timeout(1000)});
        if (response.ok && (await response.json()).service === 'nova-core') { ready = true; break; }
      } catch { /* launchd may still be starting Node */ }
      await wait(100);
    }
    if (!ready) throw new Error(`Login service registered but Core is not healthy. Inspect ${paths.errorLog}`);
    console.log('Nova Core login service installed. It restarts after crashes and at login.');
    console.log(`Logs: ${paths.data}`);
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
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main();
