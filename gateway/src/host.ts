/**
 * host.ts — MCP server over Streamable HTTP
 *
 * Exposes filtered tool list to the agent. Constructs shaped denies
 * as valid MCP tool results. This is the agent-facing interface.
 *
 * Uses the low-level Server class (not McpServer) for full control
 * over request handling — we intercept tools/list and tools/call
 * at the protocol level to inject the policy engine.
 *
 * Stateless mode: each HTTP request gets its own Server+Transport pair.
 * The Server is lightweight (just handler registrations), so per-request
 * creation is cheap and eliminates transport lifecycle issues.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import * as router from "./router.js";

let httpServer: ReturnType<typeof createServer> | null = null;

/**
 * Create a fresh MCP Server instance with handlers registered.
 * Called once per HTTP request in stateless mode to avoid
 * transport reuse conflicts in the SDK.
 */
function createMcpServer(): Server {
  const server = new Server(
    { name: "tidegate", version: "0.1.0" },
    {
      capabilities: {
        tools: {},
      },
    }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    const tools = router.getFilteredTools();
    return { tools };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    const result = await router.handleToolCall(name, args ?? {});
    return result;
  });

  return server;
}

/**
 * Create and start the upstream MCP server that agents connect to.
 */
export function startHost(port: number): void {
  httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    try {
      // Health check
      if (req.method === "GET" && req.url === "/health") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ status: "ok" }));
        return;
      }

      // MCP endpoint
      if (req.url === "/mcp") {
        // Handle POST (tool calls, initialization)
        if (req.method === "POST") {
          // Per-request Server+Transport: avoids "already connected" errors
          // and SSE stream lifecycle issues with shared server instances.
          const server = createMcpServer();
          const transport = new StreamableHTTPServerTransport({
            sessionIdGenerator: undefined, // Stateless mode
          });
          await server.connect(transport);

          // Read and parse body — malformed JSON returns 400, never crashes
          const chunks: Buffer[] = [];
          for await (const chunk of req) {
            chunks.push(chunk as Buffer);
          }

          let body: unknown;
          try {
            body = JSON.parse(Buffer.concat(chunks).toString());
          } catch {
            res.writeHead(400, { "Content-Type": "application/json" });
            res.end(JSON.stringify({
              jsonrpc: "2.0",
              error: { code: -32700, message: "Parse error: invalid JSON" },
              id: null,
            }));
            return;
          }

          await transport.handleRequest(req, res, body);
          return;
        }

        // Handle DELETE (session termination — not needed in stateless mode)
        if (req.method === "DELETE") {
          res.writeHead(405, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "Stateless mode — no sessions to terminate" }));
          return;
        }
      }

      // 404 for everything else
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Not found" }));
    } catch (err) {
      // Defense-in-depth: no single request should crash the gateway process
      console.error("[host] Unhandled error in request handler:", err);
      if (!res.headersSent) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({
          jsonrpc: "2.0",
          error: { code: -32603, message: "Internal server error" },
          id: null,
        }));
      }
    }
  });

  httpServer.listen(port, () => {
    console.error(`[host] Tidegate listening on port ${port}`);
  });
}

/**
 * Stop the host server.
 */
export function stopHost(): Promise<void> {
  return new Promise((resolve) => {
    if (httpServer) {
      httpServer.close(() => resolve());
    } else {
      resolve();
    }
  });
}
