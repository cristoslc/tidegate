/**
 * test-echo-server.ts — Mock MCP server for end-to-end testing
 *
 * Exposes two tools: `echo` and `echo_system` matching the tidegate.yaml mapping.
 * Runs on port 4200 as Streamable HTTP so Tidegate can connect as an MCP client.
 *
 * Per-request McpServer+Transport pairs: each HTTP request gets its own
 * McpServer instance to avoid transport reuse conflicts in stateless mode.
 *
 * Usage: npx tsx test-echo-server.ts
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const PORT = 4200;

/**
 * Create a fresh McpServer with tools registered.
 * Called once per HTTP request.
 */
function createEchoServer(): McpServer {
  const server = new McpServer({
    name: "echo-test",
    version: "0.1.0",
  });

  server.tool(
    "echo",
    "Echo back the provided message",
    { message: z.string().describe("The message to echo") },
    async ({ message }) => ({
      content: [{ type: "text", text: `Echo: ${message}` }],
    })
  );

  server.tool(
    "echo_system",
    "Echo a message to a specific channel",
    {
      channel: z.string().describe("Target channel (e.g. #general)"),
      message: z.string().describe("The message to echo"),
    },
    async ({ channel, message }) => ({
      content: [{ type: "text", text: `[${channel}] Echo: ${message}` }],
    })
  );

  return server;
}

// ── HTTP server ───────────────────────────────────────────────

const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }

  if (req.url === "/mcp" && req.method === "POST") {
    const server = createEchoServer();
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
    });
    await server.connect(transport);

    const chunks: Buffer[] = [];
    for await (const chunk of req) {
      chunks.push(chunk as Buffer);
    }
    const body = JSON.parse(Buffer.concat(chunks).toString());

    await transport.handleRequest(req, res, body);
    return;
  }

  res.writeHead(404);
  res.end("Not found");
});

httpServer.listen(PORT, () => {
  console.error(`[echo-server] Listening on http://localhost:${PORT}/mcp`);
});
