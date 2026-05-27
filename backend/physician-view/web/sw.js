// sw.js — Service Worker for physician-view web app.
//
// Strategy:
//   • App shell (HTML/CSS/JS): cache-first after first load → offline capable.
//   • API calls (/api/card, /clinician, /proxy/): network-only — NEVER cached.
//     Patient data must not be persisted in any browser storage.
//   • /healthz: network-only.
//
// Cache name is versioned. Old caches are purged on activate.

'use strict';

const CACHE_VERSION = 'nbh-pv-v1';
const SHELL_ASSETS  = [
  '/emergency.html',
  '/forensic.html',
  '/css/main.css',
  '/js/i18n.js',
  '/js/app.js',
  '/js/qr.js',
];

// Paths that must NEVER be cached (patient data).
const NETWORK_ONLY = ['/api/', '/clinician', '/proxy/', '/scan', '/healthz'];

// ── Install: pre-cache the app shell ──────────────────────────
self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(CACHE_VERSION).then(function (cache) {
      return cache.addAll(SHELL_ASSETS);
    }).then(function () {
      return self.skipWaiting();
    })
  );
});

// ── Activate: purge old caches ─────────────────────────────────
self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(
        keys.filter(function (k) { return k !== CACHE_VERSION; })
            .map(function (k) { return caches.delete(k); })
      );
    }).then(function () {
      return self.clients.claim();
    })
  );
});

// ── Fetch: route requests ──────────────────────────────────────
self.addEventListener('fetch', function (event) {
  const url = new URL(event.request.url);

  // Only handle same-origin requests.
  if (url.origin !== self.location.origin) return;

  // Network-only paths — never cache, always fetch live.
  const isNetworkOnly = NETWORK_ONLY.some(function (prefix) {
    return url.pathname.startsWith(prefix);
  });
  if (isNetworkOnly) {
    event.respondWith(fetch(event.request));
    return;
  }

  // App shell: cache-first, fall back to network.
  event.respondWith(
    caches.match(event.request).then(function (cached) {
      if (cached) return cached;

      return fetch(event.request).then(function (response) {
        // Only cache successful GET responses for our own origin.
        if (
          response.ok &&
          event.request.method === 'GET' &&
          url.origin === self.location.origin
        ) {
          const clone = response.clone();
          caches.open(CACHE_VERSION).then(function (cache) {
            cache.put(event.request, clone);
          });
        }
        return response;
      }).catch(function () {
        // Offline and not in cache — serve a minimal offline page.
        return new Response(
          '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">' +
          '<title>Offline</title></head><body style="font-family:system-ui;' +
          'padding:2rem;text-align:center"><h1>⚠ Offline</h1>' +
          '<p>No network connection. The physician view requires network access ' +
          'to verify the QR token and log clinician access.</p></body></html>',
          { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
        );
      });
    })
  );
});
