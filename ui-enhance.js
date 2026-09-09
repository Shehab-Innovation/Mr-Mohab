/* ============================================================
   NEXORA — Additive UI enhancement layer (presentation only)
   - Premium override stylesheet (kills deep-JS blue/light styles)
   - Welcome progress bar
   - Emoji → Font Awesome icon presentation sweep
   - Inline-style normalization for JS-generated cards
   Does NOT modify any existing logic, data, or Supabase calls.
   ============================================================ */

(function () {
    'use strict';

    /* ---------------- Premium override stylesheet ----------------
       Targets ONLY legacy hardcoded colors inside JS-generated
       templates (results list, certificate cards, muted text).
       Uses [style*=...] attribute selectors so no logic changes. */

    var OVERRIDE_CSS = [
        '',
        '/* ===== NEXORA premium presentation overrides (additive) ===== */',
        '',
        '/* JS-generated muted text (old #7b8495) */',
        '[style*="#7b8495"]{',
        '    color: var(--muted) !important;',
        '}',
        '',
        '/* Fill-in-the-blank quiz input (old light border) */',
        '#fillAnswer[style]{',
        '    border-color: var(--border-strong) !important;',
        '    background: var(--surface-2) !important;',
        '    color: var(--text) !important;',
        '}',
        '',
        '/* Results list rows (old light divider) */',
        '[style*="#eef2f7"]{',
        '    border-bottom-color: var(--border) !important;',
        '}',
        '',
        '/* Quiz option letter badges + selected states stay token-driven */',
        '.quiz-option[style*="background:#16a673"]{',
        '    background: var(--success) !important;',
        '}',
        '',
        '/* Success/Status accents in JS templates map to tokens */',
        '[style*="background:#16a673"]{',
        '    background: var(--success) !important;',
        '}',
        '[style*="color:#16a673"]{',
        '    color: var(--success) !important;',
        '}',
        '[style*="color:#ef4444"]{',
        '    color: var(--error) !important;',
        '}',
        '',
        '/* JS-generated certificate card (old blue border + white bg) */',
        '[style*="#1769e0"]{',
        '    border-color: var(--primary) !important;',
        '    background:',
        '        radial-gradient(420px 200px at 50% -30%, rgba(201,162,39,.14), transparent 70%),',
        '        var(--surface-2) !important;',
        '    box-shadow: var(--shadow-md) !important;',
        '}',
        '',
        '/* Unit content icons forced inline-blue (belt & braces) */',
        '.content-box i[style]{',
        '    color: var(--primary) !important;',
        '}',
        '',
        '/* Certificate inner headings inherit premium text tones */',
        '[style*="#1769e0"] h2,',
        '[style*="#1769e0"] h3,',
        '[style*="#1769e0"] p{',
        '    color: var(--text);',
        '}',
        '[style*="#1769e0"] h2 .brand-mark{',
        '    color: var(--accent);',
        '}',
        '',
        '/* Theme switcher sits on the cinematic sidebar in BOTH themes —',
        '   its hover text must stay warm-white even in light mode */',
        'html[data-theme="light"] .theme-switch button:hover{',
        '    color: #F5F1E6 !important;',
        '}',
        ''
    ].join('\n');

    function injectOverrideStyle() {

        if (document.getElementById('nexora-premium-overrides'))
            return;

        var styleEl =
            document.createElement('style');

        styleEl.id =
            'nexora-premium-overrides';

        styleEl.textContent =
            OVERRIDE_CSS;

        document.head.appendChild(
            styleEl
        );

    }

    /* Normalize inline styles directly on rendered certificate/result
       cards (DOM-level presentation only — template logic untouched). */

    function normalizeInlineStyles(root) {

        var stale = root.querySelectorAll('[style*="#1769e0"]');

        Array.prototype.forEach.call(stale, function (card) {

            card.style.borderColor = 'var(--primary)';

            card.style.background =
                'radial-gradient(420px 200px at 50% -30%, rgba(201,162,39,.14), transparent 70%), var(--surface-2)';

            card.style.boxShadow = 'var(--shadow-md)';

        });

        var muted = root.querySelectorAll('[style*="#7b8495"]');

        Array.prototype.forEach.call(muted, function (el) {

            el.style.color = 'var(--muted)';

        });

        var dividers = root.querySelectorAll('[style*="#eef2f7"]');

        Array.prototype.forEach.call(dividers, function (el) {

            el.style.borderBottomColor = 'var(--border)';

        });

        var fillInput =
            document.getElementById('fillAnswer');

        if (fillInput) {

            fillInput.style.borderColor = 'var(--border-strong)';

            fillInput.style.background = 'var(--surface-2)';

            fillInput.style.color = 'var(--text)';

        }

        var statusAccents = root.querySelectorAll(
            '[style*="background:#16a673"], [style*="color:#16a673"], [style*="color:#ef4444"]'
        );

        Array.prototype.forEach.call(statusAccents, function (el) {

            var s = el.style;

            if (s.background && s.background.indexOf('#16a673') !== -1)
                s.background = 'var(--success)';

            if (s.color === '#16a673')
                s.color = 'var(--success)';

            if (s.color === '#ef4444')
                s.color = 'var(--error)';

        });

    }

    /* ---------------- Welcome progress bar ---------------- */

    function refreshWelcomeProgress() {

        var avgEl =
            document.getElementById('welcomeAvg');

        var fillEl =
            document.getElementById('welcomeProgressFill');

        if (!avgEl || !fillEl)
            return;

        var results =
            (typeof getStudentResults === 'function')
                ? getStudentResults()
                : [];

        var pct =
            null;

        if (results.length > 0) {

            var total =
                results.reduce(

                    function (sum, result) {

                        return sum + (result.percentage || 0);

                    },

                    0
                );

            pct =
                Math.round(
                    total / results.length
                );

        }

        avgEl.textContent =
            pct === null
                ? '—'
                : pct + '%';

        fillEl.style.width =
            (pct === null ? 0 : pct) + '%';

    }

    /* ---------------- Emoji → icon sweep ----------------
       Strips leading decorative emoji from headings/labels
       and prepends a professional Font Awesome icon.
       Touches presentation only — never data or handlers. */

    var EMOJI_RE =
        /^[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]+/u;

    var ICON_MAP = [

        { key: 'تقييم',   icon: 'fa-chart-line'   },
        { key: 'شهاد',    icon: 'fa-award'        },
        { key: 'نتائج',   icon: 'fa-clipboard-check' },
        { key: 'مذكرة',   icon: 'fa-file-lines'   },
        { key: 'فيديو',   icon: 'fa-circle-play'  },
        { key: 'واجب',    icon: 'fa-pen-nib'      },
        { key: 'امتحان',  icon: 'fa-brain'        },
        { key: 'تواصل',   icon: 'fa-phone'        },
        { key: 'الصف',    icon: 'fa-graduation-cap' }

    ];

    function iconForText(text) {

        for (var i = 0; i < ICON_MAP.length; i++) {

            if (text.indexOf(ICON_MAP[i].key) !== -1) {

                return ICON_MAP[i].icon;

            }

        }

        return null;

    }

    function makeIcon(iconClass) {

        var el =
            document.createElement('i');

        el.className =
            'fas ' + iconClass + ' ui-h-icon';

        el.setAttribute(
            'aria-hidden',
            'true'
        );

        return el;

    }

    function sweepNode(node) {

        if (
            node.nodeType !== 3 ||
            !node.nodeValue
        ){
            return;
        }

        var parent =
            node.parentNode;

        if (
            !parent ||
            parent.nodeType !== 1
        ){
            return;
        }

        var tag =
            parent.tagName;

        if (
            tag !== 'H2' &&
            tag !== 'H3' &&
            tag !== 'H4' &&
            tag !== 'P' &&
            tag !== 'BUTTON' &&
            tag !== 'A' &&
            tag !== 'SPAN' &&
            tag !== 'DIV'
        ){
            return;
        }

        /* Buttons that already contain an icon <i> are skipped */

        if (
            parent.querySelector('i.fa-solid, i.fas, i.far, i.fab')
        ){
            return;
        }

        var value =
            node.nodeValue;

        var match =
            value.match(EMOJI_RE);

        if (!match){
            return;
        }

        var cleaned =
            value.replace(EMOJI_RE, '').replace(/^\s+/, '');

        if (!cleaned){
            return;
        }

        var iconClass =
            iconForText(cleaned);

        node.nodeValue =
            cleaned;

        if (iconClass && tag !== 'BUTTON') {

            parent.insertBefore(
                makeIcon(iconClass),
                node
            );

            parent.insertBefore(
                document.createTextNode(' '),
                node
            );

        }

    }

    function sweep(root) {

        if (!root)
            return;

        var walker =
            document.createTreeWalker(

                root,
                NodeFilter.SHOW_TEXT,
                null,
                false

            );

        var current =
            walker.nextNode();

        var batch = [];

        while (current) {

            batch.push(current);

            current =
                walker.nextNode();

        }

        batch.forEach(sweepNode);

    }

    var sweepScheduled =
        false;

    function scheduleSweep() {

        if (sweepScheduled)
            return;

        sweepScheduled =
            true;

        setTimeout(function () {

            sweepScheduled =
                false;

            sweep(document.body);

            normalizeInlineStyles(document);

            refreshWelcomeProgress();

        }, 120);

    }

    /* ---------------- Init ---------------- */

    function initEnhancements() {

        injectOverrideStyle();

        normalizeInlineStyles(document);

        sweep(document.body);

        refreshWelcomeProgress();

        var observer =
            new MutationObserver(scheduleSweep);

        observer.observe(
            document.body,
            {
                childList: true,
                subtree: true,
                characterData: true
            }
        );

    }

    /* ============================================================
       THEME CONTROLLER (Light / Dark / System) — presentation only
       Own localStorage key: 'themePreference'. Touches nothing else:
       no student data, no Supabase, no navigation, no quiz logic.
       ============================================================ */

    var THEME_KEY =
        'themePreference';

    function getStoredTheme() {

        try {

            var value =
                localStorage.getItem(THEME_KEY);

            return (
                value === 'light' ||
                value === 'dark' ||
                value === 'system'
            )
                ? value
                : 'dark';

        }
        catch (error) {

            return 'dark';

        }

    }

    function storeTheme(value) {

        try {

            localStorage.setItem(
                THEME_KEY,
                value
            );

        }
        catch (error) {

            /* storage unavailable — theme still applies for this visit */

        }

    }

    function systemPrefersDark() {

        return (
            window.matchMedia &&
            window.matchMedia('(prefers-color-scheme: dark)').matches
        );

    }

    function applyTheme(preference) {

        var effective =
            preference === 'system'
                ? (systemPrefersDark() ? 'dark' : 'light')
                : preference;

        document.documentElement.setAttribute(
            'data-theme',
            effective
        );

        var buttons =
            document.querySelectorAll('#themeSwitch [data-theme-option]');

        Array.prototype.forEach.call(
            buttons,
            function (button) {

                var is_active =
                    button.getAttribute('data-theme-option') === preference;

                button.classList.toggle(
                    'active',
                    is_active
                );

            }
        );

    }

    function initThemeController() {

        var preference =
            getStoredTheme();

        /* Apply before paint on first load to avoid a flash */
        applyTheme(preference);

        var switcher =
            document.getElementById('themeSwitch');

        if (switcher) {

            switcher.addEventListener(
                'click',
                function (event) {

                    var button =
                        event.target.closest('[data-theme-option]');

                    if (!button)
                        return;

                    preference =
                        button.getAttribute('data-theme-option');

                    storeTheme(preference);

                    applyTheme(preference);

                }
            );

        }

        /* Follow device changes while preference = system */

        if (window.matchMedia) {

            var media =
                window.matchMedia('(prefers-color-scheme: dark)');

            var on_system_change =
                function () {

                    if (preference === 'system')
                        applyTheme('system');

                };

            if (media.addEventListener) {

                media.addEventListener(
                    'change',
                    on_system_change
                );

            }
            else if (media.addListener) {

                media.addListener(on_system_change);

            }

        }

    }

    /* Theme must apply ASAP (head) to avoid flash of wrong theme */
    initThemeController();

    if (document.readyState === 'loading') {

        document.addEventListener(
            'DOMContentLoaded',
            initEnhancements
        );

    }
    else {

        initEnhancements();

    }

})();
