import { access, mkdir } from "node:fs/promises";
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { homedir } from "node:os";
import readline from "node:readline";

const MAX_REQUEST_BYTES = 60 * 1024;
const actor = process.env.MEML_ACTOR ?? "mcp-host";
const receiptPrefix = process.env.MEML_RECEIPT_PREFIX ?? "mcp-verified-";
const binary = process.env.MEML_BIN ?? "meml";
const statePath = resolve(process.env.MEML_STATE_PATH ?? `${homedir()}/.meml/state/mcp.state`);

class MemlBridge {
  process;
  pending = Promise.resolve();
  stdoutBuffer = "";
  responses = [];

  async start() {
    if (this.process) return;
    await mkdir(dirname(statePath), { recursive: true });
    this.process = spawn(binary, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.process.stdout.setEncoding("utf8");
    this.process.stdout.on("data", (chunk) => this.acceptStdout(chunk));
    this.process.stderr.resume();
    this.process.once("error", (error) => this.rejectAll(error));
    this.process.once("exit", (code, signal) => {
      this.process = undefined;
      this.rejectAll(new Error(`MEML CLI exited (${signal ?? code ?? "unknown"})`));
    });
    await this.call({ op: "ping" });
    await this.call({ op: "set_verifier", trusted_actors: [actor], receipt_prefix: receiptPrefix });
    try {
      await access(statePath);
      await this.call({ op: "recover", path: statePath });
      await this.call({ op: "set_verifier", trusted_actors: [actor], receipt_prefix: receiptPrefix });
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }

  async recall({ query, goal = "", situation = "", user = "", limit = 5 }) {
    await this.start();
    const response = await this.call({
      op: "activate",
      query,
      goal,
      situation,
      user,
      limit: Math.max(1, Math.min(Number.isFinite(limit) ? Math.trunc(limit) : 5, 20)),
      details: true,
    });
    return response.activations ?? [];
  }

  async close() {
    if (!this.process) return;
    try {
      await this.call({ op: "consolidate", repeat_threshold: 2 });
      await this.call({ op: "persist", path: statePath, atomic: true });
    } finally {
      this.process.stdin.end();
      this.process.kill();
      this.process = undefined;
    }
  }

  call(request) {
    const run = this.pending.then(() => this.writeAndRead(request));
    this.pending = run.then(() => undefined, () => undefined);
    return run;
  }

  writeAndRead(request) {
    if (!this.process) throw new Error("MEML bridge has not been started");
    const line = `${JSON.stringify(request)}\n`;
    if (Buffer.byteLength(line) > MAX_REQUEST_BYTES) throw new Error("MEML request exceeds the 60 KiB integration limit");
    return new Promise((resolveResponse, rejectResponse) => {
      this.responses.push(resolveResponse);
      this.process.stdin.write(line, "utf8", (error) => {
        if (!error) return;
        this.responses = this.responses.filter((item) => item !== resolveResponse);
        rejectResponse(error);
      });
    }).then((response) => {
      if (response.ok !== true) throw new Error(`MEML rejected request: ${String(response.error ?? "unknown error")}`);
      return response;
    });
  }

  acceptStdout(chunk) {
    this.stdoutBuffer += chunk;
    while (true) {
      const newline = this.stdoutBuffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.stdoutBuffer.slice(0, newline);
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      const resolveResponse = this.responses.shift();
      if (!resolveResponse || line.length === 0) continue;
      try {
        resolveResponse(JSON.parse(line));
      } catch {
        this.rejectAll(new Error("MEML CLI emitted invalid JSON"));
      }
    }
  }

  rejectAll(error) {
    const pending = this.responses;
    this.responses = [];
    for (const resolveResponse of pending) resolveResponse({ ok: false, error: error.message });
  }
}

const bridge = new MemlBridge();
const tools = [{
  name: "meml_recall",
  description: "Retrieve relevant, explainable MEML long-term memory before planning. Read-only; never executes actions or writes feedback.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    required: ["query"],
    properties: {
      query: { type: "string", minLength: 1, description: "Current task or question." },
      goal: { type: "string", description: "Optional intended outcome." },
      situation: { type: "string", description: "Optional project or execution context." },
      user: { type: "string", description: "Optional user or actor scope." },
      limit: { type: "integer", minimum: 1, maximum: 20, default: 5, description: "Maximum memories to return." },
    },
  },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
}];

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function success(id, result) {
  if (id !== undefined) send({ jsonrpc: "2.0", id, result });
}

function failure(id, code, message) {
  if (id !== undefined) send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handle(request) {
  if (!request || request.jsonrpc !== "2.0" || typeof request.method !== "string") return;
  const { id, method, params = {} } = request;
  try {
    if (method === "initialize") {
      return success(id, {
        protocolVersion: "2025-06-18",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "meml", version: "0.1.0" },
      });
    }
    if (method === "notifications/initialized") return;
    if (method === "ping") return success(id, {});
    if (method === "tools/list") return success(id, { tools });
    if (method === "tools/call") {
      if (params.name !== "meml_recall") return failure(id, -32602, `Unknown tool: ${String(params.name)}`);
      const args = params.arguments ?? {};
      if (typeof args.query !== "string" || args.query.trim().length === 0) return failure(id, -32602, "meml_recall requires a non-empty query");
      const activations = await bridge.recall(args);
      return success(id, {
        content: [{ type: "text", text: JSON.stringify({ activations }) }],
      });
    }
    return failure(id, -32601, `Method not found: ${method}`);
  } catch (error) {
    return failure(id, -32000, error instanceof Error ? error.message : "MEML MCP failure");
  }
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", (line) => {
  let request;
  try {
    request = JSON.parse(line);
  } catch {
    send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
    return;
  }
  void handle(request);
});
input.on("close", () => { void bridge.close(); });
process.once("SIGINT", () => { void bridge.close().finally(() => process.exit(0)); });
process.once("SIGTERM", () => { void bridge.close().finally(() => process.exit(0)); });
