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

  static savePref(key: string, value: string): void {
    try {
      const store = ThemePrefs.store;
      if (!store) {
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
