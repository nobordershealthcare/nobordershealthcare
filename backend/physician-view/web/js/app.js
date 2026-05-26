// app.js — physician-view SPA
//
// Security invariants (enforced below):
//   • Token lives only in module-scoped variable — NEVER localStorage/sessionStorage
//   • Card data cleared after 15-minute JWT TTL
//   • Blur overlay on window focus loss
//   • beforeunload clears sensitive state
//   • All user-supplied strings HTML-escaped before innerHTML
//   • Hash fragment never sent to server (token read from location.hash client-side)
//
// Flow:
//   1. Extract token from URL hash (or legacy query string → rewrite to hash)
//   2. Decode JWT claims client-side for lang/profile (no crypto — server verifies)
//   3. Show clinician verification gate (no card data visible yet)
//   4. POST /clinician → success → GET /api/card?token= → render card
//   5. Start 15-min expiry timer; blur overlay on focus loss

'use strict';

(function () {

  // ── Module state — NEVER persisted to storage ──────────────
  let _token    = null;   // raw JWT string
  let _claims   = null;   // decoded (unverified) JWT payload
  let _cardData = null;   // server-verified card response
  let _lang     = 'en';   // active UI language
  let _view     = 'emergency'; // 'emergency' | 'forensic'
  let _expiryHandle  = null;
  let _countdownHandle = null;

  const JWT_TTL_MS       = 15 * 60 * 1000;  // 15 minutes
  const WARN_THRESHOLD_S = 120;              // show warning at <2 min

  // ── Entry point ─────────────────────────────────────────────
  document.addEventListener('DOMContentLoaded', function () {
    _view = document.body.dataset.view || 'emergency';
    init();
  });

  function init() {
    setupFocusGuard();
    setupBeforeUnload();

    _token = extractToken();

    if (!_token) {
      showError('err_no_token');
      return;
    }

    // Decode JWT payload client-side (unsigned; server validates crypto).
    // Used only for lang preference and profile badge before the API call.
    _claims = parseJWTPayload(_token);
    if (!_claims) {
      showError('err_invalid');
      return;
    }

    // Detect language early so the verification gate is already localised.
    _lang = window.i18n.detectLang(_claims.lang);

    // Localise the document title
    document.title = t('card_title') + ' — noborders';

    if (_view === 'forensic') {
      renderForensicGate();
    } else {
      renderVerificationGate();
    }
  }

  // ── Token extraction ─────────────────────────────────────────
  // Prefer URL hash (never sent to server).
  // Legacy: if token is in query string, rewrite URL to hash immediately.
  function extractToken() {
    // Hash: #token=JWT  or  #token=JWT&other=...
    const hashMatch = location.hash.match(/[#&]token=([^&]+)/);
    if (hashMatch) return decodeURIComponent(hashMatch[1]);

    // Legacy query string (old QR format): ?token=JWT
    const queryMatch = location.search.match(/[?&]token=([^&]+)/);
    if (queryMatch) {
      const tok = decodeURIComponent(queryMatch[1]);
      // Rewrite to hash so token is no longer sent to server on reload
      try {
        history.replaceState(null, '', '/#token=' + encodeURIComponent(tok));
      } catch (_) {}
      return tok;
    }

    return null;
  }

  // ── JWT payload decode (base64url, no signature check) ──────
  // Signature verification happens server-side on /api/card.
  function parseJWTPayload(token) {
    try {
      const parts = token.split('.');
      if (parts.length !== 3) return null;
      // base64url → base64 → JSON
      const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
      const json = decodeURIComponent(
        atob(b64).split('').map(c =>
          '%' + c.charCodeAt(0).toString(16).padStart(2, '0')
        ).join('')
      );
      return JSON.parse(json);
    } catch (_) {
      return null;
    }
  }

  // ── i18n shorthand ───────────────────────────────────────────
  function t(key) { return window.i18n.t(key, _lang); }

  // ── HTML escape (all untrusted strings go through this) ─────
  function esc(s) {
    if (s == null) return '';
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // ── View switcher ────────────────────────────────────────────
  function showView(id) {
    document.querySelectorAll('.view').forEach(function (el) {
      el.classList.toggle('active', el.id === id);
    });
  }

  // ── Error display ────────────────────────────────────────────
  function showError(key, detail) {
    showView('view-error');
    const title = document.getElementById('error-title');
    const msg   = document.getElementById('error-msg');
    if (title) title.textContent = t('expired_title').includes('Exp') ? '⚠ Error' : '⚠';
    if (msg)   msg.textContent   = t(key) + (detail ? ' (' + detail + ')' : '');
  }

  // ── Verification gate ─────────────────────────────────────────
  function renderVerificationGate() {
    const container = document.getElementById('view-verify');
    if (!container) return;

    container.innerHTML = [
      '<div class="wrapper">',
      '<div class="verify-card">',

      // Logo
      '<div class="verify-logo">',
      '  <div class="verify-logo-icon">🏥</div>',
      '  <span class="verify-logo-text">noborders health</span>',
      '</div>',

      // Heading
      '<h1>' + esc(t('verify_heading')) + '</h1>',
      '<p class="subtext">' + esc(t('verify_subtext')) + '</p>',

      // Form
      '<form id="verify-form" novalidate>',

      // License input
      '<div class="field" id="field-license">',
      '  <label for="inp-license">' + esc(t('license_label')) + '</label>',
      '  <input type="text" id="inp-license" name="license"',
      '         placeholder="' + esc(t('license_ph')) + '"',
      '         autocomplete="off" spellcheck="false"',
      '         inputmode="text" required>',
      '  <div class="field-error" id="err-license">' + esc(t('err_license')) + '</div>',
      '</div>',

      // Country selector
      '<div class="field" id="field-country">',
      '  <label for="inp-country">' + esc(t('country_label')) + '</label>',
      '  <select id="inp-country" name="country" required>',
      '    <option value="">—</option>',
      '    <option value="PT">' + esc(t('country_pt')) + '</option>',
      '    <option value="DE">' + esc(t('country_de')) + '</option>',
      '    <option value="UA">' + esc(t('country_ua')) + '</option>',
      '    <option value="EU">' + esc(t('country_eu')) + '</option>',
      '    <option value="ATLAS">' + esc(t('country_atlas')) + '</option>',
      '  </select>',
      '  <div class="field-error" id="err-country">Select a country.</div>',
      '</div>',

      // Submit
      '<button type="submit" class="btn btn-primary" id="verify-btn">',
      '  <span class="btn-label">' + esc(t('submit_verify')) + '</span>',
      '  <span class="btn-spinner" aria-hidden="true"></span>',
      '</button>',

      // QR scanner button (desktop)
      typeof BarcodeDetector !== 'undefined'
        ? '<button type="button" class="btn btn-secondary mt-1 no-print" id="qr-scan-btn">' + esc(t('scan_btn')) + '</button>'
        : '',

      '</form>',
      '</div>', // verify-card
      '</div>', // wrapper
    ].join('\n');

    document.getElementById('verify-form')
      .addEventListener('submit', handleVerificationSubmit);

    const scanBtn = document.getElementById('qr-scan-btn');
    if (scanBtn) scanBtn.addEventListener('click', function () {
      window.QRScanner && window.QRScanner.open(function (result) {
        if (result) {
          _token = result;
          _claims = parseJWTPayload(_token);
          if (_claims) {
            try { history.replaceState(null, '', '/#token=' + encodeURIComponent(_token)); } catch (_) {}
            _lang = window.i18n.detectLang(_claims.lang);
            renderVerificationGate();
          }
        }
      });
    });

    showView('view-verify');
  }

  // ── Verification submit ───────────────────────────────────────
  async function handleVerificationSubmit(e) {
    e.preventDefault();

    const licenseInput = document.getElementById('inp-license');
    const countryInput = document.getElementById('inp-country');
    const btn          = document.getElementById('verify-btn');

    const license = licenseInput ? licenseInput.value.trim() : '';
    const country = countryInput ? countryInput.value.trim() : '';

    // Client-side validation
    let valid = true;
    if (!license) {
      document.getElementById('field-license').classList.add('has-error');
      valid = false;
    } else {
      document.getElementById('field-license').classList.remove('has-error');
    }
    if (!country) {
      document.getElementById('field-country').classList.add('has-error');
      valid = false;
    } else {
      document.getElementById('field-country').classList.remove('has-error');
    }
    if (!valid) return;

    // Show loading state
    if (btn) btn.classList.add('loading');

    try {
      // Step 1: Log clinician access (POST /clinician)
      const subRef = _claims ? safeRef(_claims.sub) : '';
      const jti    = _claims ? (_claims.jti || '') : '';

      const fd = new FormData();
      fd.append('license',     license);
      fd.append('country',     country);
      fd.append('jti',         jti);
      fd.append('patient_sub', subRef);

      const logResp = await fetch('/clinician', {
        method: 'POST',
        body: fd,
      });

      if (!logResp.ok) {
        const errText = await logResp.text().catch(function () { return ''; });
        if (logResp.status === 422) {
          document.getElementById('field-license').classList.add('has-error');
          document.getElementById('err-license').textContent = t('err_license');
          return;
        }
        if (logResp.status === 503) {
          showError('err_logged_fail');
          return;
        }
        showError('err_generic', String(logResp.status));
        return;
      }

      // Step 2: Fetch verified card data (GET /api/card?token=)
      const cardResp = await fetch(
        '/api/card?token=' + encodeURIComponent(_token),
        { headers: { 'Accept': 'application/json' } }
      );

      if (!cardResp.ok) {
        const errBody = await cardResp.json().catch(function () { return {}; });
        const errCode = (errBody && errBody.error) || '';
        if (errCode === 'expired' || cardResp.status === 410)  { showError('err_expired');  return; }
        if (errCode === 'revoked'  || cardResp.status === 403)  { showError('err_revoked');  return; }
        if (cardResp.status === 401)                            { showError('err_invalid');  return; }
        showError('err_generic', String(cardResp.status));
        return;
      }

      _cardData = await cardResp.json();

      // Clear token from memory now that we have the card data.
      // The token is still in location.hash for the duration of the session,
      // but we won't read it again unless the page reloads.
      _token = null;

      renderCard(_cardData);

    } catch (err) {
      if (!navigator.onLine || (err instanceof TypeError && err.message.includes('fetch'))) {
        showError('err_network');
      } else {
        showError('err_generic');
      }
    } finally {
      if (btn) btn.classList.remove('loading');
    }
  }

  // ── Render emergency card ─────────────────────────────────────
  function renderCard(data) {
    const profile   = (data.profile || 'civilian').toLowerCase();
    const isMilitary    = profile === 'military';
    const isGendarmerie = profile === 'gendarmerie';
    const isCovert      = profile === 'covert';
    const isMil = isMilitary || isGendarmerie || isCovert;

    const container = document.getElementById('view-card');
    if (!container) return;

    // Profile badge label
    let profileBadgeHTML = '';
    if (isMilitary)    profileBadgeHTML = '<span class="profile-badge military">' + esc(t('profile_military')) + '</span>';
    if (isGendarmerie) profileBadgeHTML = '<span class="profile-badge gendarmerie">' + esc(t('profile_gendarmerie')) + '</span>';
    if (isCovert)      profileBadgeHTML = '<span class="profile-badge covert">' + esc(t('profile_covert')) + '</span>';

    // Expiry
    const expUnix = data.exp_unix || 0;
    const expStr  = data.exp || '';

    // Blood badge (always shown, even in covert — critical for emergency care)
    const bloodHTML = data.blood
      ? '<div class="blood-badge-hero">' +
        '  <span class="blood-label-small">' + esc(t('blood_label')) + '</span>' +
        esc(data.blood) +
        '</div>'
      : '';

    // Identity section (hidden in covert until duty officer verification)
    let identityHTML = '';
    if (isCovert) {
      identityHTML = [
        '<div class="section">',
        '  <div class="section-label">' + esc(t('name_label')) + '</div>',
        '  <div class="identity-locked-banner">' + esc(t('identity_locked')) + '</div>',
        '</div>',
      ].join('\n');
    } else {
      identityHTML = [
        '<div class="section">',
        '  <div class="section-label">' + esc(t('name_label')) + '</div>',
        '  <dl class="identity-grid">',
        '    <div class="id-item">',
        '      <dt>' + esc(t('name_label')) + '</dt>',
        '      <dd>' + esc(data.name || '—') + '</dd>',
        '    </div>',
        '    <div class="id-item">',
        '      <dt>' + esc(t('dob_label')) + '</dt>',
        '      <dd>' + esc(data.dob || '—') + '</dd>',
        '    </div>',
        '    <div class="id-item">',
        '      <dt>' + esc(t('patient_ref')) + '</dt>',
        '      <dd><code class="ref-code">' + esc(data.sub_ref || '—') + '…</code></dd>',
        '    </div>',
        '  </dl>',
        '</div>',
      ].join('\n');
    }

    // Allergies section
    const allergies = Array.isArray(data.allergies) ? data.allergies : [];
    const allergiesHTML = [
      '<div class="section">',
      '  <div class="section-label">' + esc(t('allergies_label')) + '</div>',
      allergies.length > 0
        ? '<div class="chip-list">' +
          allergies.map(function (a) { return '<span class="chip">' + esc(a) + '</span>'; }).join('') +
          '</div>'
        : '<span class="none-text">' + esc(t('no_allergies')) + '</span>',
      '</div>',
    ].join('\n');

    // Medications section
    const meds = Array.isArray(data.medications) ? data.medications : [];
    let medsHTML;
    if (meds.length === 0) {
      medsHTML = [
        '<div class="section">',
        '  <div class="section-label">' + esc(t('medications_label')) + '</div>',
        '  <span class="none-text">' + esc(t('no_medications')) + '</span>',
        '</div>',
      ].join('\n');
    } else {
      const rows = meds.map(function (m) {
        return [
          '<tr>',
          '  <td>' + esc(m.name || m.generic_name || '—') + '</td>',
          '  <td>' + esc(m.dose || '—') + '</td>',
          '  <td class="col-freq">' + esc(m.freq || m.frequency || '—') + '</td>',
          '  <td>' + (m.atc ? '<code class="atc-pill">' + esc(m.atc) + '</code>' : '') + '</td>',
          '</tr>',
        ].join('');
      }).join('\n');

      medsHTML = [
        '<div class="section">',
        '  <div class="section-label">' + esc(t('medications_label')) + '</div>',
        '  <table class="med-table">',
        '    <thead><tr>',
        '      <th>' + esc(t('col_medication')) + '</th>',
        '      <th>' + esc(t('col_dose')) + '</th>',
        '      <th class="col-freq">' + esc(t('col_freq')) + '</th>',
        '      <th>' + esc(t('col_atc')) + '</th>',
        '    </tr></thead>',
        '    <tbody>' + rows + '</tbody>',
        '  </table>',
        '</div>',
      ].join('\n');
    }

    // Military extras (NOK + CBRN)
    let militaryHTML = '';
    if (isMil && (data.nok || data.cbrn)) {
      const nokParts = [];
      if (data.nok) {
        if (data.nok.unit_ref)    nokParts.push('<dt>' + esc(t('nok_label')) + ' (unit)</dt><dd>' + esc(data.nok.unit_ref) + '</dd>');
        if (data.nok.duty_contact) nokParts.push('<dd>' + esc(data.nok.duty_contact) + '</dd>');
        if (data.nok.protocol)     nokParts.push('<dd><code class="atc-pill">' + esc(data.nok.protocol) + '</code></dd>');
      }

      let cbrnHTML = '';
      if (data.cbrn) {
        const status  = (data.cbrn.status || 'unknown').toLowerCase();
        const cssClass = status === 'cleared' ? 'cbrn-cleared'
                       : status === 'precaution' ? 'cbrn-precaution'
                       : 'cbrn-unknown';
        cbrnHTML = [
          '<dt>' + esc(t('cbrn_label')) + '</dt>',
          '<dd><span class="cbrn-status ' + cssClass + '">' + esc(t('cbrn_' + status)) + '</span>',
          data.cbrn.last_checked ? ' <span class="text-muted" style="font-size:.78rem">' + esc(data.cbrn.last_checked) + '</span>' : '',
          '</dd>',
        ].join('');
      }

      militaryHTML = [
        '<div class="section">',
        '  <div class="military-section">',
        '    <div class="section-label">' + (isGendarmerie ? esc(t('profile_gendarmerie')) : esc(t('profile_military'))) + '</div>',
        '    <dl class="identity-grid">',
        nokParts.join(''),
        cbrnHTML,
        '    </dl>',
        '  </div>',
        '</div>',
      ].join('\n');
    }

    // Forensic button (military/gendarmerie only, not covert)
    const forensicBtnHTML = (isMilitary || isGendarmerie)
      ? '<div class="forensic-btn-wrap no-print">' +
        '<button class="btn btn-outline-red" id="forensic-nav-btn">' +
        esc(t('forensic_btn')) +
        '</button></div>'
      : '';

    // Access-logged banner
    const loggedHTML = '<div class="clinician-logged-banner no-print">' + esc(t('access_logged')) + '</div>';

    // Reference row
    const refHTML = [
      '<div class="section">',
      '  <div class="ref-row">',
      '    <span>' + esc(t('patient_ref')) + ': <code class="ref-code">' + esc(data.sub_ref || '—') + '</code></span>',
      '    <span>JTI: <code class="ref-code">' + esc(data.jti || '—') + '</code></span>',
      '  </div>',
      '</div>',
    ].join('\n');

    // Assemble card
    container.innerHTML = [
      '<div class="wrapper no-print-margin">',

      // Print heading (hidden on screen)
      '<div class="print-heading">' + esc(t('print_heading')) + '</div>',

      // Card header
      '<div class="card-header">',
      '  <div class="card-header-left">',
      profileBadgeHTML,
      '    <div class="card-header-icon">🏥</div>',
      '    <h1>' + esc(t('card_title')) + '</h1>',
      '    <div class="subtitle">' + esc(t('card_subtitle')) + '</div>',
      '  </div>',
      bloodHTML,
      '</div>',

      // Verified bar
      '<div class="verified-bar">',
      '  <span>' + esc(t('verified_badge')) + '</span>',
      '  <span class="expiry no-print" id="expiry-display">',
      '    <span>' + esc(t('expires_label')) + ': </span>',
      '    <span id="countdown" class="countdown">' + esc(expStr) + '</span>',
      '  </span>',
      '</div>',

      // Card body
      '<div class="card-body">',
      identityHTML,
      allergiesHTML,
      medsHTML,
      militaryHTML,
      refHTML,
      '</div>',

      // Disclaimer
      '<div class="disclaimer">' + esc(t('disclaimer')) + '</div>',

      // Actions (no-print)
      '<div class="action-bar no-print">',
      '  <button class="btn btn-secondary" onclick="window.print()">' + esc(t('print_btn')) + '</button>',
      data.proxy_link
        ? '<button class="proxy-link btn" id="proxy-btn">📄 ' + esc(t('proxy_link')) + '</button>'
        : '',
      '</div>',

      forensicBtnHTML,
      loggedHTML,

      '</div>', // wrapper
    ].join('\n');

    // Forensic nav
    const fnBtn = document.getElementById('forensic-nav-btn');
    if (fnBtn) {
      fnBtn.addEventListener('click', function () {
        // Navigate to forensic.html preserving the hash token.
        // The current hash still contains the original JWT (we cleared _token
        // from memory but left the hash for this navigation).
        const currentHash = location.hash || '';
        location.href = '/forensic.html' + currentHash;
      });
    }

    // Proxy link
    const proxyBtn = document.getElementById('proxy-btn');
    if (proxyBtn && data.proxy_link) {
      proxyBtn.addEventListener('click', function () {
        window.open('/proxy/' + encodeURIComponent(data.proxy_link), '_blank', 'noopener,noreferrer');
      });
    }

    showView('view-card');

    // Start expiry countdown timer
    if (expUnix) startExpiryTimer(expUnix);
  }

  // ── Forensic gate ─────────────────────────────────────────────
  function renderForensicGate() {
    // Same verification flow as emergency, but renders forensic view after.
    const container = document.getElementById('view-verify');
    if (!container) return;

    // Reuse the same verification gate HTML
    renderVerificationGate();

    // Override the submit handler to render forensic view
    const form = document.getElementById('verify-form');
    if (form) {
      form.removeEventListener('submit', handleVerificationSubmit);
      form.addEventListener('submit', async function (e) {
        e.preventDefault();
        // Run normal verification
        await handleVerificationSubmit(e);
        // After renderCard runs (it uses _cardData), overlay the forensic details
        if (_cardData) renderForensicOverlay(_cardData);
      });
    }
  }

  function renderForensicOverlay(data) {
    const container = document.getElementById('view-card');
    if (!container) return;

    const profile = (data.profile || 'civilian').toLowerCase();
    const isMil   = ['military', 'gendarmerie', 'covert'].includes(profile);

    // Build forensic-specific content
    const forensicHTML = [
      '<div class="wrapper">',
      '<div class="forensic-header">',
      '  <h1>' + esc(t('forensic_title')) + '</h1>',
      '  <div class="fh-sub">' + esc(t('forensic_subtitle')) + '</div>',
      '</div>',
      '<div class="card-body">',
      '  <div class="section">',
      '    <div class="forensic-locked">',
      '      <span class="lock-icon">🔒</span>',
      esc(t('forensic_locked_msg')).replace(/\n/g, '<br>'),
      '    </div>',
      '  </div>',

      // Blood + allergies are always shown (critical for emergency care)
      '  <div class="section">',
      '    <div class="section-label">' + esc(t('blood_label')) + '</div>',
      '    <span class="blood-badge-hero" style="font-size:2rem;display:inline-block">' + esc(data.blood || '?') + '</span>',
      '  </div>',

      data.allergies && data.allergies.length
        ? '<div class="section"><div class="section-label">' + esc(t('allergies_label')) + '</div>' +
          '<div class="chip-list">' +
          data.allergies.map(function (a) { return '<span class="chip">' + esc(a) + '</span>'; }).join('') +
          '</div></div>'
        : '',

      data.cbrn
        ? (function () {
            const s = (data.cbrn.status || 'unknown').toLowerCase();
            return '<div class="section"><div class="section-label">' + esc(t('cbrn_label')) + '</div>' +
              '<span class="cbrn-status cbrn-' + s + '">' + esc(t('cbrn_' + s)) + '</span></div>';
          })()
        : '',

      '  <div class="section">',
      '    <div class="ref-row">',
      '      <span>' + esc(t('patient_ref')) + ': <code class="ref-code">' + esc(data.sub_ref || '—') + '</code></span>',
      '    </div>',
      '  </div>',

      '</div>', // card-body
      '<div class="disclaimer">' + esc(t('disclaimer')) + '</div>',
      '<div class="action-bar no-print">',
      '  <button class="btn btn-secondary" onclick="window.print()">' + esc(t('print_btn')) + '</button>',
      '</div>',
      '</div>', // wrapper
    ].join('\n');

    container.innerHTML = forensicHTML;
    showView('view-card');
  }

  // ── Expiry countdown timer ────────────────────────────────────
  function startExpiryTimer(expUnix) {
    clearTimers();

    function tick() {
      const nowS       = Math.floor(Date.now() / 1000);
      const remaining  = expUnix - nowS;
      const display    = document.getElementById('countdown');
      const expiryBar  = document.getElementById('expiry-display');

      if (remaining <= 0) {
        clearTimers();
        clearSensitiveData();
        showExpiredOverlay();
        return;
      }

      if (display) {
        const mins = Math.floor(remaining / 60);
        const secs = remaining % 60;
        if (remaining > 60) {
          display.textContent = t('timer_label') + ' ' + mins + ' ' + t('timer_min') + ' ' + secs + t('timer_sec');
        } else {
          display.textContent = t('expiring_soon') + ' — ' + secs + t('timer_sec');
        }
      }

      if (expiryBar) {
        if (remaining <= WARN_THRESHOLD_S) {
          expiryBar.querySelector('.expiry') && expiryBar.querySelector('.expiry').classList.add('expiring-soon');
        }
      }
    }

    tick();
    _countdownHandle = setInterval(tick, 1000);

    // Hard-clear 1 second after expiry
    _expiryHandle = setTimeout(function () {
      clearTimers();
      clearSensitiveData();
      showExpiredOverlay();
    }, (expUnix - Math.floor(Date.now() / 1000) + 1) * 1000);
  }

  function clearTimers() {
    if (_expiryHandle)    { clearTimeout(_expiryHandle);   _expiryHandle   = null; }
    if (_countdownHandle) { clearInterval(_countdownHandle); _countdownHandle = null; }
  }

  // ── Expired overlay ───────────────────────────────────────────
  function showExpiredOverlay() {
    const overlay = document.getElementById('expired-overlay');
    if (overlay) overlay.classList.remove('hidden');
  }

  // ── Blur overlay (focus guard) ────────────────────────────────
  function setupFocusGuard() {
    const overlay = document.getElementById('blur-overlay');
    const msg     = document.getElementById('blur-msg');
    if (!overlay) return;

    function hide() { overlay.classList.add('hidden'); }
    function show() {
      if (msg) msg.textContent = t('blur_msg');
      overlay.classList.remove('hidden');
    }

    // visibilitychange is most reliable on mobile
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) show(); else hide();
    });

    // window blur/focus as fallback for desktop
    window.addEventListener('blur',  show);
    window.addEventListener('focus', hide);

    // Start hidden
    overlay.classList.add('hidden');
  }

  // ── Clear sensitive data (called on expiry and unload) ────────
  function clearSensitiveData() {
    _token    = null;
    _claims   = null;
    _cardData = null;
    clearTimers();
    // Remove hash from URL so token is not visible on back navigation
    try { history.replaceState(null, '', location.pathname); } catch (_) {}
  }

  function setupBeforeUnload() {
    window.addEventListener('beforeunload', function () {
      clearSensitiveData();
    });
    // Also clear on page hide (mobile — fires when tab goes to background for long)
    document.addEventListener('pagehide', function () {
      clearSensitiveData();
    });
  }

  // ── Helper: truncate sub to 16 chars (matches Go safeRef) ────
  function safeRef(sub) {
    if (!sub) return '';
    return String(sub).slice(0, 16);
  }

})();
