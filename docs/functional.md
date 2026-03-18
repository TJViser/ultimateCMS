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
1. Owner goes to ultimatecms.com
2. Signs up / logs in with GitHub
3. Dashboard → "Add a site"
4. Enters: repository (owner/repo), branch (main), allowed domains
5. System generates a site key: sk_a8f3e2b1
6. Owner gets the embed script:
   <script src="https://ultimatecms.com/ucms.js" data-site="sk_a8f3e2b1"></script>
7. Owner adds the script to their site's HTML (before </body>)
8. Done — contributors can now edit
```

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

### F6: Site Management

| Action | Detail |
|--------|--------|
| **Register site** | `POST /api/sites` → returns `sk_xxx` + embed snippet |
| **Site config** | Stored server-side: repo, branch, owner token, allowed origins |
| **Opaque key** | Client-side script only knows `sk_xxx`, never the repo name |

---

## Monetization Strategy

### Pricing Tiers (Proposed)

| Tier | Price | Limits |
|------|-------|--------|
| **Free** | $0/mo | 1 site, 10 edits/month, 1 contributor |
| **Pro** | $19/mo | 5 sites, unlimited edits, 5 contributors |
| **Team** | $49/mo | Unlimited sites, unlimited edits, unlimited contributors, priority support |
| **Enterprise** | Custom | Self-hosted option, GitLab support, SSO, audit logs |

### What's Gated

- Number of sites (site keys)
- Number of edits per month (API calls to `/api/edit`)
- Number of contributors per site
- Advanced features: custom PR templates, Slack notifications, approval workflows

### Revenue Levers

- The site key system makes metering trivial (count API calls per `sk_xxx`)
- GitHub OAuth identifies unique contributors
- The AI agent cost (Claude API) scales with usage — passed through in pricing
- Self-hosted / on-premise for enterprise customers

---

## Roadmap

### Phase 1 — MVP (Current State)

- [x] Embed script with floating edit button
- [x] GitHub OAuth for contributors
- [x] Visual text editor (contenteditable)
- [x] Rich context capture (DOM path, classes, section, siblings)
- [x] AI agent: grep repo → Claude finds source → edit → PR
- [x] Site key system (opaque, server-side config)
- [ ] Site owner onboarding (dashboard UI)
- [ ] PostgreSQL storage (replace JSON files)
- [ ] Session expiry + refresh tokens
- [ ] Origin validation (only allow edits from registered domains)

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
