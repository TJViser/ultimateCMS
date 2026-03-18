// ============================================
// UltimateCMS — Universal Visual Editor
// Injected by bookmarklet on any website
// ============================================

(function () {
  // If loaded via ucms.js embed, __ultimateCMS is already true — skip check
  if (window.__ultimateCMS && !window.__ucmsConfig) return;
  window.__ultimateCMS = true;

  // --- Config: from embed script (ucms.js) or manual bookmarklet ---
  const STORAGE_KEY = 'ultimatecms_config';
  const embedConfig = window.__ucmsConfig; // set by ucms.js
  let config = embedConfig
    ? { api_url: embedConfig.api_url, site_key: embedConfig.site_key, session_token: embedConfig.session_token }
    : JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null')
      || { api_url: '', site_key: '', session_token: '' };

  const changes = new Map(); // geId -> { oldText, newText, context }

  // ============================================
  // INJECT TOOLBAR
  // ============================================

  const toolbar = document.createElement('div');
  toolbar.id = 'ucms-toolbar';
  toolbar.innerHTML = `
    <style>
      #ucms-toolbar {
        position: fixed; top: 0; left: 0; right: 0; z-index: 2147483647;
        height: 48px; background: #1A1D27; border-bottom: 1px solid #2E3140;
        display: flex; align-items: center; justify-content: space-between;
        padding: 0 16px; font-family: -apple-system, Inter, sans-serif;
        box-shadow: 0 4px 24px rgba(0,0,0,0.3);
      }
      #ucms-toolbar * { box-sizing: border-box; margin: 0; padding: 0; }
      .ucms-left, .ucms-right { display: flex; align-items: center; gap: 10px; }
      .ucms-logo { font-weight: 700; font-size: 13px; color: #5B8DEF; letter-spacing: -0.02em; }
      .ucms-page { font-size: 11px; color: #8B8D98; background: #0F1117; padding: 4px 10px; border-radius: 5px; font-family: monospace; max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .ucms-btn { padding: 6px 14px; border-radius: 7px; font-size: 12px; font-weight: 600; cursor: pointer; border: 1px solid #2E3140; background: #252836; color: #E4E5E9; transition: all 0.15s; font-family: inherit; }
      .ucms-btn:hover { background: #2E3140; }
      .ucms-btn-primary { background: #5B8DEF; border-color: #5B8DEF; color: #fff; }
      .ucms-btn-primary:hover { background: #7BA3F5; }
      .ucms-btn-primary:disabled { opacity: 0.4; cursor: default; }
      .ucms-btn-danger { background: transparent; border-color: #F87171; color: #F87171; }
      .ucms-btn-danger:hover { background: rgba(248,113,113,0.1); }
      .ucms-badge { background: #FBBF24; color: #000; font-size: 10px; font-weight: 700; padding: 1px 7px; border-radius: 10px; margin-left: 4px; }
      .ucms-status { font-size: 11px; color: #8B8D98; }

      /* Editing styles injected into the page */
      [data-ucms-id] { cursor: pointer !important; transition: outline 0.15s, box-shadow 0.15s !important; }
      [data-ucms-id]:hover { outline: 2px dashed rgba(91,141,239,0.4) !important; outline-offset: 2px !important; }
      [data-ucms-id][contenteditable="true"] { outline: 2px solid rgba(91,141,239,0.9) !important; outline-offset: 2px !important; background: rgba(91,141,239,0.04) !important; }
      [data-ucms-changed] { box-shadow: -3px 0 0 0 #34D399 !important; }
      body { margin-top: 48px !important; }

      /* Config modal */
      #ucms-config-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.6); z-index: 2147483647; display: none; align-items: center; justify-content: center; }
      #ucms-config-overlay.open { display: flex; }
      #ucms-config-panel { background: #1A1D27; border: 1px solid #2E3140; border-radius: 14px; padding: 28px; width: 440px; max-width: 90vw; box-shadow: 0 24px 48px rgba(0,0,0,0.5); }
      #ucms-config-panel h3 { color: #E4E5E9; font-size: 15px; margin-bottom: 20px; }
      .ucms-field { margin-bottom: 14px; }
      .ucms-field label { display: block; font-size: 11px; font-weight: 600; color: #8B8D98; margin-bottom: 4px; text-transform: uppercase; letter-spacing: 0.05em; }
      .ucms-field input { width: 100%; padding: 9px 12px; background: #0F1117; border: 1px solid #2E3140; border-radius: 8px; color: #E4E5E9; font-size: 13px; font-family: inherit; outline: none; }
      .ucms-field input:focus { border-color: #5B8DEF; }
      .ucms-field small { font-size: 10px; color: #6B7280; margin-top: 4px; display: block; }
      .ucms-field-row { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }

      /* Result modal */
      #ucms-result-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.6); z-index: 2147483647; display: none; align-items: center; justify-content: center; }
      #ucms-result-overlay.open { display: flex; }
      #ucms-result-panel { background: #1A1D27; border: 1px solid #2E3140; border-radius: 14px; padding: 28px; width: 480px; max-width: 90vw; box-shadow: 0 24px 48px rgba(0,0,0,0.5); text-align: center; }
      #ucms-result-panel h3 { color: #E4E5E9; font-size: 15px; margin-bottom: 12px; }
      #ucms-result-panel p { color: #8B8D98; font-size: 13px; margin-bottom: 16px; line-height: 1.5; }
      #ucms-result-panel a { color: #5B8DEF; text-decoration: none; font-weight: 600; }
      #ucms-result-panel a:hover { text-decoration: underline; }
      .ucms-spinner { width: 24px; height: 24px; border: 3px solid #2E3140; border-top-color: #5B8DEF; border-radius: 50%; animation: ucms-spin 0.6s linear infinite; margin: 16px auto; }
      @keyframes ucms-spin { to { transform: rotate(360deg); } }
    </style>

    <div class="ucms-left">
      <span class="ucms-logo">UltimateCMS</span>
      <span class="ucms-page">${location.pathname}</span>
      <span class="ucms-status" id="ucms-status">Click any text to edit</span>
    </div>
    <div class="ucms-right">
      <button class="ucms-btn" id="ucms-settings-btn">Settings</button>
      <button class="ucms-btn ucms-btn-danger" id="ucms-cancel-btn">Cancel</button>
      <button class="ucms-btn ucms-btn-primary" id="ucms-submit-btn" disabled>
        Submit changes <span class="ucms-badge" id="ucms-badge" style="display:none">0</span>
      </button>
    </div>
  `;
  document.body.appendChild(toolbar);

  // ============================================
  // CONFIG MODAL
  // ============================================

  const configOverlay = document.createElement('div');
  configOverlay.id = 'ucms-config-overlay';
  configOverlay.innerHTML = `
    <div id="ucms-config-panel">
      <h3>UltimateCMS — Configuration</h3>
      <div class="ucms-field">
        <label>API URL</label>
        <input type="text" id="ucms-api-url" placeholder="https://your-app.com" value="${config.api_url}">
        <small>Your UltimateCMS backend URL</small>
      </div>
      <div class="ucms-field">
        <label>GitHub Repository</label>
        <input type="text" id="ucms-repo" placeholder="owner/repo" value="${config.repo}">
      </div>
      <div class="ucms-field-row">
        <div class="ucms-field">
          <label>Branch</label>
          <input type="text" id="ucms-branch" value="${config.branch}">
        </div>
        <div class="ucms-field">
          <label>GitHub Token</label>
          <input type="password" id="ucms-github-token" placeholder="ghp_xxx" value="${config.github_token}">
        </div>
      </div>
      <button class="ucms-btn ucms-btn-primary" id="ucms-config-save" style="width:100%;padding:10px;margin-top:8px">Save & Close</button>
    </div>
  `;
  document.body.appendChild(configOverlay);

  // ============================================
  // RESULT MODAL
  // ============================================

  const resultOverlay = document.createElement('div');
  resultOverlay.id = 'ucms-result-overlay';
  resultOverlay.innerHTML = `<div id="ucms-result-panel"></div>`;
  document.body.appendChild(resultOverlay);

  // ============================================
  // MARK EDITABLE ELEMENTS
  // ============================================

  const EDITABLE_TAGS = new Set([
    'H1','H2','H3','H4','H5','H6',
    'P','LI','TD','TH','FIGCAPTION','BLOCKQUOTE','LABEL',
    'BUTTON','A','SPAN','STRONG','EM','SMALL','B','I',
  ]);

  let nextId = 0;

  function markEditableElements() {
    document.querySelectorAll(Array.from(EDITABLE_TAGS).join(',')).forEach(el => {
      // Skip our own UI
      if (el.closest('#ucms-toolbar') || el.closest('#ucms-config-overlay') || el.closest('#ucms-result-overlay')) return;
      // Must have visible text
      if (el.textContent.trim().length < 2) return;
      // Skip purely structural elements (contains block-level children)
      const hasBlockChild = Array.from(el.children).some(c => !EDITABLE_TAGS.has(c.tagName));
      if (hasBlockChild) return;

      el.dataset.ucmsId = nextId++;
      el.dataset.ucmsOriginal = el.innerHTML;
    });
  }

  markEditableElements();

  // ============================================
  // CAPTURE RICH CONTEXT FOR EACH ELEMENT
  // ============================================

  function getDomPath(el) {
    const parts = [];
    let node = el;
    while (node && node !== document.body) {
      let selector = node.tagName.toLowerCase();
      if (node.id) {
        selector += '#' + node.id;
      } else if (node.className && typeof node.className === 'string') {
        const classes = node.className.trim().split(/\s+/).filter(c => !c.startsWith('ucms'));
        if (classes.length) selector += '.' + classes.join('.');
      }
      parts.unshift(selector);
      node = node.parentElement;
    }
    return parts.join(' > ');
  }

  function getElementContext(el) {
    const parent = el.parentElement;
    const siblings = parent
      ? Array.from(parent.children)
          .filter(c => c !== el && c.textContent.trim().length > 0)
          .slice(0, 3)
          .map(c => c.textContent.trim().substring(0, 80))
      : [];

    // Find the closest section/landmark
    const section = el.closest('section, article, header, footer, main, nav, aside');
    const sectionInfo = section ? {
      tag: section.tagName.toLowerCase(),
      id: section.id || null,
      class: section.className || null,
      // First heading in this section for extra context
      heading: section.querySelector('h1,h2,h3,h4')?.textContent.trim().substring(0, 80) || null,
    } : null;

    return {
      tag: el.tagName.toLowerCase(),
      id: el.id || null,
      classes: (el.className && typeof el.className === 'string')
        ? el.className.trim().split(/\s+/).filter(c => !c.startsWith('ucms'))
        : [],
      dom_path: getDomPath(el),
      parent_tag: parent ? parent.tagName.toLowerCase() : null,
      parent_classes: (parent?.className && typeof parent.className === 'string')
        ? parent.className.trim().split(/\s+/).filter(c => !c.startsWith('ucms'))
        : [],
      sibling_texts: siblings,
      section: sectionInfo,
      href: el.tagName === 'A' ? el.getAttribute('href') : null,
    };
  }

  // ============================================
  // EDITING BEHAVIOR
  // ============================================

  // Prevent link navigation
  document.addEventListener('click', (e) => {
    const link = e.target.closest('a');
    if (link && link.dataset.ucmsId !== undefined) e.preventDefault();
  }, true);

  // Prevent form submissions
  document.addEventListener('submit', (e) => e.preventDefault(), true);

  // Click to edit
  document.addEventListener('click', (e) => {
    // Ignore clicks on our UI
    if (e.target.closest('#ucms-toolbar') || e.target.closest('#ucms-config-overlay') || e.target.closest('#ucms-result-overlay')) return;

    // Find deepest editable element
    let target = e.target;
    while (target && target.dataset?.ucmsId === undefined) {
      target = target.parentElement;
    }
    if (!target) return;
    e.preventDefault();

    // Deactivate others
    document.querySelectorAll('[contenteditable="true"]').forEach(el => {
      el.contentEditable = false;
    });

    target.contentEditable = true;
    target.focus();
  });

  // Blur — track changes
  document.addEventListener('focusout', (e) => {
    const target = e.target.closest('[data-ucms-id]');
    if (!target) return;
    target.contentEditable = false;

    const current = target.innerHTML;
    const original = target.dataset.ucmsOriginal;

    if (current !== original) {
      target.dataset.ucmsChanged = 'true';
      changes.set(target.dataset.ucmsId, {
        old_html: original,
        new_html: current,
        old_text: textFromHtml(original),
        new_text: target.textContent.trim(),
        context: getElementContext(target),
      });
    } else {
      delete target.dataset.ucmsChanged;
      changes.delete(target.dataset.ucmsId);
    }

    updateBadge();
  });

  function textFromHtml(html) {
    const tmp = document.createElement('div');
    tmp.innerHTML = html;
    return tmp.textContent.trim();
  }

  function updateBadge() {
    const badge = document.getElementById('ucms-badge');
    const btn = document.getElementById('ucms-submit-btn');
    const status = document.getElementById('ucms-status');
    const count = changes.size;

    badge.textContent = count;
    badge.style.display = count > 0 ? 'inline' : 'none';
    btn.disabled = count === 0;
    status.textContent = count > 0
      ? `${count} change${count > 1 ? 's' : ''} pending`
      : 'Click any text to edit';
  }

  // ============================================
  // TOOLBAR ACTIONS
  // ============================================

  document.getElementById('ucms-settings-btn').addEventListener('click', () => {
    configOverlay.classList.add('open');
  });

  document.getElementById('ucms-config-save').addEventListener('click', () => {
    config.api_url = document.getElementById('ucms-api-url').value.trim();
    config.repo = document.getElementById('ucms-repo').value.trim();
    config.branch = document.getElementById('ucms-branch').value.trim() || 'main';
    config.github_token = document.getElementById('ucms-github-token').value.trim();
    localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
    configOverlay.classList.remove('open');
  });

  document.getElementById('ucms-cancel-btn').addEventListener('click', () => {
    // Remove toolbar and reload
    toolbar.remove();
    configOverlay.remove();
    resultOverlay.remove();
    location.reload();
  });

  document.getElementById('ucms-submit-btn').addEventListener('click', submitChanges);

  // Show config if not configured
  if (!config.api_url || !config.repo || !config.github_token) {
    configOverlay.classList.add('open');
  }

  // ============================================
  // SUBMIT CHANGES TO BACKEND
  // ============================================

  async function submitChanges() {
    if (changes.size === 0) return;

    // Validate config
    if (!config.api_url || !config.site_key) {
      alert('UltimateCMS: Missing configuration. Add the embed script with data-site attribute.');
      return;
    }

    const resultPanel = document.getElementById('ucms-result-panel');
    resultPanel.innerHTML = `
      <h3>Submitting changes...</h3>
      <div class="ucms-spinner"></div>
      <p>The AI agent is analyzing your codebase and creating a pull request.</p>
    `;
    resultOverlay.classList.add('open');

    // Build payload with full context — no sensitive info, just the site key
    const payload = {
      site_key: config.site_key,
      page: {
        url: location.href,
        path: location.pathname,
        title: document.title,
      },
      changes: Array.from(changes.values()),
    };

    try {
      const res = await fetch(`${config.api_url}/api/edit`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${config.session_token}`,
        },
        body: JSON.stringify(payload),
      });

      const data = await res.json();

      if (data.pr_url) {
        resultPanel.innerHTML = `
          <h3 style="color:#34D399">Pull request created!</h3>
          <p>Your changes have been submitted as a pull request. Review and merge when ready.</p>
          <a href="${data.pr_url}" target="_blank" rel="noopener">${data.pr_url}</a>
          <br><br>
          <button class="ucms-btn" onclick="document.getElementById('ucms-result-overlay').classList.remove('open'); location.reload();">Close</button>
        `;
      } else {
        throw new Error(data.error || 'Unknown error');
      }
    } catch (err) {
      resultPanel.innerHTML = `
        <h3 style="color:#F87171">Error</h3>
        <p>${err.message}</p>
        <button class="ucms-btn" onclick="document.getElementById('ucms-result-overlay').classList.remove('open')">Close</button>
      `;
    }
  }

})();
