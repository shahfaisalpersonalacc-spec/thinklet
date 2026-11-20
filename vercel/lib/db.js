// Storage for history and notes. Routes use the repository returned by
// getRepo(); tests swap in the in-memory one (memory-repo.js) via setRepo().

import { neon } from '@neondatabase/serverless';
import { HttpError } from './http.js';

/** Columns a client may change on a note (whitelist for UPDATE). */
export const NOTE_FIELDS = [
  'title',
  'body',
  'color',
  'tags',
  'pinned',
  'archived',
  'checklist',
  'source',
  'source_key',
];

export const TRASH_DAYS = 30;

let repo;

export function getRepo() {
  if (!repo) {
    const url = process.env.DATABASE_URL;
    if (!url) throw new HttpError(500, 'Server has no database (DATABASE_URL).');
    repo = sqlRepo(neon(url));
  }
  return repo;
}

export function setRepo(r) {
  repo = r;
}

const SCHEMA = [
  `create table if not exists history (
     id uuid primary key default gen_random_uuid(),
     kind text not null,
     before text not null,
     after text not null,
     created_at timestamptz not null default now())`,
  `create table if not exists notes (
     id uuid primary key default gen_random_uuid(),
     title text not null default '',
     body text not null default '',
     color text not null default 'none',
     tags text[] not null default '{}',
     pinned boolean not null default false,
     archived boolean not null default false,
     checklist boolean not null default false,
     source text,
     source_key text unique,
     created_at timestamptz not null default now(),
     updated_at timestamptz not null default now(),
     deleted_at timestamptz)`,
  `create index if not exists notes_updated on notes (updated_at desc)`,
];

/** Escape LIKE wildcards so a search for "50%" means the text "50%". */
const likeText = (q) => `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;

function sqlRepo(sql) {
  let ready;
  const q = async (text, params = []) => {
    ready ??= (async () => {
      for (const s of SCHEMA) await sql.query(s);
    })().catch((e) => {
      ready = undefined; // retry on the next request
      throw e;
    });
    await ready;
    return sql.query(text, params);
  };

  return {
    listHistory: (limit) =>
      q('select * from history order by created_at desc limit $1', [limit]),

    addHistory: async ({ kind, before, after }) =>
      (
        await q(
          'insert into history (kind, before, after) values ($1, $2, $3) returning *',
          [kind, before, after],
        )
      )[0],

    deleteHistory: async (id) =>
      (await q('delete from history where id = $1 returning id', [id])).length > 0,

    clearHistory: () => q('delete from history'),

    listNotes: ({ view, tag, q: text, sort }) => {
      const where = {
        trash: 'deleted_at is not null',
        archive: 'deleted_at is null and archived',
        pinned: 'deleted_at is null and pinned and not archived',
        all: 'deleted_at is null and not archived',
      }[view];
      const params = [];
      let cond = where;
      if (tag) {
        params.push(tag);
        cond += ` and $${params.length} = any(tags)`;
      }
      if (text) {
        params.push(likeText(text));
        cond += ` and (title ilike $${params.length} or body ilike $${params.length})`;
      }
      const by = view === 'trash' ? 'deleted_at' : sort === 'created' ? 'created_at' : 'updated_at';
      const pinFirst = view === 'all' ? 'pinned desc, ' : '';
      return q(`select * from notes where ${cond} order by ${pinFirst}${by} desc limit 500`, params);
    },

    findNoteBySourceKey: async (key) =>
      (await q('select * from notes where source_key = $1', [key]))[0] ?? null,

    createNote: async (fields) => {
      const cols = NOTE_FIELDS.filter((c) => fields[c] !== undefined);
      const vals = cols.map((c) => fields[c]);
      const text = cols.length
        ? `insert into notes (${cols.join(', ')}) values (${cols.map((_, i) => `$${i + 1}`).join(', ')}) returning *`
        : 'insert into notes default values returning *';
      return (await q(text, vals))[0];
    },

    updateNote: async (id, patch) => {
      const cols = NOTE_FIELDS.filter((c) => patch[c] !== undefined);
      const sets = cols.map((c, i) => `${c} = $${i + 2}`);
      sets.push('updated_at = now()');
      const rows = await q(
        `update notes set ${sets.join(', ')} where id = $1 returning *`,
        [id, ...cols.map((c) => patch[c])],
      );
      return rows[0] ?? null;
    },

    setTrashed: async (id, trashed) =>
      (
        await q(
          `update notes set deleted_at = ${trashed ? 'now()' : 'null'} where id = $1 returning *`,
          [id],
        )
      )[0] ?? null,

    purgeNote: async (id) =>
      (await q('delete from notes where id = $1 and deleted_at is not null returning id', [id]))
        .length > 0,

    purgeOldTrash: () =>
      q(`delete from notes where deleted_at < now() - interval '${TRASH_DAYS} days'`),
  };
}
