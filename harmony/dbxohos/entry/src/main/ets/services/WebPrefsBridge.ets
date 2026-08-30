import { ThemePrefs } from './ThemePrefs';
import { WindowBridge } from './WindowBridge';

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
    if (key === 'dbx-theme') {
      // Update the native title-button colors immediately, without waiting for
      // a polling interval on the ArkTS side.
      WindowBridge.setThemeMode(value);
    }
  }
}
