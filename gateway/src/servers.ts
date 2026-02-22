/**
 * servers.ts — MCP client connections to downstream servers
 *
 * Zero knowledge of policy, scanning, or sessions.
 * Pure forwarding. Designed as clean boundary for potential future process separation.
 *
 * Manages persistent MCP client connections to downstream servers.
 * Pluggable: Streamable HTTP client or child process stdio.
 */

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import type { Tool, CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import type { ServerMapping } from "./policy.js";

interface DownstreamConnection {
  client: Client;
  transport: StreamableHTTPClientTransport | StdioClientTransport;
  tools: Tool[];
  connected: boolean;
}

const connections = new Map<string, DownstreamConnection>();

/**
 * Connect to a downstream MCP server.
 * Maintains the connection for reuse.
 */
export async function connect(
  serverName: string,
  serverConfig: ServerMapping
): Promise<void> {
  if (connections.has(serverName)) {
    const existing = connections.get(serverName)!;
    if (existing.connected) return;
  }

  const client = new Client({
    name: `tidegate-to-${serverName}`,
    version: "0.1.0",
  });

  let transport: StreamableHTTPClientTransport | StdioClientTransport;

  if (serverConfig.transport === "http") {
    if (!serverConfig.url) {
      throw new Error(`[servers] Server '${serverName}' has transport 'http' but no url`);
    }
    transport = new StreamableHTTPClientTransport(new URL(serverConfig.url));
  } else if (serverConfig.transport === "stdio") {
    if (!serverConfig.command) {
      throw new Error(`[servers] Server '${serverName}' has transport 'stdio' but no command`);
    }
    // Filter out undefined values from process.env before merging
    const mergedEnv = serverConfig.env
      ? Object.fromEntries(
          Object.entries({ ...process.env, ...serverConfig.env })
            .filter((entry): entry is [string, string] => entry[1] !== undefined)
        )
      : undefined;

    transport = new StdioClientTransport({
      command: serverConfig.command,
      args: serverConfig.args,
      env: mergedEnv,
    });
  } else {
    throw new Error(`[servers] Unknown transport for '${serverName}': ${serverConfig.transport}`);
  }

  await client.connect(transport);

  // Discover tools from downstream server
  const { tools } = await client.listTools();

  connections.set(serverName, {
    client,
    transport,
    tools,
    connected: true,
  });

  console.error(
    `[servers] Connected to '${serverName}' (${serverConfig.transport}), ${tools.length} tools discovered`
  );
}

/**
 * Forward a tool call to the named downstream server.
 * Returns the raw CallToolResult. No policy logic here.
 */
export async function forward(
  serverName: string,
  toolName: string,
  args: Record<string, unknown>
): Promise<CallToolResult> {
  const conn = connections.get(serverName);
  if (!conn?.connected) {
    throw new Error(`[servers] Not connected to server '${serverName}'`);
  }

  const result = await conn.client.callTool({
    name: toolName,
    arguments: args,
  });

  return result as CallToolResult;
}

/**
 * Get the tool list from a specific downstream server.
 */
export function getServerTools(serverName: string): Tool[] {
  const conn = connections.get(serverName);
  if (!conn) return [];
  return conn.tools;
}

/**
 * Get all tools from all connected downstream servers.
 */
export function getAllTools(): Map<string, Tool[]> {
  const result = new Map<string, Tool[]>();
  for (const [name, conn] of connections) {
    if (conn.connected) {
      result.set(name, conn.tools);
    }
  }
  return result;
}

/**
 * Disconnect from a specific server.
 */
export async function disconnect(serverName: string): Promise<void> {
  const conn = connections.get(serverName);
  if (!conn) return;

  try {
    await conn.client.close();
  } catch {
    // Best effort
  }
  conn.connected = false;
  connections.delete(serverName);
}

/**
 * Disconnect from all servers.
 */
export async function disconnectAll(): Promise<void> {
  for (const name of connections.keys()) {
    await disconnect(name);
  }
}
