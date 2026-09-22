/* ============================================================
   NEXORA — Web Push (Phase N4) — config + enable flow
   ============================================================
   Public-only file: contains the VAPID PUBLIC key (safe for
   browsers) and NO secrets. Loaded by teacher-dashboard.html
   and index.html only.
   ============================================================ */

(function (global) {
    'use strict';

    var NEXORA_PUSH = {

        /* VAPID public key (base64url, uncompressed P-256 point). */
        vapidPublicKey: 'BGmuNvmKuA5MhpdKxLSuQh1CSNgrgi4i2VqQjJtElHNrDvAKckfw_RZvuka8HDVkcqsbuCDoDaaeju-Vlm75mLM',

        /* N4 service worker path (same origin). */
        /* N4 service worker path (same origin).
           RELATIVE on purpose: GitHub Pages serves project repos
           under a sub-path (/Mr-Mohab/) - an absolute path 404s. */
        swPath: './nexora-push-sw.js',

        /* Supabase Edge Function that sends the actual web push.
           Reachable via the public REST gateway with the anon key. */
        senderFnPath: '/functions/v1/nx_push_sender',

        /* Inactive-teacher identity guard: matches teacher-login.html. */
        teacherDisabledPage: '/teacher-login.html?disabled=1',

        /* Convert base64url -> Uint8Array (browser safe). */
        urlBase64ToUint8Array: function (base64String) {
            var padding = '='.repeat((4 - (base64String.length % 4)) % 4);
            var base64 = (base64String + padding)
                .replace(/-/g, '+')
                .replace(/_/g, '/');
            var raw = window.atob(base64);
            var output = new Uint8Array(raw.length);
            for (var i = 0; i < raw.length; i += 1) {
                output[i] = raw.charCodeAt(i);
            }
            return output;
        },

        /* Register the N4 service worker (idempotent). */
        registerServiceWorker: function () {
            return navigator.serviceWorker.register(this.swPath);
        },

        /* Full enable flow. Caller supplies two hooks so this module
           stays completely UI-free:
             hooks.resolveTeacherToken() -> Promise<string|null>
             hooks.saveSubscription(recipientType, endpoint, p256dh, auth)
                 -> Promise (throws on failure) */
        enablePush: function (hooks) {
            var self = this;

            if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
                return Promise.reject(new Error('UNSUPPORTED_BROWSER'));
            }

            return Notification.requestPermission()
                .then(function (permission) {
                    if (permission !== 'granted') {
                        throw new Error('PERMISSION_DENIED');
                    }
                    return self.registerServiceWorker();
                })
                .then(function (registration) {
                    return registration.pushManager.subscribe({
                        userVisibleOnly: true,
                        applicationServerKey: self.urlBase64ToUint8Array(self.vapidPublicKey)
                    });
                })
                .then(function (subscription) {
                    var json = subscription.toJSON();
                    var keys = json.keys || {};
                    if (!json.endpoint || !keys.p256dh || !keys.auth) {
                        throw new Error('BAD_SUBSCRIPTION');
                    }
                    return hooks.saveSubscription(
                        json.endpoint,
                        keys.p256dh,
                        keys.auth
                    );
                });
        }
    };

    global.NEXORA_PUSH = NEXORA_PUSH;

}(window));
