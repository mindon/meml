import type { Context } from "@deepseek-ai/cordis";
import { homedir } from "node:os";
import { defineTool } from "@deepseek-ai/dsh-tools";
import { MemlClient } from "../../../meml-client.ts";

export const name = "meml-memory";
export const inject = ["tools"];

export function apply(ctx: Context): void {
  const client = new MemlClient({
    statePath: process.env.MEML_STATE_PATH ?? `${homedir()}/.meml/state/deepseek-harness.state`,
    actor: "deepseek-harness",
    receiptPrefix: "dsh-verified-",
  });

  ctx.tools.register(defineTool({
    name: "meml_recall",
    description: "Retrieve relevant, explainable MEML long-term memory before planning. Read-only; it never executes actions.",
    parameters: {
      query: { type: "string", required: true, description: "Current task or question." },
      goal: { type: "string", required: false, description: "Optional intended outcome." },
      situation: { type: "string", required: false, description: "Optional project or execution context." },
      limit: { type: "number", required: false, description: "Maximum memories to return, from 1 to 20." },
    },
    output: {
      schema: { type: "string" },
      render: (_args, value) => [{ type: "text", text: value }],
    },
    async execute(args) {
      await client.start();
      const limit = typeof args.limit === "number" ? Math.max(1, Math.min(args.limit, 20)) : undefined;
      const activations = await client.recall({ query: args.query, goal: args.goal, situation: args.situation, limit });
      return JSON.stringify({ activations });
    },
  }));

  ctx.effect(() => () => client.close());
}
