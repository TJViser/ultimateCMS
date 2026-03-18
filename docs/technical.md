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
- **Sessions** (`data/sessions.json`): `session_token → { github_token, username, avatar, site_key, created_at }` — 24-hour TTL, expired sessions rejected automatically
- **OAuth states** (`data/oauth_states.json`): `nonce → { site_key, created_at }` — 10-minute TTL, single-use, cleaned up on expiry

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
2. **GitHub search API rate limits** — 10 requests/minute for unauthenticated, 30 for authenticated. The agent falls back to heuristic file selection when rate-limited.
3. **String#sub for edits** — replaces the first occurrence only. If the same text appears multiple times in a file, the agent's context helps pick the right one, but the substitution might hit the wrong one.
4. **No image/media editing** — text only for now.
5. **No undo** — changes are committed directly. Rollback = revert the PR.
6. **Single-file edits** — if the same text change needs to happen in multiple files (e.g., i18n), the agent handles it, but the current `String#sub` only patches one occurrence per edit object.

---

## Security Architecture

### Overview

UltimateCMS implements defense-in-depth across all layers: middleware, transport, input validation, output encoding, authentication, and rate limiting. The security stack is built on proven Ruby libraries (`rack-protection`, `rack-attack`) and follows OWASP best practices.

### Security Middleware

| Middleware | Purpose |
|-----------|---------|
| `Rack::Protection` | CSRF protection, session hijacking prevention, XSS mitigations |
| `Rack::Protection::ContentSecurityPolicy` | CSP headers restricting script/style/image/connect sources |
| `Rack::Attack` | Rate limiting per IP on all sensitive endpoints |
| `Rack::Cors` | CORS enforcement — per-site `allowed_origins` validation |

### HTTP Security Headers

All responses include the following headers:

| Header | Value | Purpose |
|--------|-------|---------|
| `Content-Security-Policy` | `default-src 'self'; script-src 'self'; ...` | Prevents XSS via inline scripts, restricts resource loading |
| `X-Content-Type-Options` | `nosniff` | Prevents MIME-type sniffing |
| `X-Frame-Options` | `DENY` | Prevents clickjacking via iframes |
| `X-XSS-Protection` | `1; mode=block` | Legacy XSS filter (defense-in-depth) |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | Limits referrer leakage |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` | Disables unnecessary browser APIs |
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | Forces HTTPS (when on HTTPS) |

### XSS Prevention

**Backend (Ruby):**
- All user-provided values interpolated into HTML (OAuth callback page) are escaped via `Sanitize.escape_js()` — prevents breakout from JavaScript string literals
- Error messages returned to the client are generic — no raw exception data is exposed
- Embed script snippets use `Sanitize.escape_html()` for all interpolated values
- `lib/sanitize.rb` provides centralized `escape_html()`, `escape_js()`, and `escape_markdown()` helpers using `ERB::Util.html_escape` and custom JS escaping

**Frontend (JavaScript):**
- All dynamic content in `editor.js` is rendered via DOM API (`createElement`, `textContent`, `append`) — never via `innerHTML` with user data
- `location.pathname` is set via `textContent`, not template interpolation
- Error messages, PR URLs, and usernames are rendered via `textContent` (no HTML interpretation)
- Config modal inputs are populated via `.value` property, not `innerHTML`
- `ucms.js` builds the login/logged-in popup entirely with DOM methods
- Avatar URLs are validated against `avatars.githubusercontent.com` before rendering as `<img src>`
- PR URLs are validated with `isValidUrl()` (must be `http:` or `https:`) before rendering as links

### CSRF Protection

- **Rack::Protection** middleware provides framework-level CSRF defense
- **OAuth state parameter** uses a server-side nonce: `state = "site_key:nonce"`, where the nonce is stored in `SiteStore` and verified on callback
- Used OAuth states are deleted immediately after validation (single-use)
- OAuth states expire after 10 minutes

### Input Validation

All API endpoints validate incoming data before processing:

**`POST /api/sites`:**
- `repo` — must match `owner/repo` format (`/\A[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+\z/`)
- `branch` — max 255 chars, no `..`, no control characters, no special git chars
- `github_token` — max 500 chars
- `allowed_origins` — each must be a valid `http:` or `https:` URL

**`POST /api/edit`:**
- `site_key` — must be a string
- `page.url` — must be a valid URL
- `page.path` — must be a string
- `changes` — must be an array, max 50 items
- Each change: `old_text` and `new_text` must be strings, max 5000 chars each
- Request body limited to 1MB

**`GET /auth/github`:**
- `site` parameter validated against format `/\Ask_[a-f0-9]+\z/`

**Token validation:**
- Bearer tokens must match `/\A[a-f0-9]{64}\z/` (hex, exactly 64 chars)

### CORS & Origin Enforcement

- CORS is configured per endpoint — only `/api/*`, `/ucms.js`, and `/editor.js` allow cross-origin requests
- On `POST /api/edit`, the `Origin` header is validated against the site's `allowed_origins` list
- If a site has no `allowed_origins` configured, same-origin requests are allowed by default

### Rate Limiting

| Endpoint | Limit | Window |
|----------|-------|--------|
| `POST /api/edit` | 10 requests | 60 seconds |
| `POST /api/sites` | 5 requests | 60 seconds |
| `/auth/*` | 10 requests | 300 seconds |

Limits are per IP address via `Rack::Attack`.

### Authentication & Session Management

- Sessions are created on successful GitHub OAuth and stored server-side
- **Session TTL: 24 hours** — expired sessions are rejected and cleaned up on access
- Session tokens are 64-character hex strings generated via `SecureRandom.hex(32)`
- The contributor's GitHub access token is stored server-side only — never sent back to the client
- Client-side only stores the opaque session token (in `localStorage`)

### Prompt Injection Mitigation

User-provided text interpolated into the Claude prompt is sanitized via `Sanitize.sanitize_for_prompt()`:
- Truncated to a max length (500 chars for text, 200 for paths, 20 for tag names)
- Control characters stripped (except newlines/tabs)
- Applied to: `old_text`, `new_text`, `tag`, `classes`, `dom_path`, `parent_tag`, `parent_classes`, `sibling_texts`, `section` fields, `href`, page `url`, `path`, `title`

### Regex Injection Prevention

`String#sub` in `edit_agent.rb` uses `Regexp.escape()` on the `old` string returned by Claude, ensuring it is treated as a literal string match — not as a regex pattern.

### Path Traversal Prevention

Edit objects returned by Claude are validated: file paths containing `..` are rejected.

### Secure postMessage Communication

- The OAuth callback page sends the auth token via `postMessage` to a **specific origin** (the site's first `allowed_origin`, or the backend's own URL) — never `'*'`
- `ucms.js` validates `e.origin` against the expected API origin before accepting postMessage data

### Markdown Injection Prevention

User-provided text in PR bodies is escaped via `Sanitize.escape_markdown()`, preventing injection of malicious markdown (links, images, HTML) into GitHub PR descriptions. URLs used in markdown links are validated before inclusion.

### Error Handling

- API errors return generic messages to the client (`"An error occurred while processing your edit."`)
- Detailed errors are logged server-side only (`logger.error`)
- No stack traces, file paths, or internal state are exposed to the client

### Security Dependencies

| Gem | Version | Purpose |
|-----|---------|---------|
| `rack-protection` | ~> 3.0 | CSRF, session fixation, XSS header protections |
| `rack-attack` | ~> 6.0 | Rate limiting and throttling |
| `rack-cors` | ~> 2.0 | CORS enforcement |

### `lib/sanitize.rb` — Security Utility Module

| Method | Purpose |
|--------|---------|
| `escape_html(str)` | HTML entity encoding via `ERB::Util.html_escape` |
| `escape_js(str)` | JS string literal escaping (backslash, quotes, angle brackets, `/`) |
| `valid_string?(str, max_length:, pattern:)` | Length + regex validation |
| `valid_url?(url)` | Validates `http:`/`https:` scheme |
| `valid_repo?(repo)` | Validates `owner/repo` format |
| `valid_branch?(branch)` | Validates git branch name constraints |
| `sanitize_for_prompt(str, max_length:)` | Truncates + strips control chars for safe AI prompt inclusion |
| `escape_markdown(str)` | Escapes markdown special characters |

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
| Security | Rack::Protection, Rack::Attack, CSP, custom sanitization |
