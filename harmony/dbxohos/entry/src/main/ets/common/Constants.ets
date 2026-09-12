/**
 * DBX OHOS app constants.
 */
export class AppConstants {
  static readonly HOST: string = '127.0.0.1';
  static readonly WEB_PORT: number = 4224;
  static readonly MCP_PORT: number = 18888;
  static readonly RAW_DIST_PATH: string = 'dbx-dist';
  static readonly DIST_DIR_NAME: string = 'dbx-dist';
  // Preferences key holding the fingerprint of the last frontend copy, so an
  // unchanged bundle is not copied (and its mtimes are not reset) on every start.
  static readonly DIST_FINGERPRINT_KEY: string = 'dbx-dist-fingerprint';
  static readonly INDEX_FILE: string = 'index.html';
  static readonly SERVER_URL: string = `http://${AppConstants.HOST}:${AppConstants.WEB_PORT}/`;
  static readonly MCP_URL: string = `http://${AppConstants.HOST}:${AppConstants.MCP_PORT}/mcp`;
  // Keep ArkWeb DevTools/CDP off in normal builds; enable only for local profiling.
  static readonly ENABLE_WEB_DEBUG: boolean = false;
  // V8 code-cache precompilation for the startup chunks (see CodeCacheWarmer).
  // Measured 2026-09-13 on HAD-W32: `precompileJavaScript` needs ~7.2s to
  // generate bytecode for the 23 startup chunks (3.9MB), while a cache-cleared
  // cold start improved only 1589ms -> 1456ms - the generated code cache is
  // stored together with the HTTP cache and is discarded with it. Disabled by
  // default; the code is kept so a future ArkWeb version can be re-measured.
  static readonly ENABLE_CODE_CACHE_WARMUP: boolean = false;
}
