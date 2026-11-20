// Local backend for development: the same /api routes as on Vercel, with
// data kept in memory (gone when it stops) instead of the Neon database.
//
//   cd vercel
//   node --env-file=../.env dev-server.js        (port 3001)
//
// Needs APP_USERNAME, APP_PASSWORD and ANTHROPIC_API_KEY in .env.
// AUTH_SECRET is made up for the session if .env has none.
import { randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { setRepo } from './lib/db.js';
import { memoryRepo } from './lib/memory-repo.js';

const PORT = Number(process.env.PORT) || 3001;
process.env.AUTH_SECRET ||= randomBytes(32).toString('hex');
setRepo(memoryRepo());

const routes = {
  login: (await import('./api/login.js')).default,
  claude: (await import('./api/claude.js')).default,
  history: (await import('./api/history.js')).default,
  notes: (await import('./api/notes.js')).default,
};

createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const handler = routes[url.pathname.replace(/^\/api\//, '')];
  // Vercel-style helpers on top of Node's req/res.
  req.query = Object.fromEntries(url.searchParams);
  let raw = '';
  for await (const chunk of req) raw += chunk;
  req.body = raw;
  res.status = (c) => ((res.statusCode = c), res);
  res.json = (b) => {
    res.setHeader('content-type', 'application/json; charset=utf-8');
    res.end(JSON.stringify(b));
    return res;
  };
  res.send = (b) => (res.end(b), res);
  if (!handler) return res.status(404).json({ error: { message: 'Not found.' } });
  await handler(req, res);
}).listen(PORT, '0.0.0.0', () => {
  const has = (k) => (process.env[k] ? 'set' : 'MISSING');
  console.log(`Thinklet local backend on http://0.0.0.0:${PORT}/api`);
  console.log(
    `  APP_USERNAME ${has('APP_USERNAME')} · APP_PASSWORD ${has('APP_PASSWORD')}` +
      ` · ANTHROPIC_API_KEY ${has('ANTHROPIC_API_KEY')} · data: in memory`,
  );
});
