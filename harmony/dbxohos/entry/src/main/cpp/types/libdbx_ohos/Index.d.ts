export interface ServerOptions {
  port: number;
  staticDir: string;
  dataDir: string;
  disablePassword: boolean;
}

export function startServer(options: ServerOptions): number;
export function stopServer(): void;
export function startMcpServer(port: number): number;
export function stopMcpServer(): void;

declare const dbxOhos: {
  startServer(options: ServerOptions): number;
  stopServer(): void;
  startMcpServer(port: number): number;
  stopMcpServer(): void;
};

export default dbxOhos;
