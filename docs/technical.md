# UltimateCMS — Technical Documentation

## Overview

UltimateCMS is a universal visual CMS that lets contributors edit text on any live website. An AI agent maps the visual changes back to the source code and creates a GitHub pull request — regardless of the framework used (HTML, React, 11ty, Hugo, Jekyll, Next.js, etc.).

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  CLIENT (any website)                                            │
│                                                                  │
│  <script src="ultimatecms.com/ucms.js" data-site="sk_xxx">      │
│       │                                                          │
│       ▼                                                          │
│  ucms.js  ─── shows FAB button ─── GitHub OAuth popup            │
│       │                                                          │
│       ▼  (after auth)                                            │
│  editor.js  ─── contenteditable on text elements                 │
│       │         captures rich context per change                 │
│       │                                                          │
│       ▼  POST /api/edit  { site_key, page, changes }             │
└──────┬───────────────────────────────────────────────────────────┘
       │  Authorization: Bearer <session_token>
       ▼
┌──────────────────────────────────────────────────────────────────┐
│  BACKEND (Sinatra API)                                           │
│                                                                  │
│  app.rb                                                          │
│    ├── POST /api/sites        → register a site, get sk_xxx      │
│    ├── GET  /api/sites        → list sites for authenticated user│
│    ├── GET  /auth/github      → GitHub OAuth redirect            │
│    ├── GET  /auth/github/cb   → OAuth callback, create session   │
│    └── POST /api/edit         → main edit endpoint               │
│              │                                                   │
│              ▼                                                   │
│  lib/site_store.rb   → resolve sk_xxx to { repo, branch, token }│
│              │                                                   │
│              ▼                                                   │
│  lib/github_client.rb                                            │
│    ├── search_code(query)     → GitHub code search API           │
│    ├── get_tree()             → list all files in repo           │
│    ├── get_file(path)         → read file content + SHA          │
│    ├── create_branch(name)    → create feature branch            │
│    ├── update_file(...)       → commit file changes              │
│    └── create_pull_request()  → open PR                          │
│              │                                                   │
│              ▼                                                   │
│  lib/edit_agent.rb                                               │
│    ├── find_candidates()      → grep repo for changed text       │
│    ├── ask_agent()            → Claude API: find exact edit loc  │
│    └── process()              → orchestrate full flow → PR URL   │
└──────────────────────────────────────────────────────────────────┘
```

---

## File-by-file Reference

### `public/ucms.js` — Embed Script

**Purpose:** Lightweight script the site owner adds to their HTML. Shows a floating edit button for contributors.

**Behavior:**
1. Reads `data-site` attribute from its own `<script>` tag
2. Injects a FAB (floating action button) at bottom-right
3. On click: if not authenticated → show GitHub OAuth login popup; if authenticated → load `editor.js`
4. Authentication uses a popup window flow: `GET /auth/github` → GitHub OAuth → callback → `postMessage` back to opener
5. Session stored in `localStorage` as `ucms_session` → `{ token, username, avatar }`

**Key globals set before loading editor.js:**
```javascript
window.__ucmsConfig = {
  api_url: 'https://ultimatecms.com',
  site_key: 'sk_a8f3e2b1',
  session_token: '64-char-hex-string'
}
```

---

### `public/editor.js` — Visual Editor

**Purpose:** Full editing UI injected on top of the live website.

**Behavior:**
1. Injects a fixed toolbar at the top of the page (48px)
2. Scans the DOM for editable elements (h1-h6, p, a, span, li, button, etc.)
3. Marks each with `data-ucms-id` and stores original `innerHTML`
4. On hover: dashed blue outline
5. On click: element becomes `contenteditable`, solid blue outline
6. On blur: compares innerHTML to original, tracks as change if different
7. Submit: POSTs all changes with rich context to `/api/edit`

**Rich context captured per change:**
```javascript
{
  old_html: '<original innerHTML>',
  new_html: '<modified innerHTML>',
  old_text: 'original visible text',
  new_text: 'modified visible text',
  context: {
    tag: 'h2',
    id: null,
    classes: ['section-title'],
    dom_path: 'body > section#services > div.container > div.section-header > h2',
    parent_tag: 'div',
    parent_classes: ['section-header'],
    sibling_texts: ['Ce que nous faisons', 'Un accompagnement complet...'],
    section: {
      tag: 'section',
      id: 'services',
      class: 'section services',
      heading: 'Nos Services'
    },
    href: null  // only for <a> tags
  }
}
```

**Why this context matters for the AI agent:**
- `dom_path` + `classes` → helps disambiguate identical text in different sections
- `section.heading` → the agent can search for the section heading to locate the right block
- `sibling_texts` → helps confirm the right neighborhood in the source
- `tag` → tells the agent what kind of element to look for (heading vs paragraph vs link)

---

### `app.rb` — Sinatra API

**Endpoints:**

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/` | - | Serves landing page |
| POST | `/api/sites` | - | Register a new site → returns `sk_xxx` |
| GET | `/api/sites` | Bearer | List sites for authenticated user |
| GET | `/auth/github` | - | Redirect to GitHub OAuth |
| GET | `/auth/github/callback` | - | OAuth callback, creates session |
| POST | `/api/edit` | Bearer | Main edit endpoint |

**Edit endpoint flow:**
1. Authenticate via `Authorization: Bearer <session_token>`
2. Resolve `site_key` → `{ repo, branch }` via SiteStore
3. Create `GithubClient` using the **contributor's** GitHub token (from OAuth)
4. Create `EditAgent` with GitHub client + Anthropic API key
5. Call `agent.process(page, changes)` → returns `{ pr_url }`

**Important:** The PR is created with the contributor's token, so it appears as authored by them. The Anthropic API key is server-side only.

---

### `lib/github_client.rb` — GitHub API Wrapper

Built on Faraday. All methods raise on error.

| Method | GitHub API | Purpose |
|--------|-----------|---------|
| `search_code(query)` | `GET /search/code` | Find files containing specific text |
| `get_tree` | `GET /git/trees/:sha?recursive=1` | List all files in repo |
| `get_file(path, ref:)` | `GET /contents/:path` | Read file content + SHA |
| `get_branch_sha` | `GET /git/ref/heads/:branch` | Get HEAD SHA of branch |
| `create_branch(name)` | `POST /git/refs` | Create branch from current HEAD |
| `update_file(...)` | `PUT /contents/:path` | Commit a file change |
| `create_pull_request(...)` | `POST /pulls` | Open a pull request |

---

### `lib/edit_agent.rb` — AI-Powered Source Mapper

This is the core innovation. Uses Claude to map rendered text → source code location.

**`process(page, changes)` flow:**
1. **`find_candidates(changes)`** — for each change, search the repo for the old text using GitHub code search API + heuristic file selection (prioritizes `_data/`, `content/`, `src/`, `locales/`, template files)
2. **Read candidate files** — fetch content of up to 20 candidate files via GitHub API
3. **`ask_agent(page, changes, file_contents)`** — build a detailed prompt with all context (page URL, each change with DOM context, all candidate file contents) and send to Claude
4. **Parse Claude's response** — expects a JSON array of `{ file, old, new }` edits
5. **Create branch** — `ucms/edit-<random>`
6. **Apply edits** — for each edit, `String#sub` the old text with new in the source file, commit
7. **Create PR** — with a summary of all changes and files modified

**Claude prompt structure:**
- System context: repo info, page URL
- For each change: old text, new text, tag, classes, DOM path, section info, siblings
- All candidate source files (truncated to 3000 chars each)
- Instructions: find the EXACT string in source files, consider templates/data files/i18n, use context to disambiguate
- Response format: JSON array only

**Model used:** `claude-sonnet-4-20250514` (fast, capable enough for code search)

---

### `lib/site_store.rb` — Data Persistence

**Current:** JSON files in `/data/` directory (prototype).

**Stores:**
- **Sites** (`data/sites.json`): `sk_xxx → { repo, branch, github_token, allowed_origins, created_at }`
- **Sessions** (`data/sessions.json`): `session_token → { github_token, username, avatar, created_at }`

**To replace in production:** PostgreSQL + Redis for sessions.

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes | Claude API key for the edit agent |
| `GITHUB_CLIENT_ID` | Yes | GitHub OAuth App client ID |
| `GITHUB_CLIENT_SECRET` | Yes | GitHub OAuth App client secret |

---

## Local Development Setup

```bash
# 1. Ruby dependencies
bundle install

# 2. GitHub OAuth App
#    Go to https://github.com/settings/developers → New OAuth App
#    Homepage URL: http://localhost:9292
#    Callback URL: http://localhost:9292/auth/github/callback

# 3. Environment
cp .env.example .env
# Fill in ANTHROPIC_API_KEY, GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET

# 4. Run
bundle exec puma
# → http://localhost:9292
```

---

## Known Limitations (Prototype)

1. **No database** — sites and sessions are stored in JSON files. Not safe for concurrent writes.
2. **No session expiry** — sessions never expire. Need TTL + refresh tokens.
3. **No origin validation** — `allowed_origins` is stored but not enforced yet.
4. **GitHub search API rate limits** — 10 requests/minute for unauthenticated, 30 for authenticated. The agent falls back to heuristic file selection when rate-limited.
5. **String#sub for edits** — replaces the first occurrence only. If the same text appears multiple times in a file, the agent's context helps pick the right one, but the substitution might hit the wrong one.
6. **No image/media editing** — text only for now.
7. **No undo** — changes are committed directly. Rollback = revert the PR.
8. **Single-file edits** — if the same text change needs to happen in multiple files (e.g., i18n), the agent handles it, but the current `String#sub` only patches one occurrence per edit object.

---

## Security Considerations

1. **Site keys are opaque** — no repo info exposed to the client.
2. **Contributor auth via GitHub OAuth** — no tokens stored client-side except session tokens.
3. **PRs authored by contributors** — uses their own GitHub token, so permissions are enforced by GitHub.
4. **Anthropic API key is server-side only** — never sent to the client.
5. **CORS is open (`*`)** — restrict in production to `allowed_origins` per site.
6. **GitHub OAuth state parameter** — includes site key but no CSRF protection yet. Add a random nonce verified on callback.

---

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Backend | Ruby / Sinatra |
| AI Agent | Claude API (Anthropic) |
| Git integration | GitHub REST API v3 |
| Auth | GitHub OAuth 2.0 |
| Storage (prototype) | JSON files |
| Frontend | Vanilla JS (injected) |
