# Schema Runtime Multi-Host Follow-up

## Status

Deferred follow-up. Sketch only — not scheduled, not implemented. Read
[`core-schema-runtime-architecture.md`](core-schema-runtime-architecture.md)
first; this document extends it and does not repeat its invariants except
where they change.

The base architecture ships with a single-host assumption stated as an
explicit non-goal: "This design does not support multiple runtime hosts for
one schema." This document sketches the extension that goal was written to
leave room for: identical runtime content, independently activated on more
than one host, for one schema.

Two competing shapes for that extension are captured below: a symmetric
multi-host model ("Data model changes" through "Fencing and concurrency")
where any host's acknowledgement can in principle affect schema-level state,
and a later, not-yet-reconciled alternative ("Alternative under
consideration: primary host + runtime-only clones") that avoids symmetry
altogether. Neither has been chosen. Do not implement either without
resolving that choice first.

This document originated in the dbpm repo alongside
`core-schema-runtime-architecture.md` and moved here with it. A stub remains
at `dbpm/docs/core-schema-runtime-multi-host-followup.md` pointing back to
this copy.

## Motivating scenario

Before the schema-runtime work, Core had no opinion about runtime hosts at
all, so nothing stopped an operator from pointing several identical
filesystem checkouts (behind a load balancer, or as warm standbys) at the
same database schema. Nothing enforced that model either — it worked only
because Core wasn't watching. The base architecture now binds one schema to
one `runtime_id`/`binding_token`/`prefix_identity`, which models one
filesystem location as authoritative. This document describes how to keep
that guarantee for the *desired* runtime while allowing more than one host to
independently hold and report *activation* of it.

## Decision

Keep `SCHEMA_RUNTIME` as the single owner of desired state: one binding, one
`runtime_id`, one contribution/requirement graph per revision, one
`desired_revision`. Do not duplicate the desired-state graph per host — every
host activating a given revision is activating the same
`plan_digest`-verified contribution set.

Split *activation evidence* out to a new per-host entity. A host's identity,
its last acknowledged generation/receipt checksum, and its reachability
become rows keyed by `(runtime_id, host_identity)`, not singleton columns on
`SCHEMA_RUNTIME`.

Reuse the existing fenced-operation model rather than inventing per-host
fencing. One `SCHEMA_RUNTIME`-scoped operation can span activation of
multiple hosts: dbpm orchestrates host activation sequentially or in
parallel under one lease, calling an acknowledgement procedure once per host
before releasing it. If per-host activation legitimately needs to outlive one
lease (e.g. large fleets, slow rollouts), that is a `renew_operation_lease_p`
/ resume concern already handled by the operation API, not a reason to add a
second fencing mechanism.

## Terminology additions

### Runtime host

One independently-activatable target for a schema's runtime content:
typically one machine or container identity. Identified by a
Core-verified `host_identity` plus a Core-issued `host_token`, mirroring how
`prefix_identity`/`binding_token` identify the schema-runtime binding itself.

### Convergence

The condition where every registered, non-retired runtime host has
acknowledged the schema's current desired revision as active. Convergence is
a computed fact, not stored state — see "What `active_revision` means" below.

## Data model changes

### `CORE_RUNTIME_HOST`

One row per registered host for a schema runtime.

| Field | Purpose |
| --- | --- |
| `runtime_id` | FK to `CORE_SCHEMA_RUNTIME`. |
| `host_identity` | dbpm-supplied opaque identity (hostname, container id, etc). Never treated as executable. |
| `host_token` | Core-generated collision-avoidance value, written into that host's local receipt. Not a secret, same posture as `binding_token`. |
| `host_status` | `ACTIVE` or `RETIRED`. A retired host is a tombstone, not deleted. |
| `active_revision` | Last revision this host acknowledged as active. |
| `active_generation` | This host's last acknowledged filesystem generation. |
| `active_receipt_checksum` | This host's last acknowledged receipt checksum. |
| `reachability_status` | `UNKNOWN`, `REACHABLE`, or `UNREACHABLE`, for this host only. |
| `last_acknowledged_at` | Timestamp of this host's latest valid acknowledgement. |
| `created_at`, `updated_at` | Audit timestamps. |

Unique on `(runtime_id, host_identity)` while `host_status = 'ACTIVE'`, using
the same function-based-unique-index idiom `CORE_SCHEMA_RUNTIME_UK1` already
uses for the one-bound-binding constraint, so a retired-and-re-registered
host doesn't collide with its own tombstone.

### `CORE_RUNTIME_ACK`

Add a nullable `host_identity` column. `NULL` means the acknowledgement was
schema-wide (removal, unreachable-at-the-schema-level); a populated value
scopes the acknowledgement to one host's activation. This table is already
append-only evidence, so this is an additive column, not a reshape.

### What `active_revision` means

This is the open question flagged in the base architecture's authority model,
and it needs an explicit answer before implementation, not an accidental one:

- **Recommended default:** `CORE_SCHEMA_RUNTIME.active_revision` becomes a
  computed convergence view — the revision every `ACTIVE`-status
  `CORE_RUNTIME_HOST` row currently reports, or `NULL` if hosts disagree or
  any host hasn't yet acknowledged the current desired revision. In the
  single-host topology this degrades to exactly today's behavior, since
  there's only ever one host to agree with itself.
- **Rejected alternative:** "active once any host acknowledges." This makes
  `active_revision` advance before a rollout finishes, which would make Phase
  4 auditing report a converged runtime while some hosts are still serving
  stale content — the opposite of what that field exists to guarantee.
- Consumers that need partial-rollout visibility (which hosts are on which
  revision, mid-rollout) use `list_runtime_hosts_p`, not
  `active_revision`. `active_revision` answers "is the whole runtime caught
  up," not "what's each host doing."

## Alternative under consideration: primary host + runtime-only clones

Early idea, captured verbatim from discussion, not reconciled with the
sections above, not decided. Revisit before implementing anything in this
document.

The idea: designate exactly one host per schema runtime as **primary**.
Only the primary does anything Core currently associates with dbpm —
staging revisions, application install/uninstall, everything that holds a
`SCHEMA_LIFECYCLE` or `APPLICATION:<name>` operation scope. Every other host
is a **runtime-clone**: it can only receive and activate runtime content. It
never stages a revision, never touches application lifecycle, never holds
any scope but (implicitly) participation in runtime activation.

This sidesteps the "what does `active_revision` mean when hosts disagree"
question rather than answering it. If only the primary ever changes desired
state or is treated as authoritative for it, `CORE_SCHEMA_RUNTIME.active_revision`
can stay exactly what it is in the base single-host architecture — the
primary's activation state, a singleton, no computed convergence view
required. Runtime-clones become purely additive: they register, activate,
and report their own evidence (still via something like
`CORE_RUNTIME_HOST`), but none of that feeds back into what "active" means
at the schema level. Schema-runtime removal simplifies the same way: only
the primary's state needs to gate the transition; clones don't block it and
don't need to acknowledge it.

This is a materially simpler model than the symmetric one above, if it
holds up. It has not been stress-tested. Known gaps, deliberately left open:

- **Enforcement.** Does Core need to structurally distinguish PRIMARY from
  CLONE (e.g. a `host_role` column, and refusing a clone-registered
  `host_identity` from ever backing a `SCHEMA_LIFECYCLE`/`APPLICATION`-scoped
  operation), or is the asymmetry purely an operational/dbpm-side
  convention — clones simply never get invoked with commands that would
  attempt those scopes, and Core never authenticates `host_identity` as a
  security principal in the first place? Leaning toward the latter
  (`host_identity` as an opaque label, same posture as `prefix_identity`,
  not a credential), but not decided.
- **Push vs. pull activation.** Does the primary's fenced operation
  orchestrate clone activation directly — one lease, primary pushes to N
  clones, each reports back before the lease releases, matching the
  single-operation model sketched under "Fencing and concurrency" above —
  or do clones independently poll `desired_revision` and self-activate under
  their own lease/schedule? This changes the fencing story materially and
  hasn't been chosen either way.
- **Relationship to the symmetric model above.** Does designating a primary
  *replace* the computed-convergence-view idea, or could the two coexist —
  e.g. convergence semantics apply only within a fleet of clones for
  observability, while `active_revision` still reflects the primary alone
  for authority purposes? Not decided.
- **Failover.** Does a clone ever get promoted to primary? If so, what does
  that transition need from Core — revoking the old primary's authority,
  re-fencing, re-keying `binding_token`? Not addressed at all yet.
- **Where the role lives.** Whether "runtime-clone" needs its own concept in
  schema at all (a role column on `CORE_RUNTIME_HOST`, say) or whether
  primary/clone stays entirely an out-of-band dbpm/operational convention
  that Core never represents. Bears on the enforcement question above but
  isn't identical to it.

## API additions

```text
register_runtime_host_p
deregister_runtime_host_p
list_runtime_hosts_p
```

`acknowledge_runtime_active_p` and `record_runtime_unreachable_p` gain an
`ip_host_identity`/`ip_host_token` pair, verified against `CORE_RUNTIME_HOST`
the same way `ip_operation_id`/`ip_fencing_token` are verified against
`CORE_OPERATION`. `acknowledge_runtime_removed_p` requires either zero
`ACTIVE`-status hosts remaining, or an explicit accompanying
`deregister_runtime_host_p` for every host, so a schema-runtime removal
can't silently strand a host's acknowledged state.

### `register_runtime_host_p`

- Requires a fencing token held under the `SCHEMA_RUNTIME` scope, same as
  `stage_runtime_revision_p`.
- Creates the host row, or verifies an existing `ACTIVE` row with the same
  `host_identity` (idempotent, same pattern as `bind_schema_runtime_p`).
- Returns `host_token` for dbpm to embed in that host's local receipt.

### `deregister_runtime_host_p`

- Marks a host `RETIRED`. Does not touch `desired_revision` or any other
  host's rows. A retired host's historical `CORE_RUNTIME_ACK` rows remain
  queryable evidence.

## Fencing and concurrency

No new scope is needed. `SCHEMA_RUNTIME` already serializes desired-state
transitions; host registration and per-host acknowledgement reuse that same
scope so a concurrent `stage_runtime_revision_p` can't race a host rollout.
Two hosts activating in parallel under the same operation is fine — they're
appending independent `CORE_RUNTIME_HOST` rows and `CORE_RUNTIME_ACK` rows,
not contending for the same row, so this doesn't need row-level fencing
beyond what `verify_fence_p` already provides for the shared operation.

## Compatibility with the single-host topology

Nothing here requires every deployment to register a host. A schema that
never calls `register_runtime_host_p` and instead calls
`acknowledge_runtime_active_p` without `ip_host_identity` should continue to
behave exactly as specified in the base architecture: `NULL` host identity
means "the implicit single host," and `SCHEMA_RUNTIME`'s singleton
`active_generation`/`active_receipt_checksum` columns stay populated exactly
as they are today. Multi-host is opt-in per schema, not a forced migration.

## Phase 4 auditing implications

Multi-host adds evidence categories the single-host audit tier can't
express: a host that never registered but has runtime content (unauthorized
host), a registered host that stopped acknowledging (silently dropped out of
the fleet), and partial convergence (some hosts on the new revision, some
still on the superseded one, past a reasonable rollout window). These map
naturally onto `CORE_RUNTIME_HOST.reachability_status` and
`last_acknowledged_at` staleness, but the staleness threshold is a dbpm/audit
policy input, not something Core should hardcode.

## Acceptance criteria (for whenever this is implemented)

- A schema runtime with zero registered hosts behaves identically to the
  base architecture's single-host model.
- Two or more hosts can independently register, activate, and report
  reachability for the same desired revision without contending on each
  other's rows.
- `active_revision` reflects full-fleet convergence, never a partial
  rollout, and this is enforced by how it's computed, not by caller
  discipline.
- Retiring a host never mutates `desired_revision`, another host's rows, or
  that host's own historical acknowledgement evidence.
- Schema-runtime removal cannot leave an `ACTIVE`-status host stranded with
  no corresponding removal evidence.
- Core still never reads or mutates the runtime filesystem, reads a path as
  executable, or infers ownership from `host_identity`'s spelling.

## Open questions

- Should `host_identity` uniqueness be schema-scoped (current sketch) or
  should Core also expose a cross-schema view for an operator managing many
  schemas across the same physical fleet? Leaning schema-scoped, matching
  Core's existing per-schema authority boundary, but this deserves a real
  answer from whoever needs the fleet-wide view, not a guess here.
- Does a host that fails to activate (stuck `PENDING` for that host only)
  need its own per-host `transition_status`, or is
  reachability-plus-last-acknowledged-revision sufficient signal? The sketch
  above omits a per-host transition column on the theory that comparing
  `active_revision` to the schema's `desired_revision` per host is enough,
  but this hasn't been stress-tested against a real rollout failure mode.
- Staleness threshold for "this host stopped acknowledging" — dbpm
  configuration, Core-side policy, or left entirely to the Phase 4 audit
  consumer? Recommend leaving it to the consumer, consistent with how Core
  already refuses to own retention duration or command-alias policy
  elsewhere in the base architecture, but flagging it since it's the kind of
  decision that's easy to accidentally bake into Core if unaddressed.
