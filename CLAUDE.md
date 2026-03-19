# CLAUDE.md

## Project Overview

UltimateCMS is a universal visual CMS. Contributors edit text on any live website, and an AI agent maps the visual changes back to the source code and creates a GitHub pull request — regardless of the framework (HTML, React, 11ty, Hugo, Next.js, etc.).

## Tech Stack

- **Backend**: Ruby / Sinatra, Puma
- **AI Agent**: Claude API (Anthropic) via `lib/edit_agent.rb`
- **Auth**: GitHub OAuth 2.0, stateless JWT sessions (HS256 + AES-256-GCM)
- **Git**: GitHub REST API v3 via `lib/github_client.rb`
- **Storage**: JSON files in `/data/` (prototype — no database)
- **Frontend**: Vanilla JS (injected scripts, no framework, no build step)
- **Security**: rack-protection, rack-attack, rack-cors, CSP headers

## Architecture

```
public/ucms.js       → embed script (FAB button, GitHub OAuth popup, loads editor)
public/editor.js     → visual editor (contenteditable, rich context capture, submits changes)
public/dashboard.html/js → site owner dashboard (create/manage sites, copy embed snippet)
app.rb               → Sinatra API (auth, routing, all endpoints)
lib/edit_agent.rb     → AI agent: finds source files, calls Claude, applies edits, creates PR
lib/github_client.rb  → GitHub API wrapper (search, read, commit, branch, PR)
lib/jwt_session.rb    → JWT encode/decode + AES-256-GCM encryption for GitHub tokens
lib/site_store.rb     → JSON file store for sites + OAuth states
lib/sanitize.rb       → HTML/JS/markdown escaping, input validation, prompt sanitization
```

## Commands

```bash
# Install dependencies
bundle install --path vendor/bundle

# Run the server
bundle exec puma

# Server runs at http://localhost:9292
```

## Environment Variables

Required in `.env` (see `.env.example`):
- `ANTHROPIC_API_KEY` — Claude API key
- `GITHUB_CLIENT_ID` — GitHub OAuth App client ID
- `GITHUB_CLIENT_SECRET` — GitHub OAuth App client secret
- `JWT_SECRET` — secret for signing JWTs (32+ chars)
- `TOKEN_ENCRYPTION_KEY` — AES-256 key for encrypting GitHub tokens in JWTs (64 hex chars)

## Key Conventions

- **No database** — all persistence is JSON files in `/data/`. This is a prototype. Don't add a DB without discussion.
- **No frontend build step** — `editor.js`, `ucms.js`, `dashboard.js` are vanilla JS served as static files. No npm, no bundler, no transpilation.
- **Two OAuth flows** — dashboard (redirect-based, for site owners) and contributor (popup/postMessage-based, for editors). They share the same GitHub OAuth app but have separate callback routes.
- **Security-first** — all user input is validated and sanitized. Never use `innerHTML` with user data in JS. Never interpolate user input into Ruby strings without escaping. See `lib/sanitize.rb` for helpers.
- **AI isolation** — each Claude API call is stateless (single message, no conversation). The system prompt in `edit_agent.rb` enforces confidentiality rules. Never log file contents.
- **Error messages** — never expose internal errors to the client. Use generic messages + server-side `logger.error`. GitHub API errors should only include the HTTP status code, not the response body.

## File Editing Guidelines

- `app.rb` is the largest file — when editing, be precise about which endpoint section you're modifying (dashboard auth, dashboard API, contributor auth, edit endpoint, legacy endpoints).
- `edit_agent.rb` contains the Claude prompt — changes to the prompt wording affect edit accuracy across all users. Test carefully.
- `github_client.rb` error messages must NOT include `res.body` — only status codes. This prevents leaking repo content into logs.
- Frontend JS files use DOM API (`createElement`, `textContent`, `append`) instead of `innerHTML` for any dynamic content. This is intentional for XSS prevention.

## Documentation

- `docs/technical.md` — architecture, endpoints, security, file reference
- `docs/functional.md` — personas, user flows, features, pricing, roadmap
- `outputs/ai-isolation-architecture.md` — design doc for multi-tenant AI isolation (not yet implemented)
