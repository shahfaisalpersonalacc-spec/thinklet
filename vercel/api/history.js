// GET    /api/history?limit=100   newest first
// POST   /api/history {kind, before, after}
// DELETE /api/history?id=…        one entry
// DELETE /api/history?all=1       everything
import { requireAuth } from '../lib/auth.js';
import { getRepo } from '../lib/db.js';
import { HttpError, body, id, route, str } from '../lib/http.js';

export default route({
  GET: async (req) => {
    requireAuth(req);
    const limit = Math.min(Math.max(Number(req.query?.limit) || 100, 1), 500);
    return { history: await getRepo().listHistory(limit) };
  },

  POST: async (req) => {
    requireAuth(req);
    const b = body(req);
    const entry = await getRepo().addHistory({
      kind: str(b.kind, 'Kind', 100, { required: true }),
      before: str(b.before, 'Original text', 50000, { required: true }),
      after: str(b.after, 'Result', 50000, { required: true }),
    });
    return { entry };
  },

  DELETE: async (req) => {
    requireAuth(req);
    if (req.query?.all === '1') {
      await getRepo().clearHistory();
      return { ok: true };
    }
    if (!(await getRepo().deleteHistory(id(req.query?.id)))) {
      throw new HttpError(404, 'Entry not found.');
    }
    return { ok: true };
  },
});
