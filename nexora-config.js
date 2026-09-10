/* ============================================================
   NEXORA — Teacher Identity Configuration (single source)
   ============================================================
   This is the ONLY place a teacher instance's identity and
   branding data should be changed. Shehab Innovation owns NEXORA
   core; this file is the per-teacher (tenant) config layer.

   - Presentation-only: this file never alters quiz logic,
     timers, navigation, registration, storage keys, or themes.
   - Every value is a FALLBACK for existing hardcoded markup.
     Nothing breaks if this file fails to load.
   - Future phases: values here can be overridden by the
     teacher_identity table (server-side) without touching HTML.
   ============================================================ */

(function (global) {
    'use strict';

    /* ---------------- Teacher identity (edit here only) ---------------- */

    var NEXORA_CONFIG = {

        /* Tenant identity — must match the `teachers` row
           (`teacher_id` / `username`) created in Phase 1 migration. */
        teacher: {
            teacher_id: 'T-MOHAB-001',
            username:   'mr-mohab',

            /* Display identity */
            name:      'مستر مهاب',
            subject:   'الرياضيات',
            stage:     'المرحلة الابتدائية',

            /* Grades offered (keys match gradesData + gradeSelect) */
            grades: [1, 2, 3, 4, 5, 6],

            /* Branding */
            image: 'https://i.ibb.co/HfRP5zx8/Whats-App-Image-2026-09-03-at-3-34-26-AM.jpg',
            hero_image: 'https://i.ibb.co/xtmG53Lr/Whats-App-Image-2026-09-03-at-3-34-26-AM-1.jpg',

            /* Contact */
            whatsapp: 'https://wa.me/+201289958954',
            facebook: 'https://www.facebook.com/share/1Dup2hS5YH/',

            /* Certificate identity (student site) */
            certificate: {
                teacher_name:  'مستر مهاب',
                teacher_image: 'https://i.ibb.co/HfRP5zx8/Whats-App-Image-2026-09-03-at-3-34-26-AM.jpg',
                message:       'أحسنت! استمر في التفوق والمثابرة.'
            }
        }
    };

    /* ---------------- Public accessor (read-only) ---------------- */

    global.NEXORA_CONFIG = NEXORA_CONFIG;

    global.nexoraConfig = {
        get: function () {
            return NEXORA_CONFIG;
        },
        teacher: function () {
            return NEXORA_CONFIG.teacher;
        }
    };

    /* ---------------- Presentation-only hydration ----------------
       Fills placeholders in existing markup that already use them.
       Elements WITHOUT data-nexora-hydrate are never touched, so
       current hardcoded values remain the safe fallback. */

    function hydrate() {

        var t =
            NEXORA_CONFIG.teacher;

        /* Page title (presentation-only) */

        if (document.title && document.title.indexOf('NEXORA') === 0) {

            document.title =
                'NEXORA | ' + t.name;

        }

        var root =
            document.querySelector('[data-nexora-hydrate]');

        if (!root)
            return;

        var t =
            NEXORA_CONFIG.teacher;

        var fields = {

            name:
                t.name,

            subject:
                t.subject,

            stage:
                t.stage,

            whatsapp:
                t.whatsapp,

            facebook:
                t.facebook,

            image:
                t.image,

            'image-hero':
                t.hero_image,

            'subject-stage':
                'مدرس ' + t.subject + ' – ' + t.stage,

            'cert-name':
                t.certificate.teacher_name,

            'cert-image':
                t.certificate.teacher_image

        };

        Array.prototype.forEach.call(

            root.querySelectorAll('[data-nexora-hydrate]'),

            function (el) {

                var key =
                    el.getAttribute('data-nexora-hydrate');

                var value =
                    fields[key];

                if (value === undefined || value === null)
                    return;

                if (key === 'whatsapp' || key === 'facebook') {

                    if (el.tagName !== 'A')
                        return;

                    el.setAttribute('href', value);

                    return;

                }

                if (key === 'image' || key === 'image-hero' || key === 'cert-image') {

                    if (el.tagName !== 'IMG')
                        return;

                    el.src = value;

                    return;

                }

                el.textContent =
                    String(value);

            }

        );

    }

    if (document.readyState === 'loading') {

        document.addEventListener(
            'DOMContentLoaded',
            hydrate
        );

    }
    else {

        hydrate();

    }

})(window);
