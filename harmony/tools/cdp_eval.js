#!/usr/bin/env node
/**
 * Evaluate JavaScript inside the DBX HAP's ArkWeb page over CDP.
 *
 * This is how the injected scripts (file-picker row, UI-scale compensation,
 * grid header, folder manager) are verified without a human clicking: the page
 * is driven through `Runtime.evaluate`, so a probe script can open dialogs,
 * click injected buttons and read the DOM back.
 *
 * Prerequisite: the app must have been built with
 * `AppConstants.ENABLE_WEB_DEBUG = true` (common/Constants.ets) and installed,
 * because ArkWeb only opens its devtools socket then. Keep it false in anything
 * shipped: with the socket open, anything that can reach the device over hdc can
 * inject JavaScript into a page that holds database credentials.
 *
 * Usually run through harmony/tools/ohos_cdp.sh, which finds the right socket and
 * sets up the port forward; this file only speaks CDP.
 *
 *   node harmony/tools/cdp_eval.js --port 9500 --url 4224 --eval "document.title"
 *   node harmony/tools/cdp_eval.js --port 9500 --file .tmp/probe.js
 *   node harmony/tools/cdp_eval.js --port 9500 --list
 *
 * `--file` is preferable for anything longer than a one-liner. The script is
 * evaluated with `awaitPromise` (top-level `await` works when wrapped in an
 * async IIFE) and `userGesture` (so synthetic clicks are treated as user
 * actions). Its value is printed as JSON, so `return JSON.stringify(...)` at the
 * end of a probe is the idiomatic shape.
 */
'use strict';

const fs = require('fs');

const argv = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : dflt;
};
const flag = (name) => argv.includes('--' + name);

const port = opt('port', '9500');
const urlFilter = opt('url', '4224');
const timeoutMs = Number(opt('timeout', '30000'));

async function targets() {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`);
  return res.json();
}

async function main() {
  const list = await targets();

  if (flag('list')) {
    for (const t of list) console.log(`${t.url}\t${t.title}`);
    return;
  }

  const target = list.find((t) => (t.url || '').includes(urlFilter));
  if (!target) {
    console.error(`no target whose url contains "${urlFilter}"; available:`);
    for (const t of list) console.error('  ' + t.url);
    process.exit(2);
  }

  let expression = opt('eval', null);
  const file = opt('file', null);
  if (file) expression = fs.readFileSync(file, 'utf8');
  if (!expression) {
    console.error('need --eval <expression> or --file <script>');
    process.exit(2);
  }

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  const pending = new Map();
  let seq = 0;
  const send = (method, params) =>
    new Promise((resolve, reject) => {
      const id = ++seq;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params: params || {} }));
    });

  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    }
  });

  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve);
    ws.addEventListener('error', () => reject(new Error('websocket error')));
  });

  const timer = setTimeout(() => {
    console.error(`timeout after ${timeoutMs}ms`);
    process.exit(3);
  }, timeoutMs);

  const result = await send('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true,
  });
  clearTimeout(timer);

  if (result.exceptionDetails) {
    const ex = result.exceptionDetails.exception || result.exceptionDetails;
    console.error('page exception: ' + JSON.stringify(ex));
    process.exit(4);
  }
  const value = result.result && result.result.value;
  if (flag('json')) console.log(JSON.stringify(result.result, null, 2));
  else console.log(typeof value === 'string' ? value : JSON.stringify(value, null, 2));
  ws.close();
}

main().catch((err) => {
  console.error(String(err && err.message ? err.message : err));
  process.exit(1);
});
