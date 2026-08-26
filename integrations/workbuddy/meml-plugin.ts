import { MemlClient, type MemlActivation } from "../meml-client.ts";

export type VerifiedWorkBuddyExecution = {
  subject: string;
  predicate: string;
  object: string;
  context: string;
  result: string;
  timestamp: number;
  outcome: "success" | "failure";
  failureClass?: string;
  /** Must originate from WorkBuddy's authenticated tool-result verifier. */
  receipt: string;
};

export type WorkBuddyMemlPlugin = {
  start(): Promise<void>;
  recall(input: { query: string; goal?: string; situation?: string; user?: string; limit?: number }): Promise<MemlActivation[]>;
  recordVerifiedExecution(input: VerifiedWorkBuddyExecution): Promise<number>;
  shutdown(): Promise<void>;
};

export function createWorkBuddyMemlPlugin(options: {
  statePath?: string;
  binary?: string;
  actor?: string;
  receiptPrefix?: string;
} = {}): WorkBuddyMemlPlugin {
  const client = new MemlClient({
    binary: options.binary,
    statePath: options.statePath ?? ".meml/workbuddy.state",
    actor: options.actor ?? "workbuddy",
    receiptPrefix: options.receiptPrefix ?? "workbuddy-verified-",
  });

  return {
    start: () => client.start(),
    recall: (input) => client.recall(input),
    recordVerifiedExecution: (input) => client.recordVerifiedExecution(input),
    shutdown: () => client.close(),
  };
}
