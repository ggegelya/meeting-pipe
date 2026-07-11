// MIC7 probe: is Google Meet's mute-state DOM signal stable enough to build a
// browser mute oracle on?
//
// Browsers expose no AX mute oracle, so meeting-pipe energy-gates browser
// meetings (NoOpMuteAdapter). MIC7 asks whether Meet's own page carries a
// durable mute signal (an aria attribute / data-* attribute / exposed state)
// that survives Meet's frequent UI churn, so a small extension could feed it to
// the daemon. Before committing to that net-new surface, measure the signal.
//
// HOW TO RUN: open a Google Meet call, open DevTools (Cmd+Opt+I) -> Console,
// paste this whole file, press Enter. Then toggle your mic on and off a few
// times and read the log. It ONLY reads the page; it changes nothing and sends
// nothing anywhere.
//
// WHAT TO LOOK FOR: which of the dumped signals flips reliably on every toggle,
// and whether that signal is stable (a data-* / aria-pressed boolean) or fragile
// (a localized aria-label like "Turn off microphone", or an obfuscated class
// name). A stable boolean that flips every time is a GO for a real oracle; only
// a localized label flipping (the failure mode the native AX incident proved) is
// a NO-GO for that signal.
(function () {
  function findMicButton() {
    const byData = document.querySelector('[data-is-muted], [data-mute-button], [data-muted]');
    if (byData) return byData;
    const candidates = [...document.querySelectorAll('[role="button"], button')];
    return candidates.find((b) => {
      const hay = (b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-tooltip') || '');
      return /microphone|\bmic\b|мікрофон|микрофон/i.test(hay);
    }) || null;
  }

  function snapshot(el) {
    return {
      'aria-label (localized!)': el.getAttribute('aria-label'),
      'aria-pressed': el.getAttribute('aria-pressed'),
      'data-is-muted': el.getAttribute('data-is-muted'),
      'data-muted': el.getAttribute('data-muted'),
      'data-tooltip (localized!)': el.getAttribute('data-tooltip'),
      className: typeof el.className === 'string' ? el.className : '(non-string)',
    };
  }

  const btn = findMicButton();
  if (!btn) {
    console.warn('MIC7: no mic button found. Join the call and make the bottom controls visible, then re-run.');
    return;
  }

  console.log('%cMIC7 probe watching this mic button:', 'font-weight:bold', btn);
  console.table(snapshot(btn));
  console.log('MIC7: toggle your mic a few times. Each attribute change logs a row below.');
  console.log('MIC7: note which signal flips EVERY time and whether it is a stable boolean or a localized string.');

  let last = JSON.stringify(snapshot(btn));
  let changes = 0;
  const obs = new MutationObserver(() => {
    const now = JSON.stringify(snapshot(btn));
    if (now !== last) {
      last = now;
      changes += 1;
      console.log('%cMIC7 change #' + changes + ' @ ' + new Date().toLocaleTimeString(), 'color:#0a0');
      console.table(snapshot(btn));
    }
  });
  obs.observe(btn, { attributes: true, attributeOldValue: true, subtree: false });

  window.__mic7StopProbe = function () {
    obs.disconnect();
    console.log('MIC7: stopped after ' + changes + ' observed changes.');
  };
  console.log('MIC7: call __mic7StopProbe() when done.');
})();
