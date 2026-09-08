const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("store.zig");

/// Pure kernel state-machine operations. Authorization and transaction scopes
/// remain Runtime responsibilities; this module only validates and applies a
/// bounded transition to semantic state plus its immutable audit record.
pub fn validate(store: *const store_mod.Store, input: model.TransitionInput) !void {
    _ = store.constNode(input.target) orelse return error.UnknownNode;
    if (input.cause) |cause| if (store.constNode(cause) == null) return error.UnknownCause;
    if (input.reason.len == 0 or input.reason.len > 512 or input.actor.len == 0 or input.actor.len > 128 or input.receipt.len == 0 or input.receipt.len > 512) return error.InvalidTransition;
    if (!std.math.isFinite(input.amount) or input.amount < 0 or input.amount > 1) return error.InvalidTransition;
    switch (input.kind) {
        .set_state => if (input.target_state == null or input.amount != 0) return error.InvalidTransition,
        .reinforce, .penalize, .stabilize, .decay => if (input.target_state != null or input.amount == 0) return error.InvalidTransition,
    }
}

pub fn apply(store: *store_mod.Store, clock: *i64, next_transition_id: *u64, input: model.TransitionInput) !u64 {
    const target = store.node(input.target) orelse return error.UnknownNode;
    const prior_state = target.cognitive_state;
    const prior_confidence = target.confidence;
    const prior_strength = target.strength;
    switch (input.kind) {
        .set_state => target.cognitive_state = input.target_state.?,
        .reinforce => {
            target.confidence = @min(1, target.confidence + input.amount);
            target.strength = @min(1, target.strength + input.amount);
        },
        .penalize, .decay => {
            target.confidence *= 1 - input.amount;
            target.strength *= 1 - input.amount;
        },
        .stabilize => {
            target.cognitive_state = .active;
            target.strength = @min(1, target.strength + input.amount);
        },
    }
    clock.* = @max(clock.*, input.timestamp);
    const id = next_transition_id.*;
    next_transition_id.* += 1;
    try store.recordTransition(.{
        .id = id,
        .target = input.target,
        .cause = input.cause,
        .kind = input.kind,
        .prior_state = prior_state,
        .next_state = target.cognitive_state,
        .prior_confidence = prior_confidence,
        .next_confidence = target.confidence,
        .prior_strength = prior_strength,
        .next_strength = target.strength,
        .timestamp = input.timestamp,
        .reason = input.reason,
        .actor = input.actor,
        .receipt = input.receipt,
    });
    return id;
}
