// ============================================
// UltimateCMS — Dashboard
// ============================================

(function () {
  const SESSION_KEY = 'ucms_dashboard_session';
  const API_BASE = location.origin;

  let session = null; // { token, username, avatar }
  let sites = [];

  // --- DOM refs ---
  const authScreen = document.getElementById('auth-screen');
  const dashboard = document.getElementById('dashboard');
  const nav = document.getElementById('nav');
  const navUser = document.getElementById('nav-user');
  const sitesLoading = document.getElementById('sites-loading');
  const sitesEmpty = document.getElementById('sites-empty');
  const sitesList = document.getElementById('sites-list');
  const addModal = document.getElementById('add-modal');
  const addForm = document.getElementById('add-form');
  const toast = document.getElementById('toast');

  // ============================================
  // INIT
  // ============================================

  function init() {
    // Check for token in URL fragment (from OAuth callback redirect)
    const hash = location.hash;
    if (hash.startsWith('#token=')) {
      const token = hash.slice(7);
      if (/^[a-f0-9]{64}$/.test(token)) {
        // Fetch user info and store session
        history.replaceState(null, '', '/dashboard');
        fetchUserAndLogin(token);
        return;
      }
    }

    // Check stored session
    try {
      session = JSON.parse(localStorage.getItem(SESSION_KEY));
      if (session && session.token) {
        showDashboard();
        loadSites();
        return;
      }
    } catch {}

    showAuth();
  }

  async function fetchUserAndLogin(token) {
    try {
      // Fetch user profile and sites in parallel
      const [meRes, sitesRes] = await Promise.all([
        apiFetch('/api/owner/me', { token }),
        apiFetch('/api/owner/sites', { token }),
      ]);

      if (!meRes.ok || !sitesRes.ok) {
        showAuth();
        return;
      }

      const user = await meRes.json();
      session = { token, username: user.username, avatar: user.avatar };
      localStorage.setItem(SESSION_KEY, JSON.stringify(session));

      showDashboard();
      sites = await sitesRes.json();
      renderSites();
    } catch {
      showAuth();
    }
  }

  // ============================================
  // AUTH
  // ============================================

  function showAuth() {
    session = null;
    authScreen.style.display = '';
    dashboard.style.display = 'none';
    nav.style.display = 'none';
  }

  function showDashboard() {
    authScreen.style.display = 'none';
    dashboard.style.display = '';
    nav.style.display = '';
    updateNav();
  }

  function updateNav() {
    navUser.textContent = '';

    if (session?.avatar) {
      const img = document.createElement('img');
      img.className = 'nav-avatar';
      img.alt = '';
      try {
        const url = new URL(session.avatar);
        if (url.protocol === 'https:' && url.hostname === 'avatars.githubusercontent.com') {
          img.src = session.avatar;
          navUser.appendChild(img);
        }
      } catch {}
    }

    if (session?.username) {
      const span = document.createElement('span');
      span.textContent = session.username;
      navUser.appendChild(span);
    }
  }

  document.getElementById('gh-login').addEventListener('click', () => {
    location.href = `${API_BASE}/auth/github/dashboard`;
  });

  document.getElementById('nav-logout').addEventListener('click', () => {
    localStorage.removeItem(SESSION_KEY);
    session = null;
    showAuth();
  });

  // ============================================
  // SITES
  // ============================================

  async function loadSites() {
    sitesLoading.style.display = '';
    sitesEmpty.style.display = 'none';
    sitesList.style.display = 'none';

    try {
      const res = await apiFetch('/api/owner/sites');
      if (!res.ok) {
        if (res.status === 401) {
          showAuth();
          return;
        }
        throw new Error('Failed to load sites');
      }
      sites = await res.json();
      renderSites();
    } catch (err) {
      showToast(err.message, 'error');
      sitesLoading.style.display = 'none';
    }
  }

  function renderSites() {
    sitesLoading.style.display = 'none';

    if (sites.length === 0) {
      sitesEmpty.style.display = '';
      sitesList.style.display = 'none';
      return;
    }

    sitesEmpty.style.display = 'none';
    sitesList.style.display = '';
    sitesList.textContent = '';

    sites.forEach(site => {
      sitesList.appendChild(createSiteCard(site));
    });
  }

  function createSiteCard(site) {
    const card = document.createElement('div');
    card.className = 'site-card';
    card.dataset.key = site.key;

    // Top row: repo + branch + actions
    const top = document.createElement('div');
    top.className = 'site-top';

    const repoDiv = document.createElement('div');
    repoDiv.className = 'site-repo';
    repoDiv.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 19c-5 1.5-5-2.5-7-3m14 6v-3.87a3.37 3.37 0 0 0-.94-2.61c3.14-.35 6.44-1.54 6.44-7A5.44 5.44 0 0 0 20 4.77 5.07 5.07 0 0 0 19.91 1S18.73.65 16 2.48a13.38 13.38 0 0 0-7 0C6.27.65 5.09 1 5.09 1A5.07 5.07 0 0 0 5 4.77a5.44 5.44 0 0 0-1.5 3.78c0 5.42 3.3 6.61 6.44 7A3.37 3.37 0 0 0 9 18.13V22"/></svg>`;
    const repoName = document.createElement('span');
    repoName.textContent = site.repo;
    repoDiv.appendChild(repoName);

    const branchSpan = document.createElement('span');
    branchSpan.className = 'site-branch';
    branchSpan.textContent = site.branch;

    const repoGroup = document.createElement('div');
    repoGroup.style.display = 'flex';
    repoGroup.style.alignItems = 'center';
    repoGroup.style.gap = '10px';
    repoGroup.append(repoDiv, branchSpan);

    const actions = document.createElement('div');
    actions.className = 'site-actions';

    const deleteBtn = document.createElement('button');
    deleteBtn.className = 'btn btn-danger btn-sm';
    deleteBtn.textContent = 'Delete';
    deleteBtn.addEventListener('click', () => deleteSite(site.key));
    actions.appendChild(deleteBtn);

    top.append(repoGroup, actions);

    // Meta: site key + created date
    const meta = document.createElement('div');
    meta.className = 'site-meta';

    const keySpan = document.createElement('span');
    keySpan.className = 'site-key';
    keySpan.textContent = site.key;
    meta.appendChild(keySpan);

    if (site.created_at) {
      const dateSpan = document.createElement('span');
      const d = new Date(site.created_at);
      dateSpan.textContent = `Created ${d.toLocaleDateString()}`;
      meta.appendChild(dateSpan);
    }

    // Embed snippet
    const snippet = document.createElement('div');
    snippet.className = 'snippet-block';

    const snippetCode = document.createElement('div');
    snippetCode.className = 'snippet-code';
    snippetCode.textContent = site.embed_script;

    const copyBtn = document.createElement('button');
    copyBtn.className = 'copy-btn';
    copyBtn.textContent = 'Copy';
    copyBtn.addEventListener('click', () => {
      navigator.clipboard.writeText(site.embed_script).then(() => {
        copyBtn.textContent = 'Copied!';
        copyBtn.classList.add('copied');
        setTimeout(() => {
          copyBtn.textContent = 'Copy';
          copyBtn.classList.remove('copied');
        }, 2000);
      });
    });

    snippet.append(snippetCode, copyBtn);

    // Origins
    const originsRow = document.createElement('div');
    originsRow.className = 'origins-row';

    const originsLabel = document.createElement('span');
    originsLabel.className = 'origin-label';
    originsLabel.textContent = 'Allowed origins:';
    originsRow.appendChild(originsLabel);

    if (site.allowed_origins && site.allowed_origins.length > 0) {
      site.allowed_origins.forEach(origin => {
        const tag = document.createElement('span');
        tag.className = 'origin-tag';
        tag.textContent = origin;

        const removeBtn = document.createElement('button');
        removeBtn.className = 'origin-remove';
        removeBtn.textContent = '\u00d7';
        removeBtn.title = 'Remove origin';
        removeBtn.addEventListener('click', () => removeOrigin(site.key, origin));
        tag.appendChild(removeBtn);

        originsRow.appendChild(tag);
      });
    } else {
      const noneSpan = document.createElement('span');
      noneSpan.className = 'origin-tag';
      noneSpan.textContent = 'any (not restricted)';
      noneSpan.style.color = '#FBBF24';
      originsRow.appendChild(noneSpan);
    }

    // Add origin button
    const addOriginBtn = document.createElement('button');
    addOriginBtn.className = 'btn btn-sm btn-ghost';
    addOriginBtn.textContent = '+ Add';
    addOriginBtn.style.fontSize = '11px';
    addOriginBtn.style.padding = '2px 8px';
    addOriginBtn.addEventListener('click', () => promptAddOrigin(site.key));
    originsRow.appendChild(addOriginBtn);

    card.append(top, meta, snippet, originsRow);
    return card;
  }

  // ============================================
  // SITE ACTIONS
  // ============================================

  async function deleteSite(key) {
    if (!confirm('Delete this site? Contributors will no longer be able to edit.')) return;

    try {
      const res = await apiFetch(`/api/owner/sites/${encodeURIComponent(key)}`, { method: 'DELETE' });
      if (!res.ok) {
        const data = await res.json();
        throw new Error(data.error || 'Failed to delete');
      }
      sites = sites.filter(s => s.key !== key);
      renderSites();
      showToast('Site deleted', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    }
  }

  async function removeOrigin(key, origin) {
    const site = sites.find(s => s.key === key);
    if (!site) return;

    const newOrigins = (site.allowed_origins || []).filter(o => o !== origin);

    try {
      const res = await apiFetch(`/api/owner/sites/${encodeURIComponent(key)}`, {
        method: 'PATCH',
        body: JSON.stringify({ allowed_origins: newOrigins }),
      });
      if (!res.ok) {
        const data = await res.json();
        throw new Error(data.error || 'Failed to update');
      }
      site.allowed_origins = newOrigins;
      renderSites();
      showToast('Origin removed', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    }
  }

  function promptAddOrigin(key) {
    const origin = prompt('Enter the allowed origin URL (e.g., https://yoursite.com):');
    if (!origin) return;

    try {
      const url = new URL(origin.trim());
      if (url.protocol !== 'http:' && url.protocol !== 'https:') {
        showToast('Origin must be an http or https URL', 'error');
        return;
      }
    } catch {
      showToast('Invalid URL', 'error');
      return;
    }

    addOrigin(key, origin.trim());
  }

  async function addOrigin(key, origin) {
    const site = sites.find(s => s.key === key);
    if (!site) return;

    const newOrigins = [...(site.allowed_origins || []), origin];

    try {
      const res = await apiFetch(`/api/owner/sites/${encodeURIComponent(key)}`, {
        method: 'PATCH',
        body: JSON.stringify({ allowed_origins: newOrigins }),
      });
      if (!res.ok) {
        const data = await res.json();
        throw new Error(data.error || 'Failed to update');
      }
      site.allowed_origins = newOrigins;
      renderSites();
      showToast('Origin added', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    }
  }

  // ============================================
  // ADD SITE MODAL
  // ============================================

  function openAddModal() {
    addForm.reset();
    document.getElementById('add-branch').value = 'main';
    hideFieldError('add-repo-error');
    addModal.classList.add('open');
  }

  function closeAddModal() {
    addModal.classList.remove('open');
  }

  document.getElementById('add-site-btn').addEventListener('click', openAddModal);
  document.getElementById('add-site-empty-btn').addEventListener('click', openAddModal);
  document.getElementById('add-cancel').addEventListener('click', closeAddModal);

  addModal.addEventListener('click', (e) => {
    if (e.target === addModal) closeAddModal();
  });

  addForm.addEventListener('submit', async (e) => {
    e.preventDefault();

    const repo = document.getElementById('add-repo').value.trim();
    const branch = document.getElementById('add-branch').value.trim() || 'main';
    const originsStr = document.getElementById('add-origins').value.trim();

    // Validate repo
    if (!/^[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+$/.test(repo)) {
      showFieldError('add-repo-error', 'Enter a valid repository (owner/repo)');
      return;
    }
    hideFieldError('add-repo-error');

    // Parse origins
    const allowed_origins = originsStr
      ? originsStr.split(',').map(s => s.trim()).filter(Boolean)
      : [];

    // Validate origins
    for (const origin of allowed_origins) {
      try {
        const url = new URL(origin);
        if (url.protocol !== 'http:' && url.protocol !== 'https:') {
          showToast(`Invalid origin: ${origin}`, 'error');
          return;
        }
      } catch {
        showToast(`Invalid URL: ${origin}`, 'error');
        return;
      }
    }

    const submitBtn = document.getElementById('add-submit');
    submitBtn.disabled = true;
    submitBtn.textContent = 'Creating...';

    try {
      const res = await apiFetch('/api/owner/sites', {
        method: 'POST',
        body: JSON.stringify({ repo, branch, allowed_origins }),
      });

      const data = await res.json();

      if (!res.ok) {
        throw new Error(data.error || 'Failed to create site');
      }

      sites.push(data);
      renderSites();
      closeAddModal();
      showToast('Site created! Copy the embed snippet below.', 'success');
    } catch (err) {
      showToast(err.message, 'error');
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = 'Create site';
    }
  });

  // ============================================
  // HELPERS
  // ============================================

  function apiFetch(path, opts = {}) {
    const headers = {};
    const method = opts.method || 'GET';

    // Only set Content-Type when sending a body (avoids unnecessary CORS preflight)
    if (opts.body) {
      headers['Content-Type'] = 'application/json';
    }

    const token = opts.token || session?.token;
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    return fetch(`${API_BASE}${path}`, {
      method,
      headers,
      body: opts.body || undefined,
    });
  }

  function showToast(message, type) {
    toast.textContent = message;
    toast.className = `toast ${type} show`;
    setTimeout(() => {
      toast.classList.remove('show');
    }, 3500);
  }

  function showFieldError(id, message) {
    const el = document.getElementById(id);
    el.textContent = message;
    el.style.display = 'block';
  }

  function hideFieldError(id) {
    const el = document.getElementById(id);
    el.style.display = 'none';
  }

  // ============================================
  // START
  // ============================================

  init();
})();
