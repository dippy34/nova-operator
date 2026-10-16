import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';

const now = () => new Date().toISOString();
const hash = text => createHash('sha256').update(text).digest('hex');
const equals = (a, b) => { const x = Buffer.from(a, 'hex'), y = Buffer.from(b, 'hex'); return x.length === y.length && timingSafeEqual(x, y); };
const random = count => randomBytes(count).toString('base64url');

export class Store {
  constructor(file) {
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(file);
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
    this.db.prepare("INSERT OR IGNORE INTO settings(key,value) VALUES('stopped','0')").run();

  }
  // Called only when Nova Core starts, not by a concurrent pairing CLI.
  reconcileStartup() {
    this.db.prepare("UPDATE jobs SET status='interrupted',error='Core restarted before outcome was confirmed',updated_at=? WHERE status IN ('running','queued')").run(now());
  }
  close() { this.db.close(); }
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
  stopped() { return this.db.prepare("SELECT value FROM settings WHERE key='stopped'").get().value === '1'; }
  stop() {
    this.db.prepare("UPDATE settings SET value='1' WHERE key='stopped'").run();
    this.db.prepare("UPDATE jobs SET status='cancelled',updated_at=? WHERE status='queued'").run(now());
    this.event(null, 'stop', 'Remote emergency stop activated');
  }
  resume() { this.db.prepare("UPDATE settings SET value='0' WHERE key='stopped'").run(); this.event(null, 'resume', 'Locally resumed'); }
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
