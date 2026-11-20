# Thinklet: backend, login, saved history and Notes — design

Date: 2026-11-20 · Status: approved; implemented

## Goal

Give Thinklet a backend so that, behind a single hard-coded login, a user's
history and notes are stored server-side and shared across the web app, phone
and Windows app; add a full Notes tab; and add a "Save to notes" button on
Correct/Translate results.

## Decisions (from the brainstorm)

| Question | Decision |
|---|---|
| Where the backend runs | Vercel, extending the existing `thinklet/vercel` functions |
| Database | Neon Postgres (free tier, added via Vercel Marketplace → `DATABASE_URL`) |
| Login | One user; `APP_USERNAME` / `APP_PASSWORD` env vars; protects the **whole app** |
| Notes features | Core set + tags + checklists + archive & trash |
| Offline | Out of scope: app shows "You're offline"; no local sync |

## 1. Architecture

```
Flutter app (web / phone / Windows)
   │  HTTPS, Authorization: Bearer <token>
   ▼
Vercel functions (thinklet/vercel/api)
   ├─ POST /api/login            → token (no auth needed)
   ├─ POST /api/claude           → Claude proxy (now requires token)
   ├─ /api/history               → list / add / delete / clear
   └─ /api/notes                 → list / create / update / trash / restore / purge
   │
   ▼
Neon Postgres (DATABASE_URL)
```

- **All clients use the backend.** The Windows build stops embedding
  `ANTHROPIC_API_KEY`; every build uses `--dart-define=API_BASE=<url>`
  (`/api` relative for the hosted web build, the full Vercel URL for Windows
  and local web dev). The old direct-to-Anthropic mode stays only for tests.
- **CORS**: functions allow the app's own origin plus `http://localhost:*` for
  local web development. Native (Windows) requests need no CORS.

### Environment variables

| Name | Where | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | Vercel (exists) | Claude calls |
| `DATABASE_URL` | Vercel (set by Neon integration) | Postgres |
| `APP_USERNAME`, `APP_PASSWORD` | `.env` + Vercel | The one login |
| `AUTH_SECRET` | `.env` + Vercel | HMAC key for tokens (≥32 random chars) |

`.env.example` gains the four names (no values). The user pastes real values
into Vercel themselves; Claude never reads `.env`.

## 2. Backend

Node (ESM) functions in `thinklet/vercel/api`, shared code in
`thinklet/vercel/lib`:

- `lib/auth.js` — `signToken()`, `verifyToken()` (HMAC-SHA256, payload
  `{sub, exp}`, 30-day expiry), `requireAuth(req, res)` helper returning the
  user or sending 401. Constant-time comparison for password and signature.
- `lib/db.js` — Neon serverless driver (`@neondatabase/serverless`);
  `ensureSchema()` creates tables if missing (idempotent, runs on cold start).
- `lib/http.js` — JSON body parsing, CORS headers, method routing, error → JSON.

### Login

`POST /api/login {username, password}` → `200 {token, expiresAt}` or `401`.
Wrong attempts sleep 800 ms before replying (slows guessing). No user table:
the env vars are the account.

### Data model

```sql
history (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null,        -- "Corrected", tone name, language, "Definition"...
  before      text not null,
  after       text not null,
  created_at  timestamptz not null default now()
)

notes (
  id          uuid primary key default gen_random_uuid(),
  title       text not null default '',
  body        text not null default '',  -- checklist lines stored as "[ ] item" / "[x] item"
  color       text not null default 'none', -- none|lime|purple|blue|orange|pink|teal
  tags        text[] not null default '{}',
  pinned      boolean not null default false,
  archived    boolean not null default false,
  checklist   boolean not null default false,
  source      text,                    -- 'correct' | 'translate' | null
  source_key  text unique,             -- dedupe for "Save to notes"
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz              -- set = in trash
)
```

Single user, so no `user_id` column.

### Routes

- `GET /api/history?limit=100` (newest first) · `POST /api/history {kind,before,after}` ·
  `DELETE /api/history?id=…` · `DELETE /api/history?all=1`
- `GET /api/notes?view=all|pinned|archive|trash&tag=…&q=…&sort=edited|created`
  - `all` = not archived, not trashed (pinned first); `q` matches title/body
    (case-insensitive `ILIKE`).
  - Every list call first purges notes trashed more than 30 days ago.
- `POST /api/notes {…fields}` → created note. With `source_key` already
  present → returns the existing note (`200`, no duplicate).
- `PATCH /api/notes?id=…` partial update; bumps `updated_at`.
- `POST /api/notes?action=trash&id=…` (sets `deleted_at`),
  `POST /api/notes?action=restore&id=…`, `DELETE /api/notes?id=…` (delete
  forever; only allowed when trashed). One file per resource keeps Vercel
  routing simple.
- Validation: text fields capped (title 200, body 50 000 chars, ≤ 20 tags of
  ≤ 30 chars); bad input → `400 {error:{message}}`.

All routes except `/api/login` call `requireAuth`.

## 3. App (Flutter)

New files keep `home_page.dart` from growing further:

- `lib/api.dart` — `ApiClient` (base URL, token, typed calls, maps 401 →
  `AuthExpired`, network failure → `Offline`).
- `lib/session.dart` — stores the token (`shared_preferences`), exposes
  signed-in state.
- `lib/login_page.dart` — username, password, Sign in, error text.
- `lib/notes/notes_page.dart`, `lib/notes/note_editor.dart`,
  `lib/notes/note.dart` (model + checklist line parsing).
- `ClaudeService` sends via `ApiClient` (token attached).

### Flow

App start → token present & not expired? → main shell : login page.
Any `AuthExpired` → back to login (typed text is kept in memory).

### Main shell

- **Phone:** bottom tab bar *Write | Notes*, pinned under the action buttons
  on Write.
- **Wide / Windows:** *Write | Notes* switch in the header next to the logo.
- Header menu adds **Sign out**.
- **History** button returns (`_historyEnabled = true`), now backed by
  `/api/history`; local list becomes a cache of the server list.

### Notes tab

- List: search box, filter chips (All · Pinned · each tag · Archive · Trash),
  sort menu (Last edited / Created), cards (colour strip, pin, title, first
  lines, tags, "edited 5 min ago"), **+ New note**.
- Editor: full screen on phone, side panel on wide. Title + body, autosave
  1 s after typing stops ("Saving…" → "Saved"; failure → "Couldn't save,
  retrying…" with backoff, text kept). Toolbar: pin, colour (6 + none), tags
  (add/remove chips), checklist toggle (lines become tick-boxes; ticking
  saves), copy, archive/unarchive, delete, word count.
- Delete → trash with a 5 s **Undo** snackbar. Trash view: **Restore**,
  **Delete forever** (with confirm).

### Save to notes

Small bookmark button beside Copy on the Correction and Translation cards.
Creates a note: title "Correction" / "<Language> translation" / "Definition:
<word>", body = result, blank line, "Original: <text>", tag
`correct`|`translate`, `source_key` = hash of kind + original + result. Button
shows "Saved ✓"; repeat taps return the same note (no duplicate).

## 4. Errors & security

- 401 anywhere → login screen; network error → inline "You're offline" with
  Retry; 5xx → message + Retry.
- Password checked only server-side; app stores only the token.
- Token in `shared_preferences` (web: localStorage). Acceptable for a single
  hard-coded user; documented as such.
- `/api/claude` keeps its existing request validation and now also needs auth.

## 5. Testing

- **Backend:** Node's built-in test runner (`node --test`) against
  `lib/auth.js` (sign/verify/expiry/tamper) and route handlers with an
  in-memory fake of the db layer (login ok/bad, history CRUD, notes
  filters, dedupe by `source_key`, purge after 30 days, auth required).
- **App:** widget tests with a fake `ApiClient`: login success/failure, tab
  switching, create/edit/autosave a note, checklist tick, trash + Undo,
  restore, Save-to-notes no duplicate, 401 → login. Existing 9 tests updated
  to sign in through the fake first.
- **Live check** after deploy: real login, save a note, see it from a second
  client.

## 6. One-time setup by the user

1. Vercel → thinklet → Storage → Create → **Neon** (connects `DATABASE_URL`).
2. Add `APP_USERNAME`, `APP_PASSWORD`, `AUTH_SECRET` to `.env` and to Vercel
   (`npx vercel@latest env add …` or dashboard).
3. Push (Vercel builds and deploys).

## Out of scope

Multiple users / sign-up, password reset, offline editing and sync, rich text
/ markdown rendering, note sharing, attachments.
