// Pass-through service worker.
//
// It exists so the panel is installable (and opens fullscreen), not to cache
// anything: Cleat is a live tool, so every request keeps going to the network
// and no stale asset or page is ever served.
self.addEventListener("install", () => self.skipWaiting())

self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))

self.addEventListener("fetch", () => {})
