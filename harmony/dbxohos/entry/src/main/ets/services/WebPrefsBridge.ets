import { ThemePrefs } from './ThemePrefs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xDB9;
const TAG = 'DBX_THEME_BRIDGE';

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

  /**
   * Called from the injected document script when the web UI's actual dark
   * state changes (including system theme mode). ArkTS uses this instead of
   * guessing from the saved theme preference.
   */
  setDarkMode(dark: boolean): void {
    hilog.info(DOMAIN, TAG, 'setDarkMode called: %{public}s', dark ? 'dark' : 'light');
    AppStorage.setOrCreate('dbx_dark_mode', dark);
  }
}
