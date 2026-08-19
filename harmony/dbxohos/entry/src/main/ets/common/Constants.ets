/**
 * DBX OHOS app constants.
 */
export class AppConstants {
  static readonly HOST: string = '127.0.0.1';
  static readonly WEB_PORT: number = 4224;
  static readonly MCP_PORT: number = 18888;
  static readonly RAW_DIST_PATH: string = 'dbx-dist';
  static readonly DIST_DIR_NAME: string = 'dbx-dist';
  static readonly INDEX_FILE: string = 'index.html';
  static readonly SERVER_URL: string = `http://${AppConstants.HOST}:${AppConstants.WEB_PORT}/`;
  static readonly MCP_URL: string = `http://${AppConstants.HOST}:${AppConstants.MCP_PORT}/mcp`;
}
