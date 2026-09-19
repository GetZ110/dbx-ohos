import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xDB7;
const TAG = 'DBX_THEME_PREFS';
const STORE_NAME = 'dbx_theme_prefs';

/**
 * Native persistence for Web UI preferences (theme/palette/corner style).
 *
 * ArkWeb localStorage is not reliably persisted across full app restarts on
 * some HarmonyOS devices, so theme changes are mirrored into Preferences.
 * A document-start script restores them into localStorage before the SPA runs.
 */
export class ThemePrefs {
  private static store: preferences.Preferences | null = null;

  static init(context: common.UIAbilityContext): void {
    try {
      if (!ThemePrefs.store) {
        ThemePrefs.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      }
    } catch (err) {
      const e = err as Error;
      hilog.warn(DOMAIN, TAG, 'init failed: %{public}s', e.message);
    }
  }

  static getPref(key: string): string {
    try {
      const store = ThemePrefs.store;
      if (!store) {
        return '';
      }
      const value = store.getSync(key, '');
      return typeof value === 'string' ? value : '';
    } catch (err) {
      const e = err as Error;
      hilog.warn(DOMAIN, TAG, 'getPref(%{public}s) failed: %{public}s', key, e.message);
      return '';
    }
  }

  /**
   * True when `value` can live in the preferences XML file.
   *
   * The store is an XML document, so a raw control character (0x00-0x1F other
   * than tab/newline/CR) makes the file unparsable. The framework then
   * quarantines it as `dbx_theme_prefs.broken` and **resets every key in the
   * store** — measured 2026-09-19 after a value containing \u0001 wiped the
   * theme prefs. Reject such values loudly instead of corrupting the store.
   */
  private static isStorable(value: string): boolean {
    for (let i: number = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      if (code < 0x20 && code !== 0x09 && code !== 0x0A && code !== 0x0D) {
        return false;
      }
    }
    return true;
  }

  static savePref(key: string, value: string): void {
    try {
      const store = ThemePrefs.store;
      if (!store) {
        return;
      }
      if (!ThemePrefs.isStorable(value)) {
        hilog.error(DOMAIN, TAG, 'refusing to store %{public}s: value has XML-invalid control characters', key);
        return;
      }
      store.putSync(key, value);
      store.flush().catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'flush failed: %{public}s', err.message);
      });
    } catch (err) {
      const e = err as Error;
      hilog.warn(DOMAIN, TAG, 'savePref(%{public}s) failed: %{public}s', key, e.message);
    }
  }
}
