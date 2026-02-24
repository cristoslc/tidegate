/**
 * Tidegate Gateway — Entry point
 *
 * Single Node.js process acting as both MCP server (upstream, for the agent)
 * and MCP client (downstream, connecting to real MCP servers).
 *
 * Startup sequence:
 * 1. Load tidegate.yaml config
 * 2. Connect to all downstream MCP servers
 * 3. Start upstream MCP server for agent connections
 */

import { loadConfig, type TidegateConfig } from "./policy.js";
import * as servers from "./servers.js";
import { startHost, stopHost } from "./host.js";
import { initScanner, stopScanner } from "./scanner.js";

const CONFIG_PATH = process.env["TIDEGATE_CONFIG"] ?? "tidegate.yaml";
const PORT = parseInt(process.env["TIDEGATE_PORT"] ?? "4100", 10);

async function main(): Promise<void> {
  console.error("[tidegate] Starting...");

  // 1. Load config
  let config: TidegateConfig;
  try {
    config = loadConfig(CONFIG_PATH);
    console.error(`[tidegate] Loaded config from ${CONFIG_PATH}`);
    console.error(
      `[tidegate] ${Object.keys(config.servers).length} server(s) configured: ${Object.keys(config.servers).join(", ")}`
    );
  } catch (err) {
    console.error(`[tidegate] Fatal: cannot load config from ${CONFIG_PATH}: ${err}`);
    process.exit(1);
  }

  // 2. Connect to downstream MCP servers
  for (const [serverName, serverConfig] of Object.entries(config.servers)) {
    try {
      await servers.connect(serverName, serverConfig);
    } catch (err) {
      console.error(
        `[tidegate] Failed to connect to '${serverName}': ${err instanceof Error ? err.message : String(err)}`
      );
      // Fail-closed: if we can't connect to a configured server, exit
      process.exit(1);
    }
  }

  // 3. Start Python scanner subprocess (L2/L3 leak detection)
  initScanner();

  // 4. Start upstream MCP server
  startHost(PORT);
  console.error(`[tidegate] Gateway ready. Agent connects to http://localhost:${PORT}/mcp`);

  // Graceful shutdown
  const shutdown = async () => {
    console.error("\n[tidegate] Shutting down...");
    await stopHost();
    stopScanner();
    await servers.disconnectAll();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error(`[tidegate] Fatal error: ${err}`);
  process.exit(1);
});
