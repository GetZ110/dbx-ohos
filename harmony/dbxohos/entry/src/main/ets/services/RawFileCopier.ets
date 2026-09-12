import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemePrefs } from './ThemePrefs';

const DOMAIN = 0xDB4;
const TAG = 'DBX_COPY';

/**
 * Copies resources/rawfile content into the app sandbox so the local HTTP
 * server can serve the DBX SPA with normal file system access.
 *
 * Two properties matter for startup time:
 *
 * 1. The copy is only performed when the embedded frontend actually changed.
 *    Rewriting 695 files on every cold start costs ~80-270ms of file system
 *    work, and - more importantly - it resets every `Last-Modified` timestamp.
 *    The local HTTP server derives its cache validators from that timestamp, so
 *    rewriting unconditionally made the WebView re-download AND re-compile the
 *    whole ~4.6MB startup module graph on every launch.
 * 2. Every file system operation is asynchronous. `getRawFileContentSync` plus
 *    `writeSync` used to block the ArkTS main thread for the whole copy.
 */
export class RawFileCopier {
  /**
   * Recursively copy a rawfile directory into a sandbox destination directory,
   * unless the destination already holds this exact frontend build.
   *
   * @param context UIAbilityContext used to access resourceManager
   * @param rawPath rawfile path (e.g. "dbx-dist")
   * @param destDir destination absolute directory path
   * @param markerKey Preferences key holding the fingerprint of the last copy
   * @returns true when files were copied, false when the existing copy was reused
   */
  static async copyRawDirIfNeeded(
    context: common.UIAbilityContext,
    rawPath: string,
    destDir: string,
    markerKey: string
  ): Promise<boolean> {
    const started: number = Date.now();
    let fingerprint: string = '';
    try {
      fingerprint = RawFileCopier.fingerprint(context, rawPath);
    } catch (err) {
      const e = err as Error;
      hilog.warn(DOMAIN, TAG, 'fingerprint failed, copying anyway: %{public}s', e.message);
    }

    if (fingerprint.length > 0 && ThemePrefs.getPref(markerKey) === fingerprint
      && RawFileCopier.isDestinationReady(destDir)) {
      hilog.info(DOMAIN, TAG, 'frontend unchanged (%{public}s), skipped copy in %{public}dms',
        fingerprint, Date.now() - started);
      return false;
    }

    await RawFileCopier.copyRawDir(context, rawPath, destDir);
    if (fingerprint.length > 0) {
      ThemePrefs.savePref(markerKey, fingerprint);
    }
    hilog.info(DOMAIN, TAG, 'frontend copied from rawfile in %{public}dms (fp=%{public}s)',
      Date.now() - started, fingerprint.length > 0 ? fingerprint : '(none)');
    return true;
  }

  /**
   * Fingerprints the embedded frontend directory.
   *
   * `index.html` embeds the content-hashed entry chunk plus the generated
   * dependency map, so its bytes change whenever the bundle changes. The full
   * file name tree is mixed in as a second, cheap signal (rolldown hashes every
   * chunk name after its content).
   */
  static fingerprint(context: common.UIAbilityContext, rawPath: string): string {
    const names: Array<string> = [];
    RawFileCopier.collectNames(context, rawPath, names);
    names.sort();

    let hash: number = 5381;
    const html: Uint8Array = context.resourceManager.getRawFileContentSync(`${rawPath}/index.html`);
    for (let i = 0; i < html.length; i++) {
      hash = ((hash << 5) - hash + html[i]) | 0;
    }
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      for (let j = 0; j < name.length; j++) {
        hash = ((hash << 5) - hash + name.charCodeAt(j)) | 0;
      }
    }
    return `v1-${(hash >>> 0).toString(16)}-${names.length}`;
  }

  private static collectNames(
    context: common.UIAbilityContext,
    rawPath: string,
    acc: Array<string>
  ): void {
    const entries: Array<string> = context.resourceManager.getRawFileListSync(rawPath);
    for (const name of entries) {
      const child: string = rawPath.length > 0 ? `${rawPath}/${name}` : name;
      acc.push(child);
      if (RawFileCopier.isDirectory(context, child)) {
        RawFileCopier.collectNames(context, child, acc);
      }
    }
  }

  private static isDirectory(context: common.UIAbilityContext, path: string): boolean {
    try {
      // Directories expose a file list; files do not.
      context.resourceManager.getRawFileListSync(path);
      return true;
    } catch (err) {
      return false;
    }
  }

  private static isDestinationReady(destDir: string): boolean {
    try {
      return fs.accessSync(`${destDir}/index.html`);
    } catch (err) {
      return false;
    }
  }

  /**
   * Recursively copy a rawfile directory into a sandbox destination directory.
   *
   * @param context UIAbilityContext used to access resourceManager
   * @param rawPath rawfile path (e.g. "dbx-dist")
   * @param destDir destination absolute directory path
   */
  static async copyRawDir(context: common.UIAbilityContext, rawPath: string, destDir: string): Promise<void> {
    await RawFileCopier.ensureDir(destDir);

    const entries: Array<string> = context.resourceManager.getRawFileListSync(rawPath);
    for (const name of entries) {
      const srcPath: string = rawPath ? `${rawPath}/${name}` : name;
      const destPath: string = `${destDir}/${name}`;

      if (RawFileCopier.isDirectory(context, srcPath)) {
        await RawFileCopier.copyRawDir(context, srcPath, destPath);
      } else {
        const data: Uint8Array = await context.resourceManager.getRawFileContent(srcPath);
        await RawFileCopier.writeFile(destPath, data);
      }
    }
  }

  private static async ensureDir(dirPath: string): Promise<void> {
    try {
      // Recursive creation also succeeds when the chain already exists.
      await fs.mkdir(dirPath, true);
    } catch (err) {
      // Directory may already exist; later file writes will surface real errors.
      const e = err as Error;
      hilog.warn(DOMAIN, TAG, 'ensureDir ignored: %{public}s', JSON.stringify(e));
    }
  }

  private static async writeFile(filePath: string, data: Uint8Array): Promise<void> {
    const file = await fs.open(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      const buffer: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
      await fs.write(file.fd, buffer);
    } finally {
      await fs.close(file);
    }
  }
}
