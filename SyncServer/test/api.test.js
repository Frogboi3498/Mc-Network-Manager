'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');
const { createApp } = require('../server.js');

const KEY_A = 'a'.repeat(64);
const KEY_B = 'b'.repeat(64);
const SALT = Buffer.alloc(16, 7).toString('base64');

async function start(opts = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcnm-test-'));
  const server = createApp({ dataDir: dir, ...opts });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, p, body, token) => {
    const res = await fetch(base + p, {
      method,
      headers: {
        ...(body ? { 'Content-Type': 'application/json' } : {}),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    return { status: res.status, json: text ? JSON.parse(text) : null };
  };
  return { server, call, dir };
}

test('register, login, wrong password, case-insensitive username', async () => {
  const { server, call } = await start();
  try {
    const reg = await call('POST', '/api/register', { username: 'Alice', kdfSalt: SALT, authKey: KEY_A });
    assert.equal(reg.status, 201);
    assert.match(reg.json.token, /^[0-9a-f]{64}$/);

    const dup = await call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A });
    assert.equal(dup.status, 409);

    const ok = await call('POST', '/api/login', { username: 'ALICE', authKey: KEY_A });
    assert.equal(ok.status, 200);

    const bad = await call('POST', '/api/login', { username: 'alice', authKey: KEY_B });
    assert.equal(bad.status, 401);

    const none = await call('POST', '/api/login', { username: 'nobody', authKey: KEY_A });
    assert.equal(none.status, 401);
  } finally {
    server.close();
  }
});

test('salt endpoint returns stored salt, and a stable fake for unknown users', async () => {
  const { server, call } = await start();
  try {
    await call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A });
    const real = await call('GET', '/api/salt?username=alice');
    assert.equal(real.json.kdfSalt, SALT);
    const f1 = await call('GET', '/api/salt?username=ghost');
    const f2 = await call('GET', '/api/salt?username=ghost');
    assert.equal(f1.json.kdfSalt, f2.json.kdfSalt);
    assert.notEqual(f1.json.kdfSalt, SALT);
    assert.equal((await call('GET', '/api/salt?username=a')).status, 400);
  } finally {
    server.close();
  }
});

test('input validation', async () => {
  const { server, call } = await start();
  try {
    assert.equal((await call('POST', '/api/register', { username: 'x', kdfSalt: SALT, authKey: KEY_A })).status, 400);
    assert.equal((await call('POST', '/api/register', { username: 'alice', kdfSalt: 'AAAA', authKey: KEY_A })).status, 400);
    assert.equal((await call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: 'short' })).status, 400);
    assert.equal((await call('GET', '/api/nope')).status, 404);
  } finally {
    server.close();
  }
});

test('vault requires auth, round-trips, and detects conflicts', async () => {
  const { server, call } = await start();
  try {
    assert.equal((await call('GET', '/api/vault')).status, 401);
    const { json } = await call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A });
    const t = json.token;

    assert.equal((await call('GET', '/api/vault', null, t)).status, 404);

    const put1 = await call('PUT', '/api/vault', { baseRevision: 0, blob: 'Zmlyc3Q=' }, t);
    assert.equal(put1.status, 200);
    assert.equal(put1.json.revision, 1);

    const get = await call('GET', '/api/vault', null, t);
    assert.equal(get.json.blob, 'Zmlyc3Q=');
    assert.equal(get.json.revision, 1);

    // A second device that missed revision 1 tries to write on top of revision 0.
    const stale = await call('PUT', '/api/vault', { baseRevision: 0, blob: 'c3RhbGU=' }, t);
    assert.equal(stale.status, 409);
    assert.equal(stale.json.revision, 1);
    assert.equal(stale.json.blob, 'Zmlyc3Q=');

    const put2 = await call('PUT', '/api/vault', { baseRevision: 1, blob: 'c2Vjb25k' }, t);
    assert.equal(put2.json.revision, 2);

    assert.equal((await call('PUT', '/api/vault', { baseRevision: 'x', blob: 'a' }, t)).status, 400);
    assert.equal((await call('PUT', '/api/vault', { baseRevision: 2, blob: '' }, t)).status, 400);
  } finally {
    server.close();
  }
});

test('accounts are isolated from each other', async () => {
  const { server, call } = await start();
  try {
    const a = (await call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A })).json.token;
    const b = (await call('POST', '/api/register', { username: 'bobby', kdfSalt: SALT, authKey: KEY_B })).json.token;
    await call('PUT', '/api/vault', { baseRevision: 0, blob: 'QUxJQ0U=' }, a);
    assert.equal((await call('GET', '/api/vault', null, b)).status, 404);
  } finally {
    server.close();
  }
});

test('logout invalidates the token; data persists across restart', async () => {
  const { server, call, dir } = await start();
  const t = (await call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A })).json.token;
  await call('PUT', '/api/vault', { baseRevision: 0, blob: 'cGVyc2lzdA==' }, t);
  assert.equal((await call('POST', '/api/logout', null, t)).status, 204);
  assert.equal((await call('GET', '/api/vault', null, t)).status, 401);
  server.close();

  const s2 = createApp({ dataDir: dir });
  await new Promise((r) => s2.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${s2.address().port}`;
  try {
    const login = await fetch(base + '/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'alice', authKey: KEY_A }),
    });
    assert.equal(login.status, 200);
    const { token } = await login.json();
    const vault = await fetch(base + '/api/vault', { headers: { Authorization: `Bearer ${token}` } });
    assert.equal((await vault.json()).blob, 'cGVyc2lzdA==');
  } finally {
    s2.close();
  }
});

test('login is rate limited after repeated failures', async () => {
  const { server, call } = await start();
  try {
    await call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A });
    let last;
    for (let i = 0; i < 11; i++) {
      last = await call('POST', '/api/login', { username: 'alice', authKey: KEY_B });
    }
    assert.equal(last.status, 429);
    const right = await call('POST', '/api/login', { username: 'alice', authKey: KEY_A });
    assert.equal(right.status, 429);
  } finally {
    server.close();
  }
});

test('registration can be disabled or require an invite code', async () => {
  const closed = await start({ allowRegistration: false });
  try {
    assert.equal((await closed.call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A })).status, 403);
  } finally {
    closed.server.close();
  }
  const invite = await start({ inviteCode: 'secret-code' });
  try {
    const no = await invite.call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A });
    assert.equal(no.status, 403);
    const yes = await invite.call('POST', '/api/register', {
      username: 'alice', kdfSalt: SALT, authKey: KEY_A, inviteCode: 'secret-code',
    });
    assert.equal(yes.status, 201);
  } finally {
    invite.server.close();
  }
});

test('account deletion needs the auth key and removes data and sessions', async () => {
  const { server, call } = await start();
  try {
    const t = (await call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A })).json.token;
    assert.equal((await call('DELETE', '/api/account', { authKey: KEY_B }, t)).status, 401);
    assert.equal((await call('DELETE', '/api/account', { authKey: KEY_A }, t)).status, 204);
    assert.equal((await call('GET', '/api/vault', null, t)).status, 401);
    assert.equal((await call('POST', '/api/login', { username: 'alice', authKey: KEY_A })).status, 401);
  } finally {
    server.close();
  }
});

test('rejects oversized and malformed bodies', async () => {
  const { server, call } = await start();
  try {
    const t = (await call('POST', '/api/register', { username: 'alice', kdfSalt: SALT, authKey: KEY_A })).json.token;
    const big = await call('PUT', '/api/vault', { baseRevision: 0, blob: 'A'.repeat(950 * 1024) }, t);
    assert.equal(big.status, 400);
    const res = await fetch(server.address() && `http://127.0.0.1:${server.address().port}/api/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{not json',
    });
    assert.equal(res.status, 400);
  } finally {
    server.close();
  }
});
