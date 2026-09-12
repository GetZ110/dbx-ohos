import { webview } from '@kit.ArkWeb';
import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0xDBA;
const TAG = 'DBX_CODECACHE';

const MARKER_BEGIN = '<!-- dbx-startup-modulepreload:begin -->';
const MARKER_END = '<!-- dbx-startup-modulepreload:end -->';

/**
 * Response validators ArkWeb needs to key a precompiled code cache.
 *
 * `CacheOptions.responseHeaders` only understands E-Tag and Last-Modified, and
 * the cache is only reused when those match the validators of the real response
 * - so they are read from the local server instead of derived from the file
 * system (the ETag is a weak validator computed from size + mtime).
 */
class CacheValidators {
  etag: string;
  lastModified: string;

  constructor(etag: string, lastModified: string) {
    this.etag = etag;
    this.lastModified = lastModified;
  }
}

/**
 * Pre-generates a V8 code cache for the startup chunks.
 *
 * On a cold WebView cache the renderer must parse and compile the whole ~4.6MB
 * startup module graph; on device that compile - not the loopback transfer - is
 * what costs ~1.3s (`frontend modules loaded` 1589ms cold vs 315ms warm).
 * `precompileJavaScript()` compiles a script ahead of time and stores the
 * bytecode keyed by URL + validators, so a later load skips most of the compile.
 *
 * Verified on device (HAD-W32, API 23):
 * - The script must be passed as a **string**; passing the same bytes as a
 *   `Uint8Array` returns -1 even for files that succeed as a string.
 * - Real ES-module chunks are accepted (898KB `App-*.js` -> 0), so module syntax
 *   is not the problem; only the Uint8Array form is.
 *
 * Runs in the background after the UI is up; every failure is logged and ignored.
 */
export class CodeCacheWarmer {
  private static running: boolean = false;
  private static done: boolean = false;

  static isDone(): boolean {
    return CodeCacheWarmer.done;
  }

  /**
   * @param controller WebviewController bound to the Web component
   * @param distDir absolute path of the frontend inside the sandbox
   * @param baseUrl origin the page is served from (with trailing slash)
   */
  static async warm(controller: webview.WebviewController, distDir: string, baseUrl: string): Promise<void> {
    if (CodeCacheWarmer.running || CodeCacheWarmer.done) {
      return;
    }
    CodeCacheWarmer.running = true;
    const startedAt: number = Date.now();
    let ok: number = 0;
    let failed: number = 0;
    let kilobytes: number = 0;
    let compileMillis: number = 0;
    try {
      const chunks: Array<string> = CodeCacheWarmer.startupChunks(distDir);
      hilog.info(DOMAIN, TAG, 'precompile start: %{public}d startup chunks', chunks.length);
      for (const rel of chunks) {
        const url: string = `${baseUrl}${rel}`;
        const path: string = `${distDir}/${rel}`;
        try {
          const validators: CacheValidators = await CodeCacheWarmer.validators(url);
          const size: number = fs.statSync(path).size;
          const source: string = fs.readTextSync(path);
          const headers: Array<webview.WebHeader> = [];
          if (validators.etag.length > 0) {
            headers.push({ headerKey: 'E-Tag', headerValue: validators.etag });
          }
          if (validators.lastModified.length > 0) {
            headers.push({ headerKey: 'Last-Modified', headerValue: validators.lastModified });
          }
          const options: webview.CacheOptions = { responseHeaders: headers };
          const chunkStarted: number = Date.now();
          // The first precompile of a session rejects (the code cache machinery
          // is not ready yet); retrying the identical call a moment later
          // succeeds, so swallow the rejection and retry rather than trusting a
          // single attempt.
          let code: number = -1;
          for (let attempt = 0; attempt < 3 && code !== 0; attempt++) {
            if (attempt > 0) {
              await CodeCacheWarmer.sleep(300);
            }
            try {
              code = await controller.precompileJavaScript(url, source, options);
            } catch (err) {
              code = -1;
            }
          }
          compileMillis += Date.now() - chunkStarted;
          if (code === 0) {
            ok++;
            kilobytes += Math.round(size / 1024);
          } else {
            failed++;
            hilog.warn(DOMAIN, TAG, 'precompile returned %{public}d for %{public}s', code, rel);
          }
        } catch (err) {
          failed++;
          const e = err as BusinessError;
          hilog.warn(DOMAIN, TAG, 'precompile failed for %{public}s: %{public}s', rel, JSON.stringify(e));
        }
      }
      CodeCacheWarmer.done = true;
      hilog.info(DOMAIN, TAG,
        'precompile done: %{public}d ok / %{public}d failed, %{public}d KB, compile %{public}dms, total %{public}dms',
        ok, failed, kilobytes, compileMillis, Date.now() - startedAt);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'precompile aborted: %{public}s', JSON.stringify(e));
    } finally {
      CodeCacheWarmer.running = false;
    }
  }

  /** Startup chunks are exactly the ones `inject_modulepreload.py` listed. */
  private static startupChunks(distDir: string): Array<string> {
    const chunks: Array<string> = [];
    try {
      const html: string = fs.readTextSync(`${distDir}/index.html`);
      const begin: number = html.indexOf(MARKER_BEGIN);
      const end: number = html.indexOf(MARKER_END);
      if (begin < 0 || end <= begin) {
        hilog.warn(DOMAIN, TAG, 'modulepreload block not found in index.html');
        return chunks;
      }
      const block: string = html.substring(begin, end);
      const prefix: string = 'href="./';
      let cursor: number = 0;
      while (true) {
        const hrefAt: number = block.indexOf(prefix, cursor);
        if (hrefAt < 0) {
          break;
        }
        const valueAt: number = hrefAt + prefix.length;
        const valueEnd: number = block.indexOf('"', valueAt);
        if (valueEnd < 0) {
          break;
        }
        chunks.push(block.substring(valueAt, valueEnd));
        cursor = valueEnd;
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'cannot read startup chunk list: %{public}s', JSON.stringify(e));
    }
    return chunks;
  }

  private static validators(url: string): Promise<CacheValidators> {
    return new Promise<CacheValidators>((resolve) => {
      const request = http.createHttp();
      request.request(url, {
        method: http.RequestMethod.HEAD,
        connectTimeout: 2000,
        readTimeout: 2000
      }, (err: BusinessError, response: http.HttpResponse) => {
        request.destroy();
        if (err || response.responseCode !== 200) {
          hilog.warn(DOMAIN, TAG, 'HEAD %{public}s failed: %{public}s', url, JSON.stringify(err));
          resolve(new CacheValidators('', ''));
          return;
        }
        const header = response.header as Record<string, string>;
        resolve(new CacheValidators(
          CodeCacheWarmer.headerValue(header, 'etag'),
          CodeCacheWarmer.headerValue(header, 'last-modified')));
      });
    });
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** Header names are not consistently cased by the HTTP stack. */
  private static headerValue(header: Record<string, string>, lowerCaseName: string): string {
    const keys: Array<string> = Object.keys(header);
    for (const key of keys) {
      if (key.toLowerCase() === lowerCaseName) {
        const value: string = header[key];
        return value !== undefined && value !== null ? value : '';
      }
    }
    return '';
  }
}
