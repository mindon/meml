import { access, mkdir } from "node:fs/promises";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { dirname, resolve } from "node:path";

export type JsonObject = Record<string, unknown>;

export type MemlActivation = {
  id: number;
  score: number;
  kind?: string;
  subject?: string;
  predicate?: string;
  object?: string;
  context?: string;
  result?: string;
  confidence?: number;
  signals: Record<string, number>;
};

export type MemlClientOptions = {
  binary?: string;
  statePath: string;
  actor: string;
  receiptPrefix: string;
};

const MAX_REQUEST_BYTES = 60 * 1024;

/** A serialized, long-lived JSONL client for the local MEML CLI. */
export class MemlClient {
  private readonly binary: string;
  private readonly statePath: string;
  private readonly actor: string;
  private readonly receiptPrefix: string;
  private process?: ChildProcessWithoutNullStreams;
  private pending = Promise.resolve();
  private stdoutBuffer = "";
  private responses: Array<(line: JsonObject) => void> = [];

  constructor(options: MemlClientOptions) {
    this.binary = options.binary ?? process.env.MEML_BIN ?? resolve(process.cwd(), "zig-out/bin/meml-cli");
    this.statePath = resolve(options.statePath);
    this.actor = options.actor;
    this.receiptPrefix = options.receiptPrefix;
  }

  async start(): Promise<void> {
    if (this.process) return;

    await mkdir(dirname(this.statePath), { recursive: true });
    this.process = spawn(this.binary, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.process.stdout.setEncoding("utf8");
    this.process.stdout.on("data", (chunk: string) => this.acceptStdout(chunk));
    this.process.stderr.setEncoding("utf8");
    this.process.once("error", (error) => this.rejectAll(error));
    this.process.once("exit", (code, signal) => {
      this.process = undefined;
      this.rejectAll(new Error(`MEML CLI exited (${signal ?? code ?? "unknown"})`));
    });

    await this.call({ op: "ping" });
    await this.call({ op: "set_verifier", trusted_actors: [this.actor], receipt_prefix: this.receiptPrefix });
    try {
      await access(this.statePath);
      await this.call({ op: "recover", path: this.statePath });
      await this.call({ op: "set_verifier", trusted_actors: [this.actor], receipt_prefix: this.receiptPrefix });
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }

  async recall(input: {
    query: string;
    goal?: string;
    situation?: string;
    user?: string;
    limit?: number;
  }): Promise<MemlActivation[]> {
    const response = await this.call({
      op: "activate",
      query: input.query,
      goal: input.goal ?? "",
      situation: input.situation ?? "",
      user: input.user ?? "",
      limit: Math.max(1, Math.min(input.limit ?? 5, 20)),
      details: true,
    });
    return (response.activations ?? []) as MemlActivation[];
  }

  async recordVerifiedExecution(input: {
    subject: string;
    predicate: string;
    object: string;
    context: string;
    result: string;
    timestamp: number;
    outcome: "success" | "failure";
    failureClass?: string;
    receipt: string;
  }): Promise<number> {
    this.assertReceipt(input.receipt);
    const observed = await this.call({
      op: "observe",
      subject: input.subject,
      predicate: input.predicate,
      object: input.object,
      context: input.context,
      result: input.result,
      timestamp: input.timestamp,
    });
    const id = observed.id;
    if (typeof id !== "number") throw new Error("MEML observe response has no numeric id");
    await this.call({
      op: "feedback",
      target: id,
      outcome: input.outcome,
      failure_class: input.failureClass ?? (input.outcome === "success" ? "none" : "unknown"),
      actor: this.actor,
      receipt: input.receipt,
      timestamp: input.timestamp,
    });
    return id;
  }

  async close(): Promise<void> {
    if (!this.process) return;
    try {
      await this.call({ op: "consolidate", repeat_threshold: 2 });
      await this.call({ op: "persist", path: this.statePath, atomic: true });
    } finally {
      this.process.stdin.end();
      this.process.kill();
      this.process = undefined;
    }
  }

  private assertReceipt(receipt: string): void {
    if (!receipt.startsWith(this.receiptPrefix)) {
      throw new Error(`Verified receipt must start with ${this.receiptPrefix}`);
    }
  }

  private call(request: JsonObject): Promise<JsonObject> {
    const run = this.pending.then(() => this.writeAndRead(request));
    this.pending = run.then(() => undefined, () => undefined);
    return run;
  }

  private writeAndRead(request: JsonObject): Promise<JsonObject> {
    if (!this.process) throw new Error("MEML client has not been started");
    const line = `${JSON.stringify(request)}\n`;
    if (Buffer.byteLength(line) > MAX_REQUEST_BYTES) throw new Error("MEML request exceeds the 60 KiB integration limit");

    return new Promise<JsonObject>((resolveResponse, rejectResponse) => {
      this.responses.push(resolveResponse);
      this.process!.stdin.write(line, "utf8", (error) => {
        if (!error) return;
        this.responses = this.responses.filter((item) => item !== resolveResponse);
        rejectResponse(error);
      });
    }).then((response) => {
      if (response.ok !== true) throw new Error(`MEML rejected request: ${String(response.error ?? "unknown error")}`);
      return response;
    });
  }

  private acceptStdout(chunk: string): void {
    this.stdoutBuffer += chunk;
    while (true) {
      const newline = this.stdoutBuffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.stdoutBuffer.slice(0, newline);
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      const resolveResponse = this.responses.shift();
      if (!resolveResponse || line.length === 0) continue;
      try {
        resolveResponse(JSON.parse(line) as JsonObject);
      } catch {
        this.rejectAll(new Error("MEML CLI emitted invalid JSON"));
      }
    }
  }

  private rejectAll(error: Error): void {
    const pending = this.responses;
    this.responses = [];
    for (const resolveResponse of pending) resolveResponse({ ok: false, error: error.message });
  }
}
