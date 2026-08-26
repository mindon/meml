import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { MemlClient } from "../../../meml-client.ts";

export default function memlPlugin(pi: ExtensionAPI): void {
  const client = new MemlClient({
    statePath: process.env.MEML_STATE_PATH ?? ".meml/pi.state",
    actor: "pi-agent",
    receiptPrefix: "pi-verified-",
  });

  pi.registerTool({
    name: "meml_recall",
    label: "Recall MEML memory",
    description: "Retrieve relevant, explainable long-term memory before planning. This is read-only and never executes actions.",
    promptSnippet: "Recall relevant long-term memory before planning when prior context could change the answer.",
    parameters: Type.Object({
      query: Type.String({ description: "Current task or question to match against memory." }),
      goal: Type.Optional(Type.String({ description: "Optional intended outcome." })),
      situation: Type.Optional(Type.String({ description: "Optional project or execution context." })),
      limit: Type.Optional(Type.Number({ minimum: 1, maximum: 20, description: "Maximum memories to return." })),
    }),
    async execute(_toolCallId, params) {
      await client.start();
      const activations = await client.recall(params);
      return {
        content: [{ type: "text", text: JSON.stringify({ activations }) }],
        details: { activations },
      };
    },
  });

  pi.on("session_shutdown", async () => {
    await client.close();
  });
}
