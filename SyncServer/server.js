#!/usr/bin/env node
'use strict';
/**
 * MC Network Manager - sync server.
 *
 * A tiny, dependency-free account + encrypted-vault store. Run it on your own
 * machine (`node server.js`) and point the app at it.
 *
 * Zero-knowledge design: the app derives two keys from the account password
 * with PBKDF2. One (authKey) is sent to this server to prove identity, the
 * other never leaves the device and encrypts the vault. The server therefore
 * only ever stores an opaque encrypted blob and a hash of the authKey.
 */

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const MAX_BODY_BYTES = 1024 * 1024;
const MAX_BLOB_CHARS = 900 * 1024;
const TOKEN_TTL_MS = 30 * 24 * 3600 * 1000;
const KDF_ITERATIONS = 600000;
const USERNAME_RE = /^[a-z0-9._-]{3,32}$/;
const HEX64_RE = /^[0-9a-f]{64}$/;
const FAIL_WINDOW_MS = 15 * 60 * 1000;
const MAX_FAILS = 10;

function createApp(options = {}) {
  const dataDir = options.dataDir || path.join(__dirname, 'data');
  const allowRegistration = options.allowRegistration !== false;
  const inviteCode = options.inviteCode || '';
  const dbFile = path.join(dataDir, 'db.json');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });

  let db = { serverSecret: crypto.randomBytes(32).toString('hex'), users: {}, sessions: {} };
  if (fs.existsSync(dbFile)) {
    db = JSON.parse(fs.readFileSync(dbFile, 'utf8'));
  }

  function save() {
    const tmp = dbFile + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(db), { mode: 0o600 });
    fs.renameSync(tmp, dbFile);
  }
  save();

  const fails = new Map(); // "ip|user" -> [timestamps]

  function tooManyFails(key) {
    const now = Date.now();
    const list = (fails.get(key) || []).filter((t) => now - t < FAIL_WINDOW_MS);
    fails.set(key, list);
    return list.length >= MAX_FAILS;
  }
  function recordFail(key) {
    const list = fails.get(key) || [];
    list.push(Date.now());
    fails.set(key, list);
  }

  const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

  function safeEqual(a, b) {
    const ba = Buffer.from(String(a));
    const bb = Buffer.from(String(b));
    if (ba.length !== bb.length) return false;
    return crypto.timingSafeEqual(ba, bb);
  }

  function hashAuthKey(authKey, saltHex) {
    return crypto.scryptSync(authKey, Buffer.from(saltHex, 'hex'), 32).toString('hex');
  }

  function fakeSalt(username) {
    return crypto
      .createHmac('sha256', db.serverSecret)
      .update('salt:' + username)
      .digest()
      .subarray(0, 16)
      .toString('base64');
  }

  function newSession(username) {
    const token = crypto.randomBytes(32).toString('hex');
    db.sessions[sha256(token)] = { username, expires: Date.now() + TOKEN_TTL_MS };
    return token;
  }

  function pruneSessions() {
    const now = Date.now();
    for (const [k, v] of Object.entries(db.sessions)) {
      if (v.expires < now) delete db.sessions[k];
    }
  }

  function authenticate(req) {
    const header = req.headers['authorization'] || '';
    const m = /^Bearer ([0-9a-f]{64})$/.exec(header);
    if (!m) return null;
    const s = db.sessions[sha256(m[1])];
    if (!s || s.expires < Date.now() || !db.users[s.username]) return null;
    return { username: s.username, tokenHash: sha256(m[1]) };
  }

  function send(res, status, body) {
    const payload = body === undefined ? '' : JSON.stringify(body);
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    });
    res.end(payload);
  }

  function readJson(req) {
    return new Promise((resolve, reject) => {
      let size = 0;
      const chunks = [];
      req.on('data', (c) => {
        size += c.length;
        if (size > MAX_BODY_BYTES) {
          reject(Object.assign(new Error('too_large'), { status: 413 }));
          req.destroy();
          return;
        }
        chunks.push(c);
      });
      req.on('end', () => {
        if (size === 0) return resolve({});
        try {
          const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
            throw new Error('not_object');
          }
          resolve(parsed);
        } catch {
          reject(Object.assign(new Error('bad_json'), { status: 400 }));
        }
      });
      req.on('error', reject);
    });
  }

  function validBase64(s, minBytes, maxBytes) {
    if (typeof s !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(s)) return false;
    const len = Buffer.from(s, 'base64').length;
    return len >= minBytes && len <= maxBytes;
  }

  const handler = async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      const route = `${req.method} ${url.pathname}`;
      const ip = req.socket.remoteAddress || 'unknown';

      if (route === 'GET /health') return send(res, 200, { ok: true });

      if (route === 'GET /api/salt') {
        const username = (url.searchParams.get('username') || '').toLowerCase();
        if (!USERNAME_RE.test(username)) return send(res, 400, { error: 'bad_username' });
        const user = db.users[username];
        return send(res, 200, {
          kdfSalt: user ? user.kdfSalt : fakeSalt(username),
          iterations: KDF_ITERATIONS,
        });
      }

      if (route === 'POST /api/register') {
        if (!allowRegistration) return send(res, 403, { error: 'registration_disabled' });
        const b = await readJson(req);
        const username = String(b.username || '').toLowerCase();
        if (!USERNAME_RE.test(username)) return send(res, 400, { error: 'bad_username' });
        if (!validBase64(b.kdfSalt, 16, 64)) return send(res, 400, { error: 'bad_salt' });
        if (typeof b.authKey !== 'string' || !HEX64_RE.test(b.authKey)) {
          return send(res, 400, { error: 'bad_auth_key' });
        }
        if (inviteCode && !safeEqual(b.inviteCode || '', inviteCode)) {
          return send(res, 403, { error: 'bad_invite_code' });
        }
        if (db.users[username]) return send(res, 409, { error: 'username_taken' });
        const authSalt = crypto.randomBytes(16).toString('hex');
        db.users[username] = {
          kdfSalt: b.kdfSalt,
          authSalt,
          authHash: hashAuthKey(b.authKey, authSalt),
          vault: null,
          createdAt: new Date().toISOString(),
        };
        pruneSessions();
        const token = newSession(username);
        save();
        return send(res, 201, { token });
      }

      if (route === 'POST /api/login') {
        const b = await readJson(req);
        const username = String(b.username || '').toLowerCase();
        const key = `${ip}|${username}`;
        if (tooManyFails(key)) return send(res, 429, { error: 'too_many_attempts' });
        const user = USERNAME_RE.test(username) ? db.users[username] : null;
        const authKey = typeof b.authKey === 'string' && HEX64_RE.test(b.authKey) ? b.authKey : null;
        // Always do the hash work so timing does not reveal whether the user exists.
        const salt = user ? user.authSalt : '00'.repeat(16);
        const computed = hashAuthKey(authKey || '0'.repeat(64), salt);
        const ok = user && authKey && safeEqual(computed, user.authHash);
        if (!ok) {
          recordFail(key);
          return send(res, 401, { error: 'invalid_credentials' });
        }
        fails.delete(key);
        pruneSessions();
        const token = newSession(username);
        save();
        return send(res, 200, { token });
      }

      if (route === 'POST /api/logout') {
        const a = authenticate(req);
        if (!a) return send(res, 401, { error: 'unauthorized' });
        delete db.sessions[a.tokenHash];
        save();
        return send(res, 204);
      }

      if (route === 'GET /api/vault') {
        const a = authenticate(req);
        if (!a) return send(res, 401, { error: 'unauthorized' });
        const v = db.users[a.username].vault;
        if (!v) return send(res, 404, { error: 'no_vault' });
        return send(res, 200, v);
      }

      if (route === 'PUT /api/vault') {
        const a = authenticate(req);
        if (!a) return send(res, 401, { error: 'unauthorized' });
        const b = await readJson(req);
        if (!Number.isInteger(b.baseRevision) || b.baseRevision < 0) {
          return send(res, 400, { error: 'bad_revision' });
        }
        if (typeof b.blob !== 'string' || b.blob.length === 0 || b.blob.length > MAX_BLOB_CHARS) {
          return send(res, 400, { error: 'bad_blob' });
        }
        const user = db.users[a.username];
        const current = user.vault ? user.vault.revision : 0;
        if (b.baseRevision !== current) return send(res, 409, user.vault);
        user.vault = { revision: current + 1, blob: b.blob, updatedAt: new Date().toISOString() };
        save();
        return send(res, 200, { revision: user.vault.revision, updatedAt: user.vault.updatedAt });
      }

      if (route === 'DELETE /api/account') {
        const a = authenticate(req);
        if (!a) return send(res, 401, { error: 'unauthorized' });
        const b = await readJson(req);
        const user = db.users[a.username];
        const authKey = typeof b.authKey === 'string' && HEX64_RE.test(b.authKey) ? b.authKey : null;
        if (!authKey || !safeEqual(hashAuthKey(authKey, user.authSalt), user.authHash)) {
          return send(res, 401, { error: 'invalid_credentials' });
        }
        delete db.users[a.username];
        for (const [k, v] of Object.entries(db.sessions)) {
          if (v.username === a.username) delete db.sessions[k];
        }
        save();
        return send(res, 204);
      }

      return send(res, 404, { error: 'not_found' });
    } catch (err) {
      const status = err && err.status ? err.status : 500;
      if (status === 500) console.error(err);
      return send(res, status, { error: status === 500 ? 'server_error' : err.message });
    }
  };

  const server = http.createServer(handler);
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  return server;
}

module.exports = { createApp };

if (require.main === module) {
  const port = parseInt(process.env.PORT || '8787', 10);
  const host = process.env.HOST || '0.0.0.0';
  const server = createApp({
    dataDir: process.env.DATA_DIR,
    allowRegistration: (process.env.ALLOW_REGISTRATION || 'true') !== 'false',
    inviteCode: process.env.INVITE_CODE || '',
  });
  server.listen(port, host, () => {
    console.log(`MC Network Manager sync server listening on http://${host}:${port}`);
    if (!process.env.INVITE_CODE && (process.env.ALLOW_REGISTRATION || 'true') !== 'false') {
      console.log('Note: registration is open. Set INVITE_CODE=... or ALLOW_REGISTRATION=false once your accounts exist.');
    }
  });
}
