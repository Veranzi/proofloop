// Web push for Pruflo (lib/core/push_service.dart).
//
// The Firebase SDK registers this file when the app asks for a push token;
// without it, getToken fails and no browser can be registered. It shows the
// notification the API sends through FCM and opens its link when clicked.
//
// It reads FCM's push payload directly instead of loading the Firebase SDK,
// so it needs no Firebase config: that config only exists as --dart-define
// values at build time, which a static service worker can't see.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    return;
  }
  const notification = payload.notification || {};
  const data = payload.data || {};
  const link = (payload.fcmOptions && payload.fcmOptions.link) || data.link || '/';
  event.waitUntil(
    self.registration.showNotification(notification.title || 'Pruflo', {
      body: notification.body || '',
      icon: 'icons/Icon-192.png',
      tag: payload.fcmMessageId,
      data: { link },
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  let target = new URL(event.notification.data.link, self.location.origin);
  // Only open pages of this app (the API's link may name another of its domains).
  if (target.origin !== self.location.origin) {
    target = new URL(target.pathname + target.search + target.hash, self.location.origin);
  }
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
      const open = windows.find((c) => new URL(c.url).origin === target.origin);
      if (!open) return self.clients.openWindow(target.href);
      // navigate() only works on pages this worker controls, and Flutter's own
      // worker controls the app, so fall back to a new tab.
      return open
        .focus()
        .then((c) => c.navigate(target.href))
        .catch(() => self.clients.openWindow(target.href));
    }),
  );
});
