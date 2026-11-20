// GET    /api/notes?view=all|pinned|archive|trash&tag=…&q=…&sort=edited|created
// POST   /api/notes {fields}              create (same source_key -> existing note)
// POST   /api/notes?action=trash&id=…     move to trash
// POST   /api/notes?action=restore&id=…   back out of trash
// PATCH  /api/notes?id=… {fields}         change some fields
// DELETE /api/notes?id=…                  delete forever (only from trash)
import { requireAuth } from '../lib/auth.js';
import { getRepo } from '../lib/db.js';
import { HttpError, body, bool, id, route, str } from '../lib/http.js';

export const COLORS = ['none', 'lime', 'purple', 'blue', 'orange', 'pink', 'teal'];
const VIEWS = ['all', 'pinned', 'archive', 'trash'];

/** Client fields -> validated note fields (undefined = not given). */
function fields(b) {
  const f = {
    title: str(b.title, 'Title', 200),
    body: str(b.body, 'Note', 50000),
    color: str(b.color, 'Colour', 20),
    pinned: bool(b.pinned, 'Pinned'),
    archived: bool(b.archived, 'Archived'),
    checklist: bool(b.checklist, 'Checklist'),
    source: str(b.source, 'Source', 20),
    source_key: str(b.source_key, 'Source key', 100),
  };
  if (f.color !== undefined && !COLORS.includes(f.color)) {
    throw new HttpError(400, 'Unknown colour.');
  }
  if (f.source !== undefined && !['correct', 'translate'].includes(f.source)) {
    throw new HttpError(400, 'Unknown source.');
  }
  if (b.tags !== undefined) {
    if (!Array.isArray(b.tags) || b.tags.length > 20) {
      throw new HttpError(400, 'Tags must be a list of up to 20.');
    }
    const tags = b.tags.map((t) => str(t, 'Tag', 30)?.trim().toLowerCase()).filter(Boolean);
    f.tags = [...new Set(tags)];
  }
  return f;
}

function found(note) {
  if (!note) throw new HttpError(404, 'Note not found.');
  return { note };
}

export default route({
  GET: async (req) => {
    requireAuth(req);
    const repo = getRepo();
    const view = req.query?.view ?? 'all';
    if (!VIEWS.includes(view)) throw new HttpError(400, 'Unknown view.');
    await repo.purgeOldTrash();
    const notes = await repo.listNotes({
      view,
      tag: str(req.query?.tag, 'Tag', 30) || undefined,
      q: str(req.query?.q, 'Search', 200)?.trim() || undefined,
      sort: req.query?.sort === 'created' ? 'created' : 'edited',
    });
    return { notes };
  },

  POST: async (req) => {
    requireAuth(req);
    const repo = getRepo();
    const action = req.query?.action;
    if (action === 'trash' || action === 'restore') {
      return found(await repo.setTrashed(id(req.query?.id), action === 'trash'));
    }
    if (action) throw new HttpError(400, 'Unknown action.');
    const f = fields(body(req));
    if (f.source_key) {
      const existing = await repo.findNoteBySourceKey(f.source_key);
      if (existing) return { note: existing, existing: true };
    }
    return { note: await repo.createNote(f) };
  },

  PATCH: async (req) => {
    requireAuth(req);
    return found(await getRepo().updateNote(id(req.query?.id), fields(body(req))));
  },

  DELETE: async (req) => {
    requireAuth(req);
    if (!(await getRepo().purgeNote(id(req.query?.id)))) {
      throw new HttpError(404, 'Only notes in the trash can be deleted forever.');
    }
    return { ok: true };
  },
});
