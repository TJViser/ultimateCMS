# UltimateCMS — Functional Specification

## Vision

UltimateCMS allows anyone to edit the text content of any website visually — directly on the live page — without knowing the codebase, the framework, or the file structure. An AI agent handles the translation from "what changed on screen" to "where to edit in the source code."

The result is a GitHub pull request, ready for review.

---

## Personas

### Site Owner
- **Who:** Developer or agency who built the website
- **Goal:** Let their client (or team) update content without needing to touch code
- **Actions:** Signs up, connects their GitHub repo, gets an embed script, adds it to the site

### Contributor
- **Who:** Marketing person, content manager, client, product owner — non-technical
- **Goal:** Fix a typo, update a headline, change a description — without asking a developer
- **Actions:** Visits the live site, clicks the edit button, edits text inline, submits. Gets a PR link.

### Reviewer
- **Who:** Developer on the team
- **Goal:** Review content changes before they go live
- **Actions:** Reviews the PR on GitHub, approves, merges. Standard code review flow.

---

## User Flows

### Flow 1: Site Owner — Onboarding

```
1. Owner goes to ultimatecms.com and clicks "Dashboard" in the top nav
2. Clicks "Sign in with GitHub" → GitHub OAuth redirect
3. After authentication, lands on the dashboard at /dashboard
4. First visit: sees an empty state with a 3-step onboarding guide
5. Clicks "Add your first site"
6. Fills in: repository (owner/repo), branch (main), allowed origins
7. System creates a site key and shows the embed snippet
8. Owner clicks "Copy" to copy the script tag:
   <script src="https://ultimatecms.com/ucms.js" data-site="sk_a8f3e2b1"></script>
9. Owner adds the script to their site's HTML (before </body>)
10. Done — contributors can now edit
```

**Dashboard features:**
- View all registered sites with their keys, repos, and branches
- Copy embed snippet with one click
- Manage allowed origins per site (add/remove)
- Delete sites
- Session persists across page reloads (24h expiry)

### Flow 2: Contributor — Editing Content

```
1. Contributor visits the live website (e.g., septemconsulting.com)
2. A small pencil icon appears at the bottom-right corner
3. Contributor clicks it
4. First time: GitHub login popup appears → contributor authenticates
5. The page enters "edit mode":
   - A toolbar appears at the top: "UltimateCMS | /path | Submit changes"
   - All text elements become hoverable (blue dashed outline on hover)
6. Contributor clicks a text element → it becomes editable
7. They type the new text
8. The element gets a green left border (= modified)
9. The badge on "Submit" shows the count of changes
10. Contributor clicks "Submit changes"
11. Loading screen: "The AI agent is analyzing your codebase..."
12. Success: "Pull request created!" with a link to the PR
13. Page reloads to normal state
```

### Flow 3: Reviewer — Merging Changes

```
1. Reviewer gets a GitHub notification (or the PR link from the contributor)
2. Opens the PR on GitHub
3. PR contains:
   - Title: "Content update via UltimateCMS"
   - Body: list of text changes (old → new), page URL, files modified
   - Diff: the exact source file changes
4. Reviewer reviews the diff
5. If OK → merge → site rebuilds automatically (Netlify/Vercel CI)
6. Changes are live
```

---

## Feature Specification

### F1: Embed Script (`ucms.js`)

| Aspect | Detail |
|--------|--------|
| **Trigger** | Added to any website as a `<script>` tag with `data-site` attribute |
| **Visible UI** | Small floating pencil button (48x48px), bottom-right |
| **Auth** | GitHub OAuth popup when contributor clicks edit |
| **Session** | Stored in localStorage, persists across page reloads |
| **Weight** | < 5KB minified, no dependencies |
| **Invasiveness** | Zero impact on the site until clicked. No layout shift, no network requests until interaction. |

### F2: Visual Editor (`editor.js`)

| Aspect | Detail |
|--------|--------|
| **Toolbar** | Fixed top bar: logo, page path, status text, settings, cancel, submit button |
| **Editable elements** | h1-h6, p, a, span, li, button, label, blockquote, strong, em, small, td, th, figcaption |
| **Hover state** | Blue dashed outline (2px) around editable elements |
| **Edit state** | Blue solid outline, light blue background tint |
| **Changed state** | Green left border (3px) |
| **Link handling** | Navigation is blocked. Links are editable like any other text. |
| **Form handling** | Form submissions are blocked. |
| **Body offset** | `body { margin-top: 48px }` to prevent toolbar overlap |

### F3: Rich Context Capture

For each text change, the editor captures:

| Data | Example | Purpose |
|------|---------|---------|
| Old/new text | "Nos Services" → "Nos Expertises" | The actual change |
| HTML tag | `h2` | Helps find the right element type in source |
| CSS classes | `section-title` | Class names often appear in templates |
| DOM path | `section#services > div.container > h2` | Full structural context |
| Parent info | tag + classes of parent element | Narrows down the source location |
| Sibling texts | "Ce que nous faisons" | Nearby text confirms the right section |
| Section info | id, class, first heading of nearest `<section>` | Key for identifying which block in the source |
| href | (for links only) | Links often have unique hrefs in source |

### F4: AI Edit Agent

| Aspect | Detail |
|--------|--------|
| **Input** | Page URL, all changes with rich context |
| **Step 1** | Search repo for each old text (GitHub code search API) |
| **Step 2** | Read candidate files (templates, data files, content files) |
| **Step 3** | Send all context + file contents to Claude |
| **Step 4** | Claude returns: `[{ file, old_string, new_string }]` |
| **Step 5** | Apply edits to source files on a new branch |
| **Step 6** | Open a pull request |
| **Supported frameworks** | Any — HTML, React/JSX, Vue, Svelte, 11ty/Nunjucks, Hugo, Jekyll, Next.js, Liquid, ERB, Markdown, JSON data files, YAML, i18n files |

### F5: GitHub Integration

| Action | Implementation |
|--------|---------------|
| **Auth** | OAuth 2.0 web flow with popup window |
| **File search** | `GET /search/code` + heuristic scanning |
| **File read** | `GET /repos/.../contents/:path` |
| **Branch creation** | `POST /git/refs` from HEAD of base branch |
| **File commit** | `PUT /repos/.../contents/:path` with SHA |
| **PR creation** | `POST /repos/.../pulls` |
| **PR authorship** | Uses contributor's own GitHub token |

### F6: Site Management & Dashboard

| Aspect | Detail |
|--------|--------|
| **Dashboard URL** | `/dashboard` — single-page app for site owners |
| **Auth** | GitHub OAuth with redirect flow (separate from contributor popup flow) |
| **Session** | Stored in localStorage, 24h expiry, token in URL fragment on first redirect |
| **Create site** | Modal form: repo (owner/repo), branch, allowed origins → generates `sk_xxx` + embed snippet |
| **Site cards** | Each site shows: repo, branch, key, embed snippet (copy button), allowed origins, created date |
| **Copy snippet** | One-click copy of the `<script>` embed tag |
| **Manage origins** | Add/remove allowed origins per site inline |
| **Delete site** | Confirmation prompt → removes site and invalidates the key |
| **Opaque key** | Client-side script only knows `sk_xxx`, never the repo name |
| **Limits** | Max 20 sites per owner (prototype) |

---

## Monetization Strategy

### Pricing Tiers (Proposed)

| Tier | Price | Sites | Edits/month | Contributors | AI Isolation |
|------|-------|-------|-------------|--------------|-------------|
| **Free** | $0/mo | 1 | 10 | 1 | Shared pool |
| **Pro** | $19/mo | 10 | Unlimited | 10 per site | Shared pool |
| **Team** | $49/mo | Unlimited | Unlimited | Unlimited | Dedicated container |
| **Enterprise** | Custom | Unlimited | Unlimited | Unlimited | Self-hosted (BYOAI) |

**Free → Pro upgrade trigger:** the user connects a second site. They've already validated the value on their first site — the upgrade is a natural expansion moment.

**Pro → Team upgrade trigger:** security/compliance needs. The client wants their code processed by an isolated AI instance, not shared with other customers.

**Team → Enterprise upgrade trigger:** the client's code must never leave their infrastructure. Banks, healthcare, government.

### What's Gated

- **Number of sites** (site keys) — the primary gate between Free and Pro
- Number of edits per month (API calls to `/api/edit`)
- Number of contributors per site
- AI isolation level (shared → dedicated → self-hosted)
- Advanced features: custom PR templates, Slack notifications, approval workflows, SSO, audit logs

### Revenue Levers

- The site key system makes metering trivial (count API calls per `sk_xxx`)
- GitHub OAuth identifies unique contributors
- The AI agent cost (Claude API) scales with usage — passed through in pricing
- Dedicated AI containers for Team tier = predictable margin
- Self-hosted / BYOAI for enterprise = license fee, no infra cost for us

---

## Roadmap

### Phase 1 — MVP (Current State)

- [x] Embed script with floating edit button
- [x] GitHub OAuth for contributors
- [x] Visual text editor (contenteditable)
- [x] Rich context capture (DOM path, classes, section, siblings)
- [x] AI agent: grep repo → Claude finds source → edit → PR
- [x] Site key system (opaque, server-side config)
- [x] Site owner onboarding (dashboard UI)
- [ ] PostgreSQL storage (replace JSON files)
- [x] Session expiry (24h TTL) + JWT-based stateless auth
- [x] Origin validation (only allow edits from registered domains)
- [x] Security hardening (XSS, CSRF, rate limiting, input validation, CSP)

### Phase 2 — Polish

- [ ] Dashboard for site owners (list sites, view edit history, manage contributors)
- [ ] Contributor permissions (who can edit which site)
- [ ] Edit preview: show diff before submitting
- [ ] Undo last edit (before submit)
- [ ] Batch edits: combine all changes into a single commit
- [ ] Custom commit messages
- [ ] Success notification: link to PR + link to deploy preview (Netlify/Vercel)
- [ ] Error recovery: retry failed edits, show which changes succeeded

### Phase 3 — Scale

- [ ] Stripe billing integration
- [ ] Usage metering (edits/month per site)
- [ ] GitLab support (same architecture, different API client)
- [ ] Bitbucket support
- [ ] Slack/Discord notifications when a PR is created
- [ ] Webhook on PR merge (trigger custom actions)
- [ ] Chrome extension alternative (for sites where you can't add the script)
- [ ] Multi-language: detect i18n frameworks and offer to edit specific locales

### Phase 4 — Advanced Editing

- [ ] Image replacement (upload → commit to repo → update src)
- [ ] Link URL editing (change href, not just text)
- [ ] Style editing (change colors, font sizes via CSS variables)
- [ ] Component-level editing (add/remove/reorder sections)
- [ ] Drag-and-drop reordering of list items
- [ ] Markdown preview for content files
- [ ] Real-time collaboration (multiple contributors editing simultaneously)

### Phase 5 — Enterprise

- [ ] Self-hosted deployment (Docker image)
- [ ] SSO / SAML authentication
- [ ] Audit logs (who edited what, when)
- [ ] Approval workflows (editor → reviewer → publisher)
- [ ] Role-based access control
- [ ] Custom branding (white-label the edit button / toolbar)
- [ ] API access for programmatic edits

---

## Security & Trust

UltimateCMS is built with security as a core principle. Your website, your code, and your contributors' data are protected at every level.

### Your website is safe

- **Nothing changes on your live site.** UltimateCMS never modifies your website directly. Every edit produces a GitHub pull request that must be reviewed and approved by your team before anything goes live.
- **Read-only by default.** The embed script is a lightweight JavaScript file (< 5KB) that does nothing until a contributor actively clicks the edit button. No background requests, no data collection, no tracking.
- **Domain-restricted access.** You configure which domains are allowed to submit edits. Requests from any other origin are blocked.

### Your code is protected

- **Pull requests, not direct commits.** Every change goes through your standard code review process on GitHub. Nothing is merged without your approval.
- **Branch isolation.** Edits are made on separate branches (`ucms/edit-xxxx`), never on your main branch.
- **Contributor identity.** Pull requests are authored by the contributor's own GitHub account, so you always know who made each change. GitHub's permission system is enforced — contributors can only edit repos they have access to.

### Your data is secure

- **GitHub OAuth authentication.** Contributors sign in with their GitHub account. UltimateCMS never asks for or stores passwords.
- **Signed & encrypted sessions.** Sessions use industry-standard JSON Web Tokens (JWT), signed with HMAC-SHA256. Sensitive data (GitHub access tokens) is encrypted with AES-256-GCM inside the token. Sessions expire automatically after 24 hours.
- **No secrets on the client.** Your GitHub tokens, API keys, and repo configuration stay server-side. The client-side script only knows an opaque site key (`sk_xxx`) — your repo name is never exposed.
- **HTTPS enforced.** All communication between the editor and the UltimateCMS backend is encrypted in transit.

### Industry-standard protections

| Protection | What it means for you |
|-----------|----------------------|
| **XSS prevention** | All user-generated content is escaped before display. Malicious scripts cannot be injected through the editor. |
| **CSRF protection** | Authenticated requests are protected against cross-site request forgery attacks. |
| **Rate limiting** | Automated abuse and brute-force attempts are blocked by per-IP rate limits on all endpoints. |
| **Content Security Policy** | Browser-level restrictions prevent unauthorized scripts from running on the editing interface. |
| **Input validation** | All data submitted to the API is validated for format, length, and type before processing. |
| **Secure OAuth flow** | The GitHub login flow uses server-verified, single-use, time-limited state tokens to prevent authentication attacks. |

### AI safety

- **Prompt injection protection.** All user-provided text is sanitized and length-limited before being sent to the AI agent. Malicious input cannot manipulate the AI's behavior.
- **Output validation.** The AI's response is validated structurally before any code change is applied. Invalid or suspicious edits are rejected.
- **No data retention.** Text content is sent to the Claude API for processing only. It is not stored, used for training, or shared with third parties.

### Compliance-friendly

- Edits are fully auditable via GitHub's built-in PR history, commit logs, and branch protection rules.
- No personal data is stored beyond what GitHub provides during OAuth (username and public avatar URL).
- Compatible with your existing branch protection rules, required reviews, and CI/CD checks.

---

## Competitive Landscape

| Product | Visual Editing | Framework Agnostic | Git-based | AI Source Mapping | Pricing |
|---------|:---:|:---:|:---:|:---:|---------|
| **UltimateCMS** | Yes | Yes | Yes | Yes | Freemium |
| Decap CMS | No (forms) | No (SSG only) | Yes | No | Free |
| TinaCMS | Yes | No (React) | Yes | No | Freemium |
| Storyblok | Yes | No (SDK) | No | No | Paid |
| Builder.io | Yes | No (SDK) | No | No | Paid |
| Contentful | No | Yes | No | No | Paid |
| Sanity | No | Yes | No | No | Freemium |
| CloudCannon | Yes | No (SSG) | Yes | No | Paid |

**UltimateCMS differentiator:** The AI agent that understands any codebase. No SDK, no framework requirement, no migration. Add one script tag and it works.

---

## Key Metrics to Track

| Metric | What it tells us |
|--------|-----------------|
| Sites registered | Adoption |
| Edits submitted / month | Engagement + billing |
| PR merge rate | Quality of AI edits (are they correct?) |
| Agent accuracy | % of edits where Claude found the right file/location |
| Time to PR | How fast the agent processes (target: < 15 seconds) |
| Contributor retention | Do contributors come back to edit again? |
| Edit → Merge time | How fast are PRs reviewed? |
