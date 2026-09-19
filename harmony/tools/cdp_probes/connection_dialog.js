/**
 * Probe: open the connection dialog on SQLite and dump the injected file-path row.
 *
 *   ./harmony/tools/ohos_cdp.sh --file harmony/tools/cdp_probes/connection_dialog.js
 *
 * Drives the UI the way the app's own tests cannot: click 新建连接, type into the
 * database-type search box, pick the SQLite option (which mounts the dialog that
 * carries the file-path row), then report what FilePickerWebScript injected.
 *
 * Keep this file free of backslashes and template literals; it is uploaded as a
 * plain script, so escaping is not an issue here - unlike the injected scripts
 * themselves (see AGENTS.md).
 */
(async function () {
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function clickText(text) {
    var all = document.querySelectorAll('button,[role=button],a,[role=option]');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el.offsetParent !== null && (el.textContent || '').trim() === text) {
        el.click();
        return true;
      }
    }
    return false;
  }

  var out = {};
  out.clickNewConnection = clickText('新建连接');
  await sleep(1500);

  var dialogs = document.querySelectorAll('[data-slot="dialog-content"]');
  var scope = dialogs[dialogs.length - 1] || document;
  var search = scope.querySelector('input[data-slot="input"]');
  if (search) {
    search.value = 'sqlite';
    search.dispatchEvent(new Event('input', { bubbles: true }));
  }
  await sleep(1500);

  var options = document.querySelectorAll('button.connection-db-picker-option');
  out.sqlitePicked = false;
  for (var i = 0; i < options.length; i++) {
    if ((options[i].textContent || '').toLowerCase().indexOf('sqlite') >= 0) {
      options[i].dispatchEvent(new MouseEvent('click', { bubbles: true }));
      options[i].dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
      out.sqlitePicked = true;
      break;
    }
  }
  await sleep(1800);

  var actions = document.querySelectorAll('[data-dbx-file-action]');
  out.actions = Array.prototype.map.call(actions, function (el) {
    return el.getAttribute('data-dbx-file-action');
  });
  out.actionTitles = Array.prototype.map.call(actions, function (el) { return el.title; });

  var hint = document.querySelector('[data-dbx-file-hint]');
  out.hint = hint ? hint.textContent : null;

  var labels = document.querySelectorAll('[data-slot="label"]');
  for (var k = 0; k < labels.length; k++) {
    if ((labels[k].textContent || '').trim() === '文件路径') {
      var row = labels[k].closest('.grid');
      var input = row.querySelector('input[data-slot="input"]');
      out.pathInput = {
        readOnly: input.readOnly,
        value: input.value,
        placeholder: input.placeholder,
      };
    }
  }

  var host = window.dbxNativeWindow;
  out.bridge = {
    grantedFolders: host ? host.grantedFolders() : null,
    documentsStatus: host && host.documentsStatus ? host.documentsStatus() : null,
  };
  return JSON.stringify(out, null, 1);
})()
