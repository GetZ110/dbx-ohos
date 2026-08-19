import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xDB4;
const TAG = 'DBX_COPY';

/**
 * Copies resources/rawfile content into the app sandbox so the local HTTP
 * server can serve the DBX SPA with normal file system access.
 */
export class RawFileCopier {
  /**
   * Recursively copy a rawfile directory into a sandbox destination directory.
   *
   * @param context UIAbilityContext used to access resourceManager
   * @param rawPath rawfile path (e.g. "dbx-dist")
   * @param destDir destination absolute directory path
   */
  static async copyRawDir(context: common.UIAbilityContext, rawPath: string, destDir: string): Promise<void> {
    RawFileCopier.ensureDir(destDir);

    const rm = context.resourceManager;
    const entries: Array<string> = rm.getRawFileListSync(rawPath);
    for (const name of entries) {
      const srcPath: string = rawPath ? `${rawPath}/${name}` : name;
      const destPath: string = `${destDir}/${name}`;

      let isDirectory: boolean = false;
      try {
        // Directories expose a file list; files do not.
        rm.getRawFileListSync(srcPath);
        isDirectory = true;
      } catch (err) {
        isDirectory = false;
      }

      if (isDirectory) {
        await RawFileCopier.copyRawDir(context, srcPath, destPath);
      } else {
        const data: Uint8Array = rm.getRawFileContentSync(srcPath);
        RawFileCopier.writeFile(destPath, data);
      }
    }
  }

  private static ensureDir(dirPath: string): void {
    try {
      fs.mkdirSync(dirPath);
    } catch (err) {
      // Directory may already exist; later file writes will surface real errors.
      hilog.warn(DOMAIN, TAG, 'ensureDir ignored: %{public}s', JSON.stringify(err));
    }
  }

  private static writeFile(filePath: string, data: Uint8Array): void {
    const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      const buffer: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
  }
}
