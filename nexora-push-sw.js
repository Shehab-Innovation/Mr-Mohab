/* ============================================================
   NEXORA — N4 Push Service Worker (minimal, push-only)
   ============================================================
   Shows incoming web pushes and opens the notification's
   target_page on click. NO caching, NO PWA features (per N4).
   ============================================================ */

self.addEventListener('install', function (event) {
    self.skipWaiting();
});

self.addEventListener('activate', function (event) {
    event.waitUntil(self.clients.claim());
});

self.addEventListener('push', function (event) {
    var data = {};
    try {
        data = event.data ? event.data.json() : {};
    } catch (error) {
        data = { title: 'NEXORA', message: (event.data && event.data.text()) || '' };
    }

    var title = data.title || 'NEXORA';
    var body = data.message || data.body || '';

    event.waitUntil(
        self.registration.showNotification(title, {
            body: body,
            icon: data.icon,
            badge: data.badge,
            tag: data.tag,
            data: { targetPage: data.target_page || data.targetPage || null }
        })
    );
});

self.addEventListener('notificationclick', function (event) {
    var target = (event.notification.data && event.notification.data.targetPage) || '/';

    event.notification.close();

    event.waitUntil(
        self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clientList) {
            for (var i = 0; i < clientList.length; i += 1) {
                var client = clientList[i];
                var sameOrigin = new URL(client.url).origin === self.location.origin;
                if (sameOrigin && 'focus' in client) {
                    client.focus();
                    if (target && target !== '/') {
                        client.navigate(client.url.split('#')[0].split('?')[0] + '#nxpage=' + target);
                    }
                    return;
                }
            }
            return self.clients.openWindow(target && target !== '/' ? ('/?nxpage=' + target) : '/');
        })
    );
});
