import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const sharedServer = resolve(dirname(fileURLToPath(import.meta.url)), "../../../mcp/meml-mcp.mjs");
await import(sharedServer);
