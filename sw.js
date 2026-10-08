/* Cache de l'appli : elle se lance sans reseau une fois installee.
   A chaque mise a jour, change le numero de VERSION : les anciens
   fichiers sont alors effaces et les nouveaux telecharges. */
const VERSION = 'poker-v21';
const FICHIERS = ['./', './index.html', './cotes.html', './supabase.js',
  './config.js', './reseau.js', './manifest.json',
  './icone-192.png', './icone-512.png', './apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(FICHIERS)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET') return;
  /* le temps reel ne doit jamais passer par le cache */
  if (u.origin !== location.origin) return;
  e.respondWith(
    fetch(e.request)
      .then(r => { const c = r.clone(); caches.open(VERSION).then(x => x.put(e.request, c)); return r; })
      .catch(() => caches.match(e.request).then(r => r || caches.match('./index.html')))
  );
});
