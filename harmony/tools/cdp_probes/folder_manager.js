/**
 * Probe: open the toolbar's 授权目录管理 panel and dump its rows.
 *
 *   ./harmony/tools/ohos_cdp.sh --file harmony/tools/cdp_probes/folder_manager.js
 *
 * Reports, per row, the raw `documentsStatus()` value and whether a revoke /
 * grant button is present - i.e. exactly what the panel paints. The panel is
 * closed and reopened once to catch state left dangling by a previous probe.
 *
 * Do not swap `window.dbxNativeWindow` for a fake bridge in a probe without
 * restoring it in a `finally`: a probe that throws leaves the fake behind and
 * every later "native call" silently hits it (that once looked like a broken
 * revoke implementation for an hour).
 */
(async function () {
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  var out = {};
  var button = document.querySelector('[data-dbx-folder-manager]');
  out.toolbarButton = button ? (button.textContent || '').trim() : null;
  if (!button) return JSON.stringify(out, null, 1);

  button.click();
  await sleep(500);
  var overlay = document.querySelector('[data-dbx-fm-overlay]');
  out.open = !!overlay;
  if (!overlay) return JSON.stringify(out, null, 1);

  var rect = overlay.getBoundingClientRect();
  out.overlayRect = [Math.round(rect.width), Math.round(rect.height)];
  out.viewport = [window.innerWidth, window.innerHeight];
  out.rows = Array.prototype.map.call(overlay.querySelectorAll('[data-dbx-fm-row]'), function (row) {
    return {
      key: row.getAttribute('data-dbx-fm-row'),
      status: row.getAttribute('data-dbx-fm-status') || null,
      permission: (row.querySelector('[data-dbx-fm-perm]') || {}).textContent || null,
      revoke: !!row.querySelector('[data-dbx-fm-revoke]'),
      grant: !!row.querySelector('[data-dbx-fm-grant]'),
      text: (row.textContent || '').replace(/\s+/g, ' ').trim(),
    };
  });
  out.addButton = !!overlay.querySelector('[data-dbx-fm-add]');

  // Close through the UI (not by removing the node) so internal state stays sane,
  // then reopen to prove it can.
  var closeButton = null;
  Array.prototype.forEach.call(overlay.querySelectorAll('button'), function (b) {
    if ((b.textContent || '').trim() === '关闭') closeButton = b;
  });
  if (closeButton) closeButton.click();
  await sleep(200);
  out.closed = !document.querySelector('[data-dbx-fm-overlay]');
  button.click();
  await sleep(400);
  out.reopened = !!document.querySelector('[data-dbx-fm-overlay]');
  var reopened = document.querySelector('[data-dbx-fm-overlay]');
  if (reopened) reopened.click();
  await sleep(200);
  out.closedByBackdrop = !document.querySelector('[data-dbx-fm-overlay]');
  return JSON.stringify(out, null, 1);
})()
