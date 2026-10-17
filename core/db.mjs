import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, openSync, closeSync, chmodSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomBytes, randomInt, createHash, timingSafeEqual } from 'node:crypto';

const now = () => new Date().toISOString();
const hash = text => createHash('sha256').update(text).digest('hex');
const equals = (a, b) => { const x = Buffer.from(a, 'hex'), y = Buffer.from(b, 'hex'); return x.length === y.length && timingSafeEqual(x, y); };
const random = count => randomBytes(count).toString('base64url');
export const INVITATION_MS = 10 * 60_000;
// Crockford base32: no I, L, O or U, so a typed code survives common misreadings.
const SHORT_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
export const normalizeShortCode = text => String(text).toUpperCase().replace(/[^0-9A-Z]/g, '').replace(/O/g, '0').replace(/[IL]/g, '1');
const shortCode = () => Array.from({ length: 8 }, () => SHORT_ALPHABET[randomInt(32)]).join('');

export class Store {
  constructor(file) {
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    closeSync(openSync(file, 'a', 0o600));
    chmodSync(file, 0o600);
    for (const suffix of ['-wal', '-shm']) {
      if (existsSync(file + suffix)) chmodSync(file + suffix, 0o600);
    }
    this.db = new DatabaseSync(file);
    this.db.exec('PRAGMA busy_timeout=5000');
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
      CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS invitations(
        code_hash TEXT PRIMARY KEY, expires_ms INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS devices(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS jobs(
        id TEXT PRIMARY KEY, device_id TEXT NOT NULL, type TEXT NOT NULL,
        status TEXT NOT NULL, payload TEXT NOT NULL, result TEXT, error TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS events(
        id INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT, kind TEXT NOT NULL,
        description TEXT NOT NULL, created_at TEXT NOT NULL);`);
    this.db.exec(`CREATE TABLE IF NOT EXISTS ai_usage(
      job_id TEXT PRIMARY KEY, amount_micros INTEGER NOT NULL, confirmed INTEGER NOT NULL DEFAULT 0);`);
    this.db.exec(`CREATE TABLE IF NOT EXISTS schedules(
        id TEXT PRIMARY KEY, device_id TEXT NOT NULL, title TEXT NOT NULL, task TEXT NOT NULL, spec TEXT NOT NULL,
        uses_computer INTEGER NOT NULL, monitor INTEGER NOT NULL, next_ms INTEGER, until_ms INTEGER,
        runs INTEGER NOT NULL DEFAULT 0, last_run TEXT, last_result TEXT, created_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS reports(
        id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, job_id TEXT, source TEXT NOT NULL,
        title TEXT NOT NULL, message TEXT NOT NULL, visuals TEXT, ok INTEGER NOT NULL, created_at TEXT NOT NULL);`);
    this.db.prepare("INSERT OR IGNORE INTO settings(key,value) VALUES('stopped','0')").run();
    const columns = this.db.prepare('PRAGMA table_info(invitations)').all().map(c => c.name);
    if (!columns.includes('short_hash')) this.db.exec('ALTER TABLE invitations ADD COLUMN short_hash TEXT');
    if (!columns.includes('role')) this.db.exec("ALTER TABLE invitations ADD COLUMN role TEXT NOT NULL DEFAULT 'member'");
    this.db.exec('CREATE INDEX IF NOT EXISTS invitations_short ON invitations(short_hash)');
    // Installs from before Nova had ranges gave the owner iPhone whole-Mac control; keep that.
    if (this.setting('access_level') === null && this.setting('computer_owner') !== null) {
      this.setSetting('access_level', 'full');
      this.setSetting('access_chosen', '1');
    }
  }
  // Called only when Nova Core starts, not by a concurrent pairing CLI.
  reconcileStartup() {
    this.db.prepare("UPDATE jobs SET status='interrupted',error='Core restarted before outcome was confirmed',updated_at=? WHERE status IN ('running','queued','awaiting_approval')").run(now());
  }
  close() { this.db.close(); }
  aiSpent() { return this.db.prepare('SELECT COALESCE(SUM(amount_micros),0) AS amount FROM ai_usage').get().amount; }
  reserveAI(id, amount, cap) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      if (this.aiSpent() + amount > cap) { this.db.exec('ROLLBACK'); return false; }
      this.db.prepare('INSERT INTO ai_usage(job_id,amount_micros) VALUES(?,?)').run(id,amount);
      this.db.exec('COMMIT'); return true;
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  settleAI(id, amount) { this.db.prepare('UPDATE ai_usage SET amount_micros=?,confirmed=1 WHERE job_id=?').run(amount,id); }
  aiHistory(deviceId) {
    const rows = this.db.prepare("SELECT payload,result FROM jobs WHERE device_id=? AND type='ai.chat' AND status='succeeded' ORDER BY rowid DESC LIMIT 2").all(deviceId).reverse();
    // Bounded, per-device context only. Repository contents and unrelated jobs are never sent.
    return rows.flatMap(row => [{role:'user',content:JSON.parse(row.payload).message.slice(0,1000)},
      {role:'assistant',content:JSON.parse(row.result).message.slice(0,1500)}]);
  }
  issueInvitation() { return this.createInvitation().code; }
  /// One invitation, two ways to redeem it once: the QR secret (144 bits) or a typed
  /// 8-character code (40 bits, protected by expiry and Core's attempt limit).
  /// An owner invitation can only be made on the Mac and lets that iPhone control it.
  createInvitation({ owner = false } = {}) {
    const code = random(18), short = shortCode(), expiresMs = Date.now() + INVITATION_MS;
    this.db.prepare('INSERT INTO invitations(code_hash,short_hash,expires_ms,role) VALUES(?,?,?,?)').run(hash(code), hash(short), expiresMs, owner ? 'owner' : 'member');
    return { code, short: `${short.slice(0, 4)}-${short.slice(4)}`, expiresMs, owner };
  }
  redeemInvitation(code, name) {
    if (typeof code !== 'string' || !code) return null;
    const short = normalizeShortCode(code);
    const row = this.db.prepare('SELECT * FROM invitations WHERE code_hash=? OR (short_hash IS NOT NULL AND short_hash=?)').get(hash(code), short.length === 8 ? hash(short) : '-');
    if (!row || row.used || row.expires_ms <= Date.now()) return null;
    const token = random(32);
    const id = random(12);
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const updated = this.db.prepare('UPDATE invitations SET used=1 WHERE code_hash=? AND used=0 AND expires_ms>?').run(row.code_hash, Date.now());
      if (updated.changes !== 1) { this.db.exec('ROLLBACK'); return null; }
      this.db.prepare('INSERT INTO devices(id,name,token_hash,created_at) VALUES(?,?,?,?)').run(id, name, hash(token), now());
      if (row.role === 'owner') this.setSetting('computer_owner', id);
      this.db.exec('COMMIT');
      if (row.role === 'owner') this.event(null, 'computer_owner', `${name} paired as the owner from a code made on the Mac`);
      return { id, token, owner: row.role === 'owner' };
    } catch (err) { this.db.exec('ROLLBACK'); throw err; }
  }
  /// Ends every unused invitation, for example after too many wrong codes.
  expireInvitations() { this.db.prepare('UPDATE invitations SET used=1 WHERE used=0').run(); }
  auth(token) {
    if (!token || token.length < 40 || token.length > 150) return null;
    const h = hash(token);
    // Hash lookup; no plaintext tokens are ever stored in SQLite.
    const row = this.db.prepare('SELECT id,name,token_hash FROM devices WHERE token_hash=?').get(h);
    return row && equals(row.token_hash, h) ? { id: row.id, name: row.name } : null;
  }
  devices() { return this.db.prepare('SELECT id,name,created_at FROM devices ORDER BY created_at').all(); }
  revokeDevice(id) {
    const removed = this.db.prepare('DELETE FROM devices WHERE id=?').run(id).changes === 1;
    if (removed && this.setting('computer_owner') === id) this.setSetting('computer_owner', null);
    if (removed) this.event(null, 'revoke', 'A paired device was removed');
    return removed;
  }
  stopped() { return this.db.prepare("SELECT value FROM settings WHERE key='stopped'").get().value === '1'; }
  stop() {
    this.db.prepare("UPDATE settings SET value='1' WHERE key='stopped'").run();
    this.db.prepare("UPDATE jobs SET status='cancelled',updated_at=? WHERE status IN ('queued','awaiting_approval')").run(now());
    this.event(null, 'stop', 'Remote emergency stop activated');
  }
  resume() { this.db.prepare("UPDATE settings SET value='0' WHERE key='stopped'").run(); this.event(null, 'resume', 'Locally resumed'); }
  setting(key) { return this.db.prepare('SELECT value FROM settings WHERE key=?').get(key)?.value ?? null; }
  setSetting(key, value) {
    if (value === null) this.db.prepare('DELETE FROM settings WHERE key=?').run(key);
    else this.db.prepare('INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(key, value);
  }
  event(jobId, kind, description) {
    this.db.prepare('INSERT INTO events(job_id,kind,description,created_at) VALUES(?,?,?,?)').run(jobId, kind, description, now());
  }
  createJob(deviceId, type, payload) {
    const id = random(12), stamp = now();
    this.db.prepare('INSERT INTO jobs(id,device_id,type,status,payload,created_at,updated_at) VALUES(?,?,?,?,?,?,?)').run(id, deviceId, type, 'queued', JSON.stringify(payload), stamp, stamp);
    this.event(id, 'queued', `Requested ${type}`);
    return id;
  }
  updateJob(id, status, result = null, error = null) {
    this.db.prepare('UPDATE jobs SET status=?,result=?,error=?,updated_at=? WHERE id=?').run(status, result === null ? null : JSON.stringify(result), error, now(), id);
    this.event(id, status, error || `Job ${status}`);
  }
  getJob(id, deviceId) {
    const row = this.db.prepare('SELECT id,type,status,payload,result,error,created_at,updated_at FROM jobs WHERE id=? AND device_id=?').get(id, deviceId);
    if (!row) return null;
    return { ...row, payload: JSON.parse(row.payload), result: row.result === null ? null : JSON.parse(row.result) };
  }
  jobs(deviceId) {
    return this.db.prepare('SELECT id,type,status,created_at,updated_at FROM jobs WHERE device_id=? ORDER BY created_at DESC LIMIT 50').all(deviceId);
  }
  events(jobId) { return this.db.prepare('SELECT kind,description,created_at FROM events WHERE job_id=? ORDER BY id ASC LIMIT 100').all(jobId); }
}
