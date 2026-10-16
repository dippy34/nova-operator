import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, openSync, closeSync, chmodSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';

const now = () => new Date().toISOString();
const hash = text => createHash('sha256').update(text).digest('hex');
const equals = (a, b) => { const x = Buffer.from(a, 'hex'), y = Buffer.from(b, 'hex'); return x.length === y.length && timingSafeEqual(x, y); };
const random = count => randomBytes(count).toString('base64url');

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
  issueInvitation() {
    const code = random(18); // 144 bits of random pairing entropy
    this.db.prepare('INSERT INTO invitations(code_hash,expires_ms) VALUES(?,?)').run(hash(code), Date.now() + 10 * 60_000);
    return code;
  }
  redeemInvitation(code, name) {
    const codeHash = hash(code);
    const row = this.db.prepare('SELECT * FROM invitations WHERE code_hash=?').get(codeHash);
    if (!row || row.used || row.expires_ms <= Date.now()) return null;
    const token = random(32);
    const id = random(12);
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const updated = this.db.prepare('UPDATE invitations SET used=1 WHERE code_hash=? AND used=0 AND expires_ms>?').run(codeHash, Date.now());
      if (updated.changes !== 1) { this.db.exec('ROLLBACK'); return null; }
      this.db.prepare('INSERT INTO devices(id,name,token_hash,created_at) VALUES(?,?,?,?)').run(id, name, hash(token), now());
      this.db.exec('COMMIT');
      return { id, token };
    } catch (err) { this.db.exec('ROLLBACK'); throw err; }
  }
  auth(token) {
    if (!token || token.length < 40 || token.length > 150) return null;
    const h = hash(token);
    // Hash lookup; no plaintext tokens are ever stored in SQLite.
    const row = this.db.prepare('SELECT id,name,token_hash FROM devices WHERE token_hash=?').get(h);
    return row && equals(row.token_hash, h) ? { id: row.id, name: row.name } : null;
  }
  devices() { return this.db.prepare('SELECT id,name,created_at FROM devices ORDER BY created_at').all(); }
  revokeDevice(id) { return this.db.prepare('DELETE FROM devices WHERE id=?').run(id).changes === 1; }
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
