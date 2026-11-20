// In-memory repository with the same behaviour as the SQL one in db.js.
// Used by the backend tests (no database needed).

import { randomUUID } from 'node:crypto';
import { NOTE_FIELDS, TRASH_DAYS } from './db.js';

export function memoryRepo({ now = () => new Date() } = {}) {
  const history = [];
  const notes = [];
  const copy = (n) => n && { ...n, tags: [...n.tags] };

  return {
    history,
    notes,

    listHistory: async (limit) =>
      [...history].sort((a, b) => b.created_at - a.created_at).slice(0, limit),

    addHistory: async ({ kind, before, after }) => {
      const h = { id: randomUUID(), kind, before, after, created_at: now() };
      history.push(h);
      return h;
    },

    deleteHistory: async (id) => {
      const i = history.findIndex((h) => h.id === id);
      if (i >= 0) history.splice(i, 1);
      return i >= 0;
    },

    clearHistory: async () => {
      history.length = 0;
    },

    listNotes: async ({ view, tag, q, sort }) => {
      const match = {
        trash: (n) => n.deleted_at,
        archive: (n) => !n.deleted_at && n.archived,
        pinned: (n) => !n.deleted_at && n.pinned && !n.archived,
        all: (n) => !n.deleted_at && !n.archived,
      }[view];
      const text = q?.toLowerCase();
      const by = view === 'trash' ? 'deleted_at' : sort === 'created' ? 'created_at' : 'updated_at';
      return notes
        .filter(match)
        .filter((n) => !tag || n.tags.includes(tag))
        .filter(
          (n) =>
            !text ||
            n.title.toLowerCase().includes(text) ||
            n.body.toLowerCase().includes(text),
        )
        .sort((a, b) => (view === 'all' ? b.pinned - a.pinned : 0) || b[by] - a[by])
        .map(copy);
    },

    findNoteBySourceKey: async (key) => copy(notes.find((n) => n.source_key === key)) ?? null,

    createNote: async (fields) => {
      const t = now();
      const n = {
        id: randomUUID(),
        title: '',
        body: '',
        color: 'none',
        tags: [],
        pinned: false,
        archived: false,
        checklist: false,
        source: null,
        source_key: null,
        created_at: t,
        updated_at: t,
        deleted_at: null,
      };
      for (const c of NOTE_FIELDS) if (fields[c] !== undefined) n[c] = fields[c];
      notes.push(n);
      return copy(n);
    },

    updateNote: async (id, patch) => {
      const n = notes.find((x) => x.id === id);
      if (!n) return null;
      for (const c of NOTE_FIELDS) if (patch[c] !== undefined) n[c] = patch[c];
      n.updated_at = now();
      return copy(n);
    },

    setTrashed: async (id, trashed) => {
      const n = notes.find((x) => x.id === id);
      if (!n) return null;
      n.deleted_at = trashed ? now() : null;
      return copy(n);
    },

    purgeNote: async (id) => {
      const i = notes.findIndex((x) => x.id === id && x.deleted_at);
      if (i >= 0) notes.splice(i, 1);
      return i >= 0;
    },

    purgeOldTrash: async () => {
      const cutoff = now() - TRASH_DAYS * 24 * 60 * 60 * 1000;
      for (let i = notes.length - 1; i >= 0; i--) {
        if (notes[i].deleted_at && notes[i].deleted_at < cutoff) notes.splice(i, 1);
      }
    },
  };
}
