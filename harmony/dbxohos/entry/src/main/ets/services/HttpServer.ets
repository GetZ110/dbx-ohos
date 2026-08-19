import util from '@ohos.util';
import socket from '@ohos.net.socket';
import fs from '@ohos.file.fs';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { McpServer } from './McpServer';

const DOMAIN = 0xDB0;
const TAG = 'DBX_HTTP';

interface HttpRequest {
  method: string;
  path: string;
  headers: Map<string, string>;
  body: string;
}

interface HttpResponse {
  status: number;
  statusText: string;
  headers: Map<string, string>;
  body: string;
}

interface SocketMessage {
  message: ArrayBuffer;
  remoteInfo: socket.SocketRemoteInfo;
}

/**
 * A small local HTTP/1.1 server implemented with ArkTS TCP sockets.
 *
 * v1 responsibilities:
 *  - serve the DBX SPA static files from the app sandbox
 *  - expose /api/health
 *  - expose /mcp for the built-in MCP server
 *  - return 501 for other /api/* routes until the Rust dbx-core backend is
 *    integrated as a native .so
 */
export class HttpServer {
  private static instance: HttpServer = new HttpServer();
  private server: socket.TCPSocketServer | null = null;
  private distDir: string = '';
  private started: boolean = false;

  static getInstance(): HttpServer {
    return HttpServer.instance;
  }

  async start(port: number, distDir: string): Promise<void> {
    if (this.started) {
      hilog.info(DOMAIN, TAG, 'HTTP server already started');
      return;
    }
    this.distDir = distDir;
    const tcpServer: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    this.server = tcpServer;

    tcpServer.on('connect', (client: socket.TCPSocketConnection) => {
      this.handleConnection(client);
    });
    tcpServer.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'HTTP server error: %{public}s', JSON.stringify(err));
    });

    const addr: socket.NetAddress = {
      address: '127.0.0.1',
      port: port,
      family: 1
    };
    await tcpServer.listen(addr);
    this.started = true;
    hilog.info(DOMAIN, TAG, 'HTTP server listening on %{public}s:%{public}d', addr.address, port);
  }

  stop(): void {
    if (this.server) {
      try {
        this.server.off('connect');
        this.server.off('error');
        this.server.close();
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'stop error: %{public}s', JSON.stringify(err));
      }
      this.server = null;
    }
    this.started = false;
  }

  isStarted(): boolean {
    return this.started;
  }

  private handleConnection(client: socket.TCPSocketConnection): void {
    let buffer: string = '';
    client.on('message', (value: SocketMessage) => {
      buffer += this.arrayBufferToString(value.message);
      const headerEnd: number = buffer.indexOf('\r\n\r\n');
      if (headerEnd < 0) {
        return;
      }
      const rawHead: string = buffer.substring(0, headerEnd);
      const rawBody: string = buffer.substring(headerEnd + 4);
      buffer = '';
      const request: HttpRequest | null = this.parseRequest(rawHead, rawBody);
      if (!request) {
        this.sendText(client, 400, 'Bad Request', 'Bad Request', 'text/plain; charset=utf-8');
        return;
      }
      this.dispatch(client, request);
    });
  }

  private parseRequest(rawHead: string, rawBody: string): HttpRequest | null {
    const lines: Array<string> = rawHead.split('\r\n');
    if (lines.length === 0) {
      return null;
    }
    const parts: Array<string> = lines[0].split(' ');
    if (parts.length < 2) {
      return null;
    }
    const headers: Map<string, string> = new Map();
    for (let i: number = 1; i < lines.length; i++) {
      const idx: number = lines[i].indexOf(':');
      if (idx > 0) {
        const key: string = lines[i].substring(0, idx).trim().toLowerCase();
        const value: string = lines[i].substring(idx + 1).trim();
        headers.set(key, value);
      }
    }
    const request: HttpRequest = {
      method: parts[0],
      path: parts[1],
      headers: headers,
      body: rawBody
    };
    return request;
  }

  private dispatch(client: socket.TCPSocketConnection, request: HttpRequest): void {
    const url: string = request.path.split('?')[0];
    const path: string = decodeURIComponent(url);

    if (path.startsWith('/api/')) {
      this.handleApi(client, path);
      return;
    }
    if (path === '/mcp' || path.startsWith('/mcp/')) {
      McpServer.getInstance().handleHttpRequest(client, request.method, request.path, request.body);
      return;
    }
    this.serveStatic(client, path, request.method);
  }

  private handleApi(client: socket.TCPSocketConnection, path: string): void {
    if (path === '/api/health') {
      const body: string =
        '{"status":"ok","server":"arkts-http-v1","dbx":"embedded-web-shell","api":"native-backend-pending"}';
      this.sendJson(client, 200, body);
      return;
    }
    const body: string =
      '{"error":"native-backend-not-integrated","message":"This DBX API route requires the Rust dbx-core native backend (.so)."}';
    this.sendJson(client, 501, body);
  }

  private serveStatic(client: socket.TCPSocketConnection, path: string, method: string): void {
    let relative: string = path === '/' ? '/index.html' : path;
    if (relative.includes('..')) {
      this.sendText(client, 403, 'Forbidden', 'Forbidden', 'text/plain; charset=utf-8');
      return;
    }
    let filePath: string = `${this.distDir}${relative}`;
    let data: ArrayBuffer | null = this.readFile(filePath);
    if (!data && !relative.startsWith('/assets/') && !relative.includes('.')) {
      // SPA fallback
      filePath = `${this.distDir}/index.html`;
      data = this.readFile(filePath);
    }
    if (!data) {
      this.sendText(client, 404, 'Not Found', 'Not Found', 'text/plain; charset=utf-8');
      return;
    }
    const contentType: string = this.contentType(filePath);
    this.sendBytes(client, method === 'HEAD' ? 200 : 200, data, contentType);
  }

  private readFile(filePath: string): ArrayBuffer | null {
    try {
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(filePath);
        if (stat.size <= 0) {
          return new ArrayBuffer(0);
        }
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buffer);
        return buffer;
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'read file failed: %{public}s', filePath);
      return null;
    }
  }

  private sendJson(client: socket.TCPSocketConnection, status: number, body: string): void {
    this.sendText(client, status, status === 200 ? 'OK' : 'Error', body, 'application/json; charset=utf-8');
  }

  private sendText(client: socket.TCPSocketConnection, status: number, statusText: string,
    body: string, contentType: string): void {
    const data: ArrayBuffer = this.stringToArrayBuffer(body);
    this.sendBytes(client, status, data, contentType);
  }

  private sendBytes(client: socket.TCPSocketConnection, status: number, body: ArrayBuffer,
    contentType: string): void {
    const reason: string = status === 200 ? 'OK' : (status === 404 ? 'Not Found' : 'Error');
    const head: string =
      `HTTP/1.1 ${status} ${reason}\r\n` +
      `Content-Type: ${contentType}\r\n` +
      `Content-Length: ${body.byteLength}\r\n` +
      `Access-Control-Allow-Origin: *\r\n` +
      `Connection: close\r\n\r\n`;
    const headData: ArrayBuffer = this.stringToArrayBuffer(head);
    const merged: ArrayBuffer = new ArrayBuffer(headData.byteLength + body.byteLength);
    const mergedView: Uint8Array = new Uint8Array(merged);
    mergedView.set(new Uint8Array(headData), 0);
    mergedView.set(new Uint8Array(body), headData.byteLength);
    const options: socket.TCPSendOptions = {
      data: merged
    };
    client.send(options).then(() => {
      client.close();
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'send response failed: %{public}s', JSON.stringify(err));
      client.close();
    });
  }

  private contentType(filePath: string): string {
    const lower: string = filePath.toLowerCase();
    if (lower.endsWith('.html')) return 'text/html; charset=utf-8';
    if (lower.endsWith('.js')) return 'application/javascript; charset=utf-8';
    if (lower.endsWith('.mjs')) return 'application/javascript; charset=utf-8';
    if (lower.endsWith('.css')) return 'text/css; charset=utf-8';
    if (lower.endsWith('.json')) return 'application/json; charset=utf-8';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.ico')) return 'image/x-icon';
    if (lower.endsWith('.woff')) return 'font/woff';
    if (lower.endsWith('.woff2')) return 'font/woff2';
    if (lower.endsWith('.ttf')) return 'font/ttf';
    if (lower.endsWith('.wasm')) return 'application/wasm';
    if (lower.endsWith('.map')) return 'application/json';
    return 'application/octet-stream';
  }

  private stringToArrayBuffer(text: string): ArrayBuffer {
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(text);
    const buffer: ArrayBuffer = new ArrayBuffer(encoded.byteLength);
    new Uint8Array(buffer).set(encoded);
    return buffer;
  }

  private arrayBufferToString(buffer: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(buffer);
    let result: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      result += String.fromCharCode(bytes[i]);
    }
    return result;
  }
}
