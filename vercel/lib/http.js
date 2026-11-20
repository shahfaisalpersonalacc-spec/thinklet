// Small helpers shared by the API routes: CORS, method routing, errors.

/** A client error with a status code and a message safe to show users. */
export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// The hosted web app is same-origin and needs no CORS. These cover local
// development: `flutter run` on localhost or on the LAN (phone testing).
const DEV_ORIGIN =
  /^http:\/\/(localhost|127\.0\.0\.1|192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3})(:\d+)?$/;

function cors(req, res) {
  const origin = req.headers?.origin;
  if (origin && DEV_ORIGIN.test(origin)) {
    res.setHeader('access-control-allow-origin', origin);
    res.setHeader('vary', 'origin');
    res.setHeader('access-control-allow-headers', 'content-type, authorization');
    res.setHeader(
      'access-control-allow-methods',
      'GET, POST, PATCH, DELETE, OPTIONS',
    );
  }
}

/**
 * Builds a route handler from `{GET: fn, POST: fn, ...}`. Each fn gets
 * (req, res) and returns the JSON body to send (status 200), or sends the
 * response itself. HttpError becomes `{error: {message}}` with its status.
 */
export function route(methods) {
  return async function handler(req, res) {
    cors(req, res);
    if (req.method === 'OPTIONS') return res.status(204).end();
    const fn = methods[req.method];
    if (!fn) {
      return res.status(405).json({ error: { message: 'Method not allowed.' } });
    }
    try {
      const out = await fn(req, res);
      if (out !== undefined && !res.headersSent) res.status(200).json(out);
    } catch (e) {
      if (e instanceof HttpError) {
        return res.status(e.status).json({ error: { message: e.message } });
      }
      console.error(e);
      res.status(500).json({ error: { message: 'Server error. Try again.' } });
    }
  };
}

/** The parsed JSON body (Vercel parses it), or {} for none. */
export function body(req) {
  const b = req.body;
  if (b == null || b === '') return {};
  if (typeof b === 'string') {
    try {
      return JSON.parse(b);
    } catch {
      throw new HttpError(400, 'Body must be JSON.');
    }
  }
  return b;
}

/** Validated string: trimmed to `max` is an error, not silent truncation. */
export function str(v, name, max, { required = false } = {}) {
  if (v === undefined || v === null) {
    if (required) throw new HttpError(400, `${name} is required.`);
    return undefined;
  }
  if (typeof v !== 'string') throw new HttpError(400, `${name} must be text.`);
  if (v.length > max) {
    throw new HttpError(400, `${name} is too long (max ${max} characters).`);
  }
  return v;
}

export function bool(v, name) {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'boolean') throw new HttpError(400, `${name} must be true or false.`);
  return v;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function id(v) {
  if (typeof v !== 'string' || !UUID.test(v)) throw new HttpError(400, 'Bad id.');
  return v;
}
