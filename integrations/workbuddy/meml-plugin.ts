import { homedir } from "node:os";
import { MemlClient, type AttestationIssuer, type MemlActivation, type VerifiedExecution } from "../meml-client.ts";

export type VerifiedWorkBuddyExecution = VerifiedExecution;

export type WorkBuddyMemlPlugin = {
  start(): Promise<void>;
  recall(input: { query: string; goal?: string; situation?: string; user?: string; limit?: number }): Promise<MemlActivation[]>;
  recordVerifiedExecution(input: VerifiedWorkBuddyExecution): Promise<number>;
  shutdown(): Promise<void>;
};

export function createWorkBuddyMemlPlugin(options: {
  statePath?: string;
  binary?: string;
  attestationIssuers?: readonly AttestationIssuer[];
  /** Explicit compatibility escape hatch; do not use for new deployments. */
  legacyReceiptVerifier?: { actor: string; receiptPrefix: string };
} = {}): WorkBuddyMemlPlugin {
  const client = new MemlClient({
    binary: options.binary,
    statePath: options.statePath ?? process.env.MEML_STATE_PATH ?? `${homedir()}/.meml/state/workbuddy.state`,
    attestationIssuers: options.attestationIssuers,
    legacyReceiptVerifier: options.legacyReceiptVerifier,
  });

  return {
    start: () => client.start(),
    recall: (input) => client.recall(input),
    recordVerifiedExecution: (input) => client.recordVerifiedExecution(input),
    shutdown: () => client.close(),
  };
}
