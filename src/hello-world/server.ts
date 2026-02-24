/**
 * hello-world/server.ts — Demo MCP server for Tidegate
 *
 * A simple in-memory note-taking service that demonstrates all of
 * Tidegate's field-level policy enforcement:
 *
 *   - save_note:  category (system_param, enum-validated) + body (user_content, L1+L2+L3 scanned)
 *   - list_notes: category (system_param, optional filter)
 *   - get_note:   id (system_param, regex-validated UUID)
 *
 * No external dependencies — notes live in memory. Designed to show
 * how Tidegate inspects and enforces policy on tool calls before they
 * reach the MCP server.
 *
 * Usage: npx tsx hello-world/server.ts
 * Docker: see hello-world/Dockerfile
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { randomUUID } from "node:crypto";

const PORT = parseInt(process.env["PORT"] ?? "4300", 10);

// ── In-memory storage ────────────────────────────────────────

interface Note {
  id: string;
  category: string;
  body: string;
  createdAt: string;
}

const notes = new Map<string, Note>();

// Seed a couple of example notes
const seed1 = randomUUID();
const seed2 = randomUUID();
notes.set(seed1, {
  id: seed1,
  category: "work",
  body: "Review the Q3 security audit findings",
  createdAt: new Date().toISOString(),
});
notes.set(seed2, {
  id: seed2,
  category: "personal",
  body: "Pick up groceries on the way home",
  createdAt: new Date().toISOString(),
});

// ── MCP server factory ───────────────────────────────────────

const VALID_CATEGORIES = ["work", "personal", "ideas", "urgent"] as const;

function createNoteServer(): McpServer {
  const server = new McpServer({
    name: "hello-world-notes",
    version: "0.1.0",
  });

  // save_note: creates a new note
  // - category: system_param with enum validation
  // - body: user_content with full L1+L2+L3 scan
  server.tool(
    "save_note",
    "Save a new note in the specified category",
    {
      category: z
        .enum(VALID_CATEGORIES)
        .describe("Note category (work, personal, ideas, urgent)"),
      body: z
        .string()
        .min(1)
        .max(10000)
        .describe("The note content"),
    },
    async ({ category, body }) => {
      const id = randomUUID();
      const note: Note = {
        id,
        category,
        body,
        createdAt: new Date().toISOString(),
      };
      notes.set(id, note);
      return {
        content: [
          {
            type: "text",
            text: `Note saved. ID: ${id}, Category: ${category}, Length: ${body.length} chars`,
          },
        ],
      };
    }
  );

  // list_notes: lists notes, optionally filtered by category
  // - category: system_param, optional
  server.tool(
    "list_notes",
    "List all notes, optionally filtered by category",
    {
      category: z
        .enum(VALID_CATEGORIES)
        .optional()
        .describe("Filter by category (optional)"),
    },
    async ({ category }) => {
      let filtered = [...notes.values()];
      if (category) {
        filtered = filtered.filter((n) => n.category === category);
      }

      if (filtered.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: category
                ? `No notes found in category '${category}'.`
                : "No notes found.",
            },
          ],
        };
      }

      const lines = filtered.map(
        (n) =>
          `[${n.id}] (${n.category}) ${n.body.slice(0, 80)}${n.body.length > 80 ? "..." : ""}`
      );
      return {
        content: [
          {
            type: "text",
            text: `Found ${filtered.length} note(s):\n${lines.join("\n")}`,
          },
        ],
      };
    }
  );

  // get_note: retrieves a single note by UUID
  // - id: system_param with regex validation (UUID format)
  server.tool(
    "get_note",
    "Get a specific note by its ID",
    {
      id: z
        .string()
        .uuid()
        .describe("The note UUID"),
    },
    async ({ id }) => {
      const note = notes.get(id);
      if (!note) {
        return {
          content: [
            {
              type: "text",
              text: `Note not found: ${id}`,
            },
          ],
        };
      }

      return {
        content: [
          {
            type: "text",
            text: `Note ${note.id}:\n  Category: ${note.category}\n  Created: ${note.createdAt}\n  Body: ${note.body}`,
          },
        ],
      };
    }
  );

  return server;
}

// ── HTTP server ──────────────────────────────────────────────

const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  try {
    if (req.method === "GET" && req.url === "/health") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok", notes: notes.size }));
      return;
    }

    if (req.url === "/mcp" && req.method === "POST") {
      const server = createNoteServer();
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined,
      });
      await server.connect(transport);

      const chunks: Buffer[] = [];
      for await (const chunk of req) {
        chunks.push(chunk as Buffer);
      }

      let body: unknown;
      try {
        body = JSON.parse(Buffer.concat(chunks).toString());
      } catch {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Invalid JSON" }));
        return;
      }

      await transport.handleRequest(req, res, body);
      return;
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Not found" }));
  } catch (err) {
    console.error("[hello-world] Unhandled error:", err);
    if (!res.headersSent) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Internal server error" }));
    }
  }
});

httpServer.listen(PORT, () => {
  console.error(`[hello-world] Notes MCP server listening on http://localhost:${PORT}/mcp`);
  console.error(`[hello-world] ${notes.size} seed notes loaded`);
});
