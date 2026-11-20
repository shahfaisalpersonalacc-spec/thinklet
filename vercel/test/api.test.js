// Backend tests: run with `npm test` in thinklet/vercel. No database needed;
// the routes run against the in-memory repository.
import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

process.env.APP_USERNAME = 'me';
process.env.APP_PASSWORD = 'pa55word';
process.env.AUTH_SECRET = 'test-secret-that-is-long-enough';

const { signToken, verifyToken } = await import('../lib/auth.js');
const { setRepo } = await import('../lib/db.js');
const { memoryRepo } = await import('../lib/memory-repo.js');
const login = (await import('../api/login.js')).default;
const history = (await import('../api/history.js')).default;
const notes = (await import('../api/notes.js')).default;
const claude = (await import('../api/claude.js')).default;

let repo;
let clock;
beforeEach(() => {
  clock = Date.parse('2026-11-20T10:00:00Z');
  repo = memoryRepo({ now: () => new Date((clock += 1000)) });
  setRepo(repo);
});

/** Calls a route like Vercel would; resolves to {status, body}. */
async function call(handler, { method = 'GET', query = {}, body, token, headers = {} } = {}) {
  const res = {
    statusCode: 200,
    headers: {},
    headersSent: false,
    status(c) {
      this.statusCode = c;
      return this;
    },
    setHeader(k, v) {
      this.headers[k] = v;
    },
    json(b) {
      this.body = b;
      this.headersSent = true;
      return this;
    },
    send(b) {
      this.body = b;
      this.headersSent = true;
      return this;
    },
    end() {
      this.headersSent = true;
      return this;
    },
  };
  const auth = token ? { authorization: `Bearer ${token}` } : {};
  await handler({ method, query, body, headers: { ...auth, ...headers } }, res);
  return { status: res.statusCode, body: res.body, headers: res.headers };
}

const token = () => signToken('me').token;

test('login: right password gives a working token', async () => {
  const r = await call(login, { method: 'POST', body: { username: 'me', password: 'pa55word' } });
  assert.equal(r.status, 200);
  assert.equal(verifyToken(r.body.token), 'me');
  assert.ok(r.body.expiresAt > Date.now());
});

test('login: wrong password or username is refused', async () => {
  for (const body of [
    { username: 'me', password: 'nope' },
    { username: 'you', password: 'pa55word' },
  ]) {
    const r = await call(login, { method: 'POST', body });
    assert.equal(r.status, 401);
    assert.match(r.body.error.message, /wrong/i);
  }
});

test('tokens: tampered or expired ones are rejected', () => {
  const { token: t } = signToken('me', Date.now());
  const [p, m] = t.split('.');
  const forged = Buffer.from(JSON.stringify({ sub: 'me', exp: 9e15 })).toString('base64url');
  assert.equal(verifyToken(`${forged}.${m}`), null);
  assert.equal(verifyToken(`${p}.${m}x`), null);
  assert.equal(verifyToken(t, Date.now() + 31 * 24 * 3600 * 1000), null);
  assert.equal(verifyToken('garbage'), null);
});

test('every route except login needs a token', async () => {
  for (const [h, method] of [
    [history, 'GET'],
    [notes, 'GET'],
    [notes, 'POST'],
    [claude, 'POST'],
  ]) {
    assert.equal((await call(h, { method })).status, 401);
    assert.equal((await call(h, { method, token: 'bad.token' })).status, 401);
  }
});

test('history: add, list newest first, delete one, clear', async () => {
  const t = token();
  for (const kind of ['Corrected', 'Urdu']) {
    const r = await call(history, { method: 'POST', token: t, body: { kind, before: 'b', after: 'a' } });
    assert.equal(r.status, 200);
  }
  let list = (await call(history, { token: t })).body.history;
  assert.deepEqual(list.map((h) => h.kind), ['Urdu', 'Corrected']);

  await call(history, { method: 'DELETE', token: t, query: { id: list[0].id } });
  list = (await call(history, { token: t })).body.history;
  assert.equal(list.length, 1);

  await call(history, { method: 'DELETE', token: t, query: { all: '1' } });
  assert.equal((await call(history, { token: t })).body.history.length, 0);
});

test('history: bad input is a 400, not a crash', async () => {
  const r = await call(history, { method: 'POST', token: token(), body: { kind: 'x' } });
  assert.equal(r.status, 400);
  const d = await call(history, { method: 'DELETE', token: token(), query: { id: 'nope' } });
  assert.equal(d.status, 400);
});

test('notes: create, edit, views, search, tags, sort', async () => {
  const t = token();
  const make = async (b) => (await call(notes, { method: 'POST', token: t, body: b })).body.note;
  const a = await make({ title: 'Groceries', body: 'milk', tags: ['Home', 'home', ' list '] });
  const b = await make({ title: 'Work plan', body: '50% done', pinned: true });
  const c = await make({ title: 'Old', archived: true });

  assert.deepEqual(a.tags, ['home', 'list']); // trimmed, lower-cased, deduped

  const list = async (query) =>
    (await call(notes, { token: t, query })).body.notes.map((n) => n.title);
  assert.deepEqual(await list({}), ['Work plan', 'Groceries']); // pinned first
  assert.deepEqual(await list({ view: 'pinned' }), ['Work plan']);
  assert.deepEqual(await list({ view: 'archive' }), ['Old']);
  assert.deepEqual(await list({ tag: 'home' }), ['Groceries']);
  assert.deepEqual(await list({ q: 'MILK' }), ['Groceries']);
  assert.deepEqual(await list({ q: '50%' }), ['Work plan']);

  // Editing moves a note up the "last edited" order (among unpinned).
  const d = await make({ title: 'Newer' });
  assert.deepEqual(await list({}), ['Work plan', 'Newer', 'Groceries']);
  const p = await call(notes, { method: 'PATCH', token: t, query: { id: a.id }, body: { body: 'milk, eggs' } });
  assert.equal(p.body.note.body, 'milk, eggs');
  assert.deepEqual(await list({}), ['Work plan', 'Groceries', 'Newer']);
  assert.deepEqual(await list({ sort: 'created' }), ['Work plan', 'Newer', 'Groceries']);
  assert.ok(c && d);
});

test('notes: trash, restore, delete forever, auto-purge after 30 days', async () => {
  const t = token();
  const n = (await call(notes, { method: 'POST', token: t, body: { title: 'Bin me' } })).body.note;

  // Can't delete forever before it's in the trash.
  assert.equal((await call(notes, { method: 'DELETE', token: t, query: { id: n.id } })).status, 404);

  await call(notes, { method: 'POST', token: t, query: { action: 'trash', id: n.id } });
  const views = async (view) => (await call(notes, { token: t, query: { view } })).body.notes.length;
  assert.equal(await views('all'), 0);
  assert.equal(await views('trash'), 1);

  await call(notes, { method: 'POST', token: t, query: { action: 'restore', id: n.id } });
  assert.equal(await views('all'), 1);

  await call(notes, { method: 'POST', token: t, query: { action: 'trash', id: n.id } });
  assert.equal((await call(notes, { method: 'DELETE', token: t, query: { id: n.id } })).status, 200);
  assert.equal(await views('trash'), 0);

  // A note left in the trash for 31 days is gone on the next list.
  const old = (await call(notes, { method: 'POST', token: t, body: { title: 'Old' } })).body.note;
  await call(notes, { method: 'POST', token: t, query: { action: 'trash', id: old.id } });
  clock += 31 * 24 * 3600 * 1000;
  assert.equal(await views('trash'), 0);
});

test('notes: saving the same result twice returns the same note', async () => {
  const t = token();
  const body = { title: 'Correction', body: 'I have an apple.', source: 'correct', source_key: 'k1' };
  const first = await call(notes, { method: 'POST', token: t, body });
  const second = await call(notes, { method: 'POST', token: t, body });
  assert.equal(second.body.note.id, first.body.note.id);
  assert.equal(second.body.existing, true);
  assert.equal(repo.notes.length, 1);
});

test('notes: bad fields are refused', async () => {
  const t = token();
  for (const body of [{ color: 'rainbow' }, { tags: 'x' }, { pinned: 'yes' }, { title: 'x'.repeat(201) }]) {
    assert.equal((await call(notes, { method: 'POST', token: t, body })).status, 400);
  }
  assert.equal((await call(notes, { token: t, query: { view: 'bin' } })).status, 400);
});

test('CORS: local dev origins allowed, others not', async () => {
  const ok = await call(notes, { method: 'OPTIONS', headers: { origin: 'http://192.168.1.140:8080' } });
  assert.equal(ok.status, 204);
  assert.equal(ok.headers['access-control-allow-origin'], 'http://192.168.1.140:8080');
  const bad = await call(notes, { method: 'OPTIONS', headers: { origin: 'https://evil.example' } });
  assert.equal(bad.headers['access-control-allow-origin'], undefined);
});
