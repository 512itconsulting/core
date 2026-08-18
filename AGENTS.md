# AGENTS.md

## Purpose

Core provides Oracle database deployment metadata, dependency tracking, object registration, and deployment lifecycle APIs.

## Rules

- All registry activity must go through pkg_application
- Never directly manipulate APPLICATION table
- Maintain backward compatibility where possible
- Prefer additive schema evolution
- Deployment scripts must be idempotent when feasible
- For normal application deployments after Core is installed, register deployment metadata, dependencies, privileges, owned objects, and metadata ownership before creating or replacing application objects
- Core's own initial deployment is a bootstrap exception because pkg_application does not exist yet
- Do not hard-code git commit hashes in committed deployment wrappers; prefer external injection by dbpm/orchestration from artifact metadata or repository state
- Treat delete_application_p before an initial deployment as a destructive reinstall operation, not as the default install path
- Destructive reinstall behavior should be explicit, gated for development/pre-prod use, and avoided for established environments unless the user clearly requests it

## Key Packages

- pkg_application
- pkg_core_operation (fenced operation leases; see docs/core-operation-api-followup.md)
- pkg_core_schema_runtime (schema-wide dbpm runtime registry; see docs/core-schema-runtime-architecture.md)

## Architecture

Core is intended to be a stable runtime/deployment substrate for dbpm and other deployment tooling.

dbpm should own artifact resolution, dependency ordering, provenance injection, and deployment mode selection. Core should remain the authoritative in-database registry for installed application state, deployment history, dependencies, privileges, object ownership, and cleanup metadata.
