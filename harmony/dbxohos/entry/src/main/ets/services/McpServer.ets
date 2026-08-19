import util from '@ohos.util';
import socket from '@ohos.net.socket';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xDB1;
const TAG = 'DBX_MCP';

interface ToolInfo {
  name: string;
  description: string;
  inputSchema: string;
}

/**
 * Minimal MCP (Model Context Protocol) server implemented in ArkTS.
 *
 * v1 returns static JSON-RPC responses for handshake and tools/list.
 * tools/call is a placeholder until the Rust dbx-mcp backend is integrated.
 */
export class McpServer {
  private static instance: McpServer = new McpServer();
  private tools: Array<ToolInfo> = [
    {
      name: 'dbx_list_connections',
      description: 'List DBX saved database connections.',
      inputSchema: '{}'
    },
    {
      name: 'dbx_schema_list',
      description: 'List schemas/tables of a DBX connection.',
      inputSchema: '{"type":"object","properties":{"connection":{"type":"string"}},"required":["connection"]}'
    },
    {
      name: 'dbx_query',
      description: 'Run a read-only SQL query on a DBX connection.',
      inputSchema: '{"type":"object","properties":{"connection":{"type":"string"},"sql":{"type":"string"},"limit":{"type":"number"}},"required":["connection","sql"]}'
    }
  ];

  static getInstance(): McpServer {
    return McpServer.instance;
  }

  handleHttpRequest(client: socket.TCPSocketConnection, method: string, path: string, body: string): void {
    if (method !== 'POST') {
      this.sendJson(client, 405, '{"jsonrpc":"2.0","error":{"code":-32600,"message":"Method Not Allowed"}}');
      return;
    }

    let rpcMethod: string = '';
    let id: number | undefined = undefined;
    try {
      const parsed = JSON.parse(body) as Record<string, object>;
      const methodValue: object | undefined = parsed['method'];
      rpcMethod = methodValue === undefined ? '' : String(methodValue);
      const idValue: object | undefined = parsed['id'];
      if (idValue !== undefined) {
        id = Number(idValue);
      }
    } catch (err) {
      this.sendJson(client, 400, '{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}');
      return;
    }

    if (!rpcMethod) {
      this.sendJson(client, 400, '{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"}}');
      return;
    }

    if (rpcMethod === 'initialize') {
      const responseBody: string =
        `{"jsonrpc":"2.0","id":${this.idText(id)},"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"dbx-mcp-ohos","version":"0.1.0"}}}`;
      this.sendJson(client, 200, responseBody);
      return;
    }

    if (rpcMethod === 'notifications/initialized') {
      this.sendJson(client, 202, '{}');
      return;
    }

    if (rpcMethod === 'tools/list') {
      const toolsJson: string = this.tools.map((tool: ToolInfo) => {
        return `{"name":"${tool.name}","description":"${tool.description}","inputSchema":${tool.inputSchema}}`;
      }).join(',');
      const responseBody: string = `{"jsonrpc":"2.0","id":${this.idText(id)},"result":{"tools":[${toolsJson}]}}`;
      this.sendJson(client, 200, responseBody);
      return;
    }

    if (rpcMethod === 'tools/call') {
      const responseBody: string =
        `{"jsonrpc":"2.0","id":${this.idText(id)},"result":{"content":[{"type":"text","text":"MCP tools/call is not implemented yet. Integrate Rust dbx-mcp backend to enable database operations."}],"isError":true}}`;
      this.sendJson(client, 200, responseBody);
      return;
    }

    const responseBody: string = `{"jsonrpc":"2.0","id":${this.idText(id)},"error":{"code":-32601,"message":"Method not found: ${rpcMethod}"}}`;
    this.sendJson(client, 200, responseBody);
  }

  private idText(id: number | undefined): string {
    return id === undefined ? 'null' : id.toString();
  }

  private sendJson(client: socket.TCPSocketConnection, status: number, text: string): void {
    const bodyData: ArrayBuffer = this.stringToArrayBuffer(text);
    const reason: string = status === 200 ? 'OK' : (status === 202 ? 'Accepted' : 'Error');
    const head: string =
      `HTTP/1.1 ${status} ${reason}\r\n` +
      `Content-Type: application/json; charset=utf-8\r\n` +
      `Content-Length: ${bodyData.byteLength}\r\n` +
      `Access-Control-Allow-Origin: *\r\n` +
      `Connection: close\r\n\r\n`;
    const headData: ArrayBuffer = this.stringToArrayBuffer(head);
    const merged: ArrayBuffer = new ArrayBuffer(headData.byteLength + bodyData.byteLength);
    const view: Uint8Array = new Uint8Array(merged);
    view.set(new Uint8Array(headData), 0);
    view.set(new Uint8Array(bodyData), headData.byteLength);
    const options: socket.TCPSendOptions = {
      data: merged
    };
    client.send(options).then(() => {
      client.close();
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'send MCP response failed: %{public}s', JSON.stringify(err));
      client.close();
    });
  }

  private stringToArrayBuffer(text: string): ArrayBuffer {
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(text);
    const buffer: ArrayBuffer = new ArrayBuffer(encoded.byteLength);
    new Uint8Array(buffer).set(encoded);
    return buffer;
  }
}
