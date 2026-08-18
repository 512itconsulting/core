# Core Lifecycle Integration Follow-up

## Status

Deferred Core follow-up. Complete the dbpm-side development-lifecycle phases
described in [`development-lifecycle-design.md`](https://github.com/512itconsulting/dbpm/blob/main/docs/development-lifecycle-design.md)
(dbpm repo) before starting this work.

This document originated in the dbpm repo; it moved here because it
primarily specifies Core's implementation. A stub remains at
`dbpm/docs/core-operation-api-followup.md` pointing back to this copy.

## Decision

The Phase 2 implementation currently persists composite-operation state by
generating SQL that directly reads and writes namespaced `CORE` entries in
`APP_DICTIONARY`. This is an intentional temporary implementation boundary,
not the desired long-term interface.

After the current lifecycle work is complete, move operation persistence,
leases, fencing, attempts, and evidence behind a supported Core package API.
dbpm should orchestrate the lifecycle but should not own Core's transactional
state-management rules or depend on the physical layout of Core tables.

This follow-up also owns the Core-side administration and profile expansion
needed to make the lifecycle capability model convenient to configure. dbpm
already reads and fails closed on explicit `DBPM_ALLOW_*` keys; it does not
currently expand `DBPM_LIFECYCLE=DEVELOPER` or `DISPOSABLE`, and no package
manifest field should be introduced for target policy.

The schema-wide runtime registry and acknowledgement model are specified
separately in [`core-schema-runtime-architecture.md`](core-schema-runtime-architecture.md).
That architecture shares the operation API, fencing, policy, and audit boundary
defined here.

## Lifecycle capability profiles and provisioning

Core remains authoritative for target policy. Its supported administrative
surface must provision and audit these explicit keys:

```text
DBPM_ALLOW_MUTABLE_SOURCE
DBPM_ALLOW_SAME_VERSION_REPLACE
DBPM_ALLOW_RUNTIME_REPLACE
DBPM_ALLOW_GRAPH_RESET
DBPM_ALLOW_ENVIRONMENT_RESET
```

`DBPM_LIFECYCLE=DEVELOPER` and `DBPM_LIFECYCLE=DISPOSABLE` are convenience
profiles over those keys, not additional permissions and not package manifest
attributes. The Core implementation should expand a selected profile into the
corresponding explicit values through the same authoritative configuration
path dbpm reads. dbpm must continue enforcing only the resulting explicit
capabilities so profile use and individually managed keys cannot diverge into
parallel policy paths.

Before implementation, reconcile the final profile mapping with the design's
larger-blast-radius rule: graph reset and environment reset must retain the
explicit grants required by
[`development-lifecycle-design.md`](https://github.com/512itconsulting/dbpm/blob/main/docs/development-lifecycle-design.md#option-3-add-a-policy-gated-development-reset-workflow)
(dbpm repo),
and environment reset must never be implied by either convenience profile.

Core's administration mechanism must:

- restrict capability mutation through Core's existing administrative model;
- validate values and reject unknown profiles or non-`Y`/`N` capability data;
- record actor, time, previous value, and new value for every policy change;
- expose the effective explicit keys through a supported read API; and
- ensure `DEPLOY_LOCKED=Y` remains authoritative over every lifecycle profile
  and capability.

## Why this should move into Core

- Core is authoritative for installed application and deployment state.
- Lease acquisition, fencing, and attempt sequencing require database-local
  atomicity.
- Direct `APP_DICTIONARY` access couples dbpm to Core's storage schema.
- Repeating concurrency rules in generated SQL makes those rules harder to
  evolve and independently validate.
- Core procedures provide one supported authorization and auditing boundary.

The current split between beginning an operation and acquiring its first lease
also leaves a narrow first-operation race. Competing callers can create or
replace an unleased operation before either caller completes lease acquisition.
The current implementation fails loudly rather than silently corrupting state,
but the final Core API should remove the race entirely.

## Intended Core API

The exact package and type names may be selected with the Core maintainers, but
the supported surface should provide equivalents of:

```text
begin_and_acquire_operation
get_current_operation
renew_operation_lease
record_operation_step
release_operation_lease
```

`begin_and_acquire_operation` must atomically:

1. claim or validate the application's current-operation slot;
2. reject an existing unexpired lease;
3. create the durable operation record;
4. increment the attempt number;
5. assign the fencing token and lease expiry; and
6. commit the complete state transition.

Core should validate operation states, evidence names, lease tokens, lease
expiry, and legal state transitions. Callers must not be able to update an
operation using an expired or superseded fencing token.

## dbpm integration shape

dbpm should invoke the Core API through thin SQL*Plus/SQLcl-compatible calls.
Prefer direct procedure calls such as `EXEC package.procedure(...)` with
machine-readable results emitted by the Core API. Avoid embedding Core's DML,
locking, or transition logic in anonymous PL/SQL blocks generated by dbpm.

The migration should remove the following implementation knowledge from
`src/dbpm/db.py`:

- `DBPM_OP_*` and `DBPM_CURRENT_OP_*` key construction;
- direct `APP_DICTIONARY` DML;
- `SELECT ... FOR UPDATE` lease implementation;
- timestamp and fencing validation SQL;
- evidence-row storage details; and
- operation cleanup rules.

The Python-facing `OperationRecord` and `OperationLease` abstractions may remain
if they continue to match the supported Core API.

## Compatibility and migration

No dbpm release has ever shipped the transitional `APP_DICTIONARY`-based
`DBPM_OP_*`/`DBPM_CURRENT_OP_*` implementation; it exists only on the current
unreleased development branch. There is no production data to migrate and no
compatibility contract to preserve, so this follow-up needs no migration
layer:

- Introduce the Core API and switch dbpm to it as one coherent change; do not
  build dual-read compatibility for the transitional record format.
- Before upgrading a development database to the new Core API, any developer
  with an in-progress composite operation must let it complete or explicitly
  clear it (e.g. via `resume` or a direct cleanup of the transitional
  `CORE`-namespaced `APP_DICTIONARY` entries) under the old implementation
  first. This is a one-time development-environment step, not a supported
  upgrade path — it does not need to be automated or documented for end users.
- Once the Core API lands, delete the transitional `APP_DICTIONARY` read/write
  code from `db.py` outright rather than keeping it as a fallback.

## Acceptance criteria

This follow-up is complete when:

- Core provides a supported, audited administration path for all five
  lifecycle capability keys;
- `DBPM_LIFECYCLE=DEVELOPER` and `DISPOSABLE` expand deterministically to the
  documented explicit keys without bypassing separate high-blast-radius
  grants;
- dbpm reads effective lifecycle policy through a supported Core API rather
  than depending on profile strings or direct dictionary storage;
- dbpm performs no direct DML against Core operation storage;
- beginning an operation and acquiring its initial lease are atomic;
- concurrent acquisition tests run against the supported Core package API;
- expired and superseded fencing tokens are rejected inside Core;
- the transitional `APP_DICTIONARY`-based operation code is removed from
  `db.py` rather than kept as a fallback;
- Core owns validation of legal operation state transitions; and
- dbpm's generated SQL contains only supported Core API calls for composite
  operation management.
