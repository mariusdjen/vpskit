/* vpskit landing page */
(function () {
  'use strict';

  /* --- Language toggle --- */
  var html = document.documentElement;
  var stored = localStorage.getItem('vpskit-lang');
  var lang = stored || (navigator.language && navigator.language.startsWith('fr') ? 'fr' : 'en');
  html.setAttribute('data-lang', lang);

  var toggle = document.getElementById('langToggle');
  if (toggle) {
    toggle.addEventListener('click', function () {
      var next = html.getAttribute('data-lang') === 'en' ? 'fr' : 'en';
      html.setAttribute('data-lang', next);
      localStorage.setItem('vpskit-lang', next);
    });
  }

  /* --- Copy to clipboard --- */
  document.addEventListener('click', function (e) {
    var btn = e.target.closest('.copy-btn');
    if (!btn) return;
    var text = btn.getAttribute('data-copy');
    if (!text) return;
    navigator.clipboard.writeText(text).then(function () {
      btn.classList.add('copied');
      var orig = btn.innerHTML;
      btn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="18" height="18"><polyline points="20 6 9 17 4 12"/></svg>';
      setTimeout(function () {
        btn.innerHTML = orig;
        btn.classList.remove('copied');
      }, 1500);
    });
  });

  /* --- Tabs --- */
  document.addEventListener('click', function (e) {
    var btn = e.target.closest('.tab-btn');
    if (!btn) return;
    var tabId = btn.getAttribute('data-tab');
    var container = btn.closest('.container');
    if (!container) return;
    container.querySelectorAll('.tab-btn').forEach(function (b) {
      b.classList.remove('active');
      b.setAttribute('aria-selected', 'false');
    });
    container.querySelectorAll('.tab-panel').forEach(function (p) {
      p.classList.remove('active');
    });
    btn.classList.add('active');
    btn.setAttribute('aria-selected', 'true');
    var panel = document.getElementById(tabId);
    if (panel) panel.classList.add('active');
  });

  /* --- Scroll reveal --- */
  var fadeEls = document.querySelectorAll('.fade-in');
  if (fadeEls.length && 'IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.15 });
    fadeEls.forEach(function (el) { observer.observe(el); });
  } else {
    fadeEls.forEach(function (el) { el.classList.add('visible'); });
  }
})();
