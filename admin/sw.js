// Service worker mínimo: solo habilita que el panel se pueda "instalar"
// como app de escritorio. No guarda nada offline a propósito: el panel
// necesita internet para leer/guardar en Supabase, así que cachear
// respuestas viejas generaría más confusión que ayuda.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request));
});
