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

### `public/dashboard.html` + `public/dashboard.js` — Owner Dashboard

**Purpose:** Site management UI for site owners. Accessible at `/dashboard`.

**Behavior:**
1. If not authenticated → shows GitHub sign-in screen
2. OAuth flow via `GET /auth/github/dashboard` → GitHub → callback → redirect to `/dashboard#token=xxx`
3. Dashboard picks up the token from the URL fragment, fetches user profile + sites via API
4. Session stored in `localStorage` as `ucms_dashboard_session`
5. Shows site cards with: repo, branch, site key, embed snippet (copy button), allowed origins (add/remove), delete
6. Empty state shows a 3-step onboarding guide + "Add your first site" button
7. "Add a site" modal: repo, branch, allowed origins → creates site via API

---

### `app.rb` — Sinatra API

**Endpoints:**

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/` | - | Serves landing page |
| GET | `/dashboard` | - | Serves dashboard SPA |
| GET | `/auth/github/dashboard` | - | GitHub OAuth for site owners (redirect flow) |
| GET | `/auth/github/dashboard/callback` | - | Dashboard OAuth callback → redirect with token |
| GET | `/auth/github` | - | GitHub OAuth for contributors (popup flow) |
| GET | `/auth/github/callback` | - | Contributor OAuth callback → postMessage |
| GET | `/api/owner/me` | Bearer | Get authenticated owner's profile |
| GET | `/api/owner/sites` | Bearer | List sites for authenticated owner |
| POST | `/api/owner/sites` | Bearer | Create a new site |
| PATCH | `/api/owner/sites/:key` | Bearer | Update site settings (branch, origins) |
| DELETE | `/api/owner/sites/:key` | Bearer | Delete a site |
| POST | `/api/sites` | - | Legacy: register a site via API (no auth) |
| GET | `/api/sites` | Bearer | Legacy: list sites by token |
| POST | `/api/edit` | Bearer | Main edit endpoint |

**Two OAuth flows:**
- **Dashboard flow** (site owners): redirect-based. `GET /auth/github/dashboard` → GitHub → callback → redirect to `/dashboard#token=xxx`. Session stored in `localStorage`.
- **Contributor flow** (editors): popup-based. `GET /auth/github?site=sk_xxx` → GitHub → callback → `postMessage` to opener window. Used by `ucms.js`.

**Dashboard API authorization:**
- All `/api/owner/*` endpoints require `Authorization: Bearer <session_token>`
- Site mutations (PATCH, DELETE) verify the authenticated user is the site's owner
- Sites are limited to 20 per owner (prototype)

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
- **Sites** (`data/sites.json`): `sk_xxx → { repo, branch, github_token, allowed_origins, owner, created_at }`
- **OAuth states** (`data/oauth_states.json`): `nonce → { site_key, flow, created_at }` — 10-minute TTL, single-use, cleaned up on expiry

**Note:** Sessions are no longer stored server-side — they use stateless JWTs (see below).

**Methods:**
- `create(repo:, branch:, github_token:, allowed_origins:, owner:)` — create a new site
- `get(key)` — get site by key
- `list_for_owner(username)` — list sites by owner username
- `update(key, **attrs)` — update site attributes (branch, allowed_origins)
- `delete(key)` — remove a site

**To replace in production:** PostgreSQL for sites, Redis for OAuth states.

---

### `lib/jwt_session.rb` — Stateless JWT Authentication

**Purpose:** Replaces the server-side session store with signed, stateless JSON Web Tokens.

**How it works:**
1. On successful GitHub OAuth, the server creates a JWT containing the user's identity and an encrypted GitHub access token
2. The JWT is sent to the client (via URL fragment for dashboard, or postMessage for contributors)
3. On every API request, the client sends the JWT in the `Authorization: Bearer` header
4. The server verifies the signature and expiration — no database/file lookup needed

**JWT payload structure:**
```json
{
  "username": "thibault",
  "avatar": "https://avatars.githubusercontent.com/u/...",
  "ght": "<AES-256-GCM encrypted GitHub token>",
  "flow": "dashboard",
  "site_key": "sk_xxx (contributor flow only)",
  "exp": 1710892800,
  "iat": 1710806400
}
```

**Security design:**
- **Signing:** HMAC-SHA256 (`HS256`) with `JWT_SECRET` — proves the token was issued by the server and hasn't been tampered with
- **GitHub token encryption:** AES-256-GCM with `TOKEN_ENCRYPTION_KEY` — the `ght` claim is an opaque encrypted blob readable only by the server. This prevents the GitHub access token from being exposed even though JWTs are base64-encoded.
- **Expiration:** 24h TTL embedded in the `exp` claim, with 30s clock skew tolerance
- **Client-side decoding:** The dashboard and embed scripts decode the JWT payload client-side to read `username`, `avatar`, and `exp` — eliminating the need for a `/api/owner/me` call in the happy path. The `ght` field is unreadable client-side (encrypted).

**Methods:**
- `JwtSession.encode(username:, avatar:, github_token:, flow:, site_key:)` → JWT string
- `JwtSession.decode(jwt_string)` → `{ username:, avatar:, github_token:, flow:, site_key: }` or `nil`

**Trade-off:** JWTs cannot be revoked individually (no server-side state). If revocation becomes critical, a short-lived JWT + refresh token pattern or a deny list would be needed.

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes | Claude API key for the edit agent |
| `GITHUB_CLIENT_ID` | Yes | GitHub OAuth App client ID |
| `GITHUB_CLIENT_SECRET` | Yes | GitHub OAuth App client secret |
| `JWT_SECRET` | Yes | Secret for signing JWTs (HS256). Any random string, 32+ chars |
| `TOKEN_ENCRYPTION_KEY` | Yes | AES-256 key for encrypting GitHub tokens in JWTs. Exactly 64 hex characters |

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

- Sessions use **stateless JWTs** — no server-side session storage
- **Session TTL: 24 hours** — embedded in the JWT `exp` claim, with 30s clock skew tolerance
- JWTs are signed with HMAC-SHA256 (`HS256`) using `JWT_SECRET`
- The contributor's GitHub access token is **AES-256-GCM encrypted** inside the JWT (`ght` claim) — unreadable client-side, decrypted only by the server
- Client-side stores the JWT in `localStorage` and decodes public claims (`username`, `avatar`, `exp`) for display — no API call needed
- Client-side checks `exp` before sending requests — expired tokens are cleared automatically

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
| `jwt` | ~> 2.7 | JWT signing and verification (HS256) |
| `openssl` (stdlib) | — | AES-256-GCM encryption for GitHub tokens in JWTs |

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
