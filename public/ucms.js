// ============================================
// UltimateCMS — Embed Script
// Usage: <script src="https://ultimatecms.com/ucms.js" data-site="sk_xxx"></script>
// ============================================

(function () {
  if (window.__ultimateCMS) return;
  window.__ultimateCMS = true;

  // --- Security: HTML escape helper ---
  function escapeHtml(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.appendChild(document.createTextNode(String(str)));
    return div.innerHTML;
  }

  // --- Security: Validate URL (must be https for avatars) ---
  function isValidAvatarUrl(str) {
    try {
      const url = new URL(str);
      return url.protocol === 'https:' && url.hostname === 'avatars.githubusercontent.com';
    } catch {
      return false;
    }
  }

  // --- Read site key from script tag ---
  const scriptTag = document.currentScript || document.querySelector('script[data-site]');
  const siteKey = scriptTag?.getAttribute('data-site');
  if (!siteKey) return;

  // Validate site key format
  if (!/^sk_[a-f0-9]+$/.test(siteKey)) return;

  const API_BASE = scriptTag.src.replace(/\/ucms\.js.*$/, '');
  const SESSION_KEY = 'ucms_session';

  // --- JWT helpers ---
  function decodeJwtPayload(jwt) {
    try {
      const parts = jwt.split('.');
      if (parts.length !== 3) return null;
      const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
      return JSON.parse(atob(b64));
    } catch { return null; }
  }

  function isTokenExpired(jwt) {
    const claims = decodeJwtPayload(jwt);
    if (!claims || !claims.exp) return true;
    return claims.exp < Date.now() / 1000;
  }

  // Load session with validation + expiry check
  let session = null;
  try {
    const stored = JSON.parse(localStorage.getItem(SESSION_KEY) || 'null');
    if (stored && typeof stored.token === 'string' && typeof stored.username === 'string') {
      if (!isTokenExpired(stored.token)) {
        session = stored;
      } else {
        localStorage.removeItem(SESSION_KEY);
      }
    }
  } catch {
    session = null;
  }

  // --- Inject floating edit button ---
  const fab = document.createElement('div');
  fab.id = 'ucms-fab';
  fab.innerHTML = `
    <style>
      #ucms-fab { position: fixed; bottom: 24px; right: 24px; z-index: 2147483646; font-family: -apple-system, Inter, sans-serif; }
      #ucms-fab-btn {
        width: 48px; height: 48px; border-radius: 14px;
        background: #1A1D27; border: 1px solid #2E3140;
        color: #5B8DEF; cursor: pointer;
        display: flex; align-items: center; justify-content: center;
        box-shadow: 0 4px 24px rgba(0,0,0,0.3); transition: all 0.2s;
      }
      #ucms-fab-btn:hover { transform: scale(1.08); background: #252836; }
      #ucms-fab-btn svg { width: 22px; height: 22px; }
      #ucms-auth-popup {
        position: absolute; bottom: 60px; right: 0;
        background: #1A1D27; border: 1px solid #2E3140; border-radius: 12px;
        padding: 20px; width: 260px;
        box-shadow: 0 12px 40px rgba(0,0,0,0.4); display: none;
      }
      #ucms-auth-popup.open { display: block; }
      #ucms-auth-popup h4 { color: #E4E5E9; font-size: 13px; margin-bottom: 6px; }
      #ucms-auth-popup p { color: #8B8D98; font-size: 11px; margin-bottom: 14px; line-height: 1.5; }
      .ucms-gh-btn {
        width: 100%; padding: 10px; border-radius: 8px;
        background: #E4E5E9; color: #1A1D27; border: none;
        font-size: 12px; font-weight: 600; cursor: pointer;
        font-family: inherit; display: flex; align-items: center;
        justify-content: center; gap: 8px; transition: background 0.15s;
      }
      .ucms-gh-btn:hover { background: #fff; }
      .ucms-gh-btn svg { width: 16px; height: 16px; }
      .ucms-logged { display: flex; align-items: center; gap: 8px; margin-bottom: 12px; }
      .ucms-avatar { width: 24px; height: 24px; border-radius: 6px; }
      .ucms-username { color: #E4E5E9; font-size: 12px; font-weight: 600; }
      .ucms-edit-btn {
        width: 100%; padding: 10px; border-radius: 8px;
        background: #5B8DEF; color: #fff; border: none;
        font-size: 12px; font-weight: 600; cursor: pointer; font-family: inherit;
      }
      .ucms-edit-btn:hover { background: #7BA3F5; }
      .ucms-logout { background: none; border: none; color: #8B8D98; font-size: 10px; cursor: pointer; padding: 8px 0 0; font-family: inherit; }
      .ucms-logout:hover { color: #F87171; }
    </style>

    <button id="ucms-fab-btn" title="Edit this page">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/>
      </svg>
    </button>

    <div id="ucms-auth-popup"></div>
  `;
  document.body.appendChild(fab);

  const fabBtn = document.getElementById('ucms-fab-btn');
  const popup = document.getElementById('ucms-auth-popup');

  fabBtn.addEventListener('click', () => {
    if (session?.token) {
      renderLoggedIn();
    } else {
      renderLogin();
    }
    popup.classList.toggle('open');
  });

  function renderLogin() {
    // Clear and rebuild with DOM methods to avoid innerHTML XSS
    popup.textContent = '';

    const h4 = document.createElement('h4');
    h4.textContent = 'UltimateCMS';
    const p = document.createElement('p');
    p.textContent = 'Sign in with GitHub to edit this page.';

    const btn = document.createElement('button');
    btn.className = 'ucms-gh-btn';
    btn.id = 'ucms-gh-login';
    btn.innerHTML = `
      <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0024 12c0-6.63-5.37-12-12-12z"/></svg>
      Sign in with GitHub
    `;
    btn.addEventListener('click', startAuth);

    popup.append(h4, p, btn);
  }

  function renderLoggedIn() {
    // Build with DOM methods to avoid XSS via username/avatar
    popup.textContent = '';

    const loggedDiv = document.createElement('div');
    loggedDiv.className = 'ucms-logged';

    // Only render avatar if URL is a valid GitHub avatar URL
    if (session.avatar && isValidAvatarUrl(session.avatar)) {
      const img = document.createElement('img');
      img.className = 'ucms-avatar';
      img.src = session.avatar;
      img.alt = '';
      loggedDiv.appendChild(img);
    }

    const usernameSpan = document.createElement('span');
    usernameSpan.className = 'ucms-username';
    usernameSpan.textContent = session.username; // textContent = safe
    loggedDiv.appendChild(usernameSpan);

    const editBtn = document.createElement('button');
    editBtn.className = 'ucms-edit-btn';
    editBtn.id = 'ucms-start-edit';
    editBtn.textContent = 'Edit this page';
    editBtn.addEventListener('click', loadEditor);

    const logoutBtn = document.createElement('button');
    logoutBtn.className = 'ucms-logout';
    logoutBtn.id = 'ucms-logout';
    logoutBtn.textContent = 'Sign out';
    logoutBtn.addEventListener('click', () => {
      session = null;
      localStorage.removeItem(SESSION_KEY);
      popup.classList.remove('open');
    });

    popup.append(loggedDiv, editBtn, logoutBtn);
  }

  // --- GitHub OAuth via popup window ---
  function startAuth() {
    const authUrl = `${API_BASE}/auth/github?site=${encodeURIComponent(siteKey)}`;
    const w = 500, h = 600;
    const left = (screen.width - w) / 2, top = (screen.height - h) / 2;
    const authWindow = window.open(authUrl, 'ucms-auth', `width=${w},height=${h},left=${left},top=${top}`);

    // Listen for the auth callback — validate origin
    window.addEventListener('message', function handler(e) {
      // Verify the message comes from our API origin
      const expectedOrigin = new URL(API_BASE).origin;
      if (e.origin !== expectedOrigin) return;
      if (e.data?.type !== 'ucms:auth') return;

      window.removeEventListener('message', handler);
      authWindow?.close();

      // Validate received data
      if (typeof e.data.token !== 'string' || typeof e.data.username !== 'string') return;

      session = {
        token: e.data.token,
        username: e.data.username,
        avatar: e.data.avatar,
      };
      localStorage.setItem(SESSION_KEY, JSON.stringify(session));
      popup.classList.remove('open');
      loadEditor();
    });
  }

  // --- Load the full editor ---
  function loadEditor() {
    fab.remove();
    popup.classList.remove('open');

    // Pass config to editor via global
    window.__ucmsConfig = {
      api_url: API_BASE,
      site_key: siteKey,
      session_token: session.token,
    };

    const s = document.createElement('script');
    s.src = `${API_BASE}/editor.js`;
    document.body.appendChild(s);
  }
})();
