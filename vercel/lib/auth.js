// One hard-coded account (APP_USERNAME / APP_PASSWORD) and signed tokens.
// A token is base64url(JSON {sub, exp}) + "." + base64url(HMAC-SHA256),
// keyed with AUTH_SECRET. No database needed to check one.

import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { HttpError } from './http.js';

export const TOKEN_DAYS = 30;

function secret() {
  const s = process.env.AUTH_SECRET;
  if (!s || s.length < 16) {
    throw new HttpError(500, 'Server login is not configured (AUTH_SECRET).');
  }
  return s;
}

const b64 = (buf) => Buffer.from(buf).toString('base64url');
const sign = (data) => createHmac('sha256', secret()).update(data).digest();

/** Equal-time string compare, so timing can't reveal how much matched.
 *  Hashing first makes both sides the same length. */
export function sameText(a, b) {
  const h = (s) => createHash('sha256').update(String(s)).digest();
  return timingSafeEqual(h(a), h(b));
}

export function signToken(sub, now = Date.now()) {
  const exp = now + TOKEN_DAYS * 24 * 60 * 60 * 1000;
  const payload = b64(JSON.stringify({ sub, exp }));
  return { token: `${payload}.${b64(sign(payload))}`, expiresAt: exp };
}

/** The token's user, or null if it's malformed, tampered or expired. */
export function verifyToken(token, now = Date.now()) {
  if (typeof token !== 'string') return null;
  const [payload, mac, extra] = token.split('.');
  if (!payload || !mac || extra !== undefined) return null;
  const expected = sign(payload);
  const given = Buffer.from(mac, 'base64url');
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) {
    return null;
  }
  try {
    const { sub, exp } = JSON.parse(Buffer.from(payload, 'base64url').toString());
    return typeof sub === 'string' && typeof exp === 'number' && exp > now ? sub : null;
  } catch {
    return null;
  }
}

/** Throws 401 unless the request carries a valid "Bearer <token>". */
export function requireAuth(req) {
  const h = req.headers?.authorization ?? '';
  const user = h.startsWith('Bearer ') ? verifyToken(h.slice(7)) : null;
  if (!user) throw new HttpError(401, 'Please sign in again.');
  return user;
}

/** The configured account, or a 500 if it isn't set up on the server. */
export function account() {
  const username = process.env.APP_USERNAME;
  const password = process.env.APP_PASSWORD;
  if (!username || !password) {
    throw new HttpError(500, 'Server login is not configured (APP_USERNAME / APP_PASSWORD).');
  }
  return { username, password };
}
