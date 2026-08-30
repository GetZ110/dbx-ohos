import { ThemePrefs } from './ThemePrefs';

/**
 * JavaScript bridge object exposed to the Web page as `window.dbxNativePrefs`.
 *
 * The injected document-start script uses these synchronous methods to restore
 * theme preferences into localStorage before the DBX SPA starts, and to mirror
 * any later `localStorage.setItem('dbx-*', ...)` calls back to native storage.
 */
export class WebPrefsBridge {
  getPref(key: string): string {
    return ThemePrefs.getPref(key);
  }

  savePref(key: string, value: string): void {
    ThemePrefs.savePref(key, value);
  }
}
