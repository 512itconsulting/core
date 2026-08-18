# Changelog

Notable changes to Core are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Core follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file is a human-readable index. The authoritative record of what shipped
in each release is the `ip_notes` text passed to `pkg_application.begin_deployment_p`
in `Deployment_Manifests/deploy.sql` and `Deployment_Manifests/releases/*/update.sql`,
which is stored in the database itself. Keep both in sync when cutting a release.

## [Unreleased]

### Added

- Add `PKG_CORE_OPERATION`: Core-owned fenced operation leases, replacing the
  transitional `APP_DICTIONARY`-based `DBPM_OP_*` scheme with a supported API
  (`begin_and_acquire_operation_p`, `verify_fence_p`, `renew_operation_lease_p`,
  `record_operation_step_p`, `release_operation_lease_p`) and a scope
  hierarchy (`SCHEMA_LIFECYCLE`, `SCHEMA_RUNTIME`, `APPLICATION:<name>`).
- Add `PKG_CORE_SCHEMA_RUNTIME` and the schema-runtime registry
  (`CORE_SCHEMA_RUNTIME`, `CORE_RUNTIME_REVISION`, `CORE_RUNTIME_CONTRIBUTION`,
  `CORE_RUNTIME_REQUIREMENT`, `CORE_RUNTIME_ACK`): Core-owned authority over
  the one dbpm runtime binding per schema, desired/active revision tracking,
  and fenced activation/removal acknowledgement, per
  [`docs/core-schema-runtime-architecture.md`](docs/core-schema-runtime-architecture.md).
  New Core-owned tables and packages use a `CORE_` prefix to sort together
  and avoid colliding with installed-application object names in the shared
  schema.
- Add `record_database_complete_p` and `abandon_runtime_revision_p` so
  `CORE_RUNTIME_REVISION.revision_status` can reach `DATABASE_COMPLETE` and
  `FAILED`; `acknowledge_runtime_active_p` now requires `STAGED` or
  `DATABASE_COMPLETE`.
- Add `record_runtime_validated_p` and wire the `VALIDATED` acknowledgement
  type for reconciliation evidence.
- Persist and expose the actor on `bind_schema_runtime_p`
  (`CORE_SCHEMA_RUNTIME.ACTOR`), and record every bind/rebind in the new
  append-only `CORE_SCHEMA_RUNTIME_AUDIT` table with the authorizing
  operation, attempt, actor, and old/new prefix and binding token.
  `bind_schema_runtime_p` now requires a fencing token held under the
  `SCHEMA_RUNTIME`/`SCHEMA_LIFECYCLE` scope, same as every other mutating
  procedure in `PKG_CORE_SCHEMA_RUNTIME`.
- Add `PKG_APP_DICT.set_capability_p`, `apply_lifecycle_profile_p`, and
  `get_lifecycle_capabilities_p`: Core-owned administration for the five
  `DBPM_ALLOW_*` lifecycle capability keys and `DEVELOPER`/`DISPOSABLE`
  profile expansion, audited in the new `CORE_CAPABILITY_AUDIT` table, per
  [`docs/core-operation-api-followup.md`](docs/core-operation-api-followup.md)'s
  "Lifecycle capability profiles and provisioning" section.
  `DBPM_ALLOW_ENVIRONMENT_RESET` is never implied by either profile, and
  `DBPM_ALLOW_GRAPH_RESET` is granted only by `DISPOSABLE`.
- Add `docs/core-schema-runtime-architecture.md`, `docs/core-operation-api-followup.md`,
  and `docs/core-schema-runtime-multi-host-followup.md` (moved here from the
  dbpm repo, which primarily specify Core's implementation).

### Changed

- Gate `begin_runtime_removal_p` behind `DEPLOY_LOCKED=N` and
  `DBPM_ALLOW_ENVIRONMENT_RESET=Y`, per Invariant 10 of the schema-runtime
  architecture.

## [3.5.0] - 2026-07-04

### Added

- Add `DEPLOY_LOCKED` deployment safety metadata.
- Add manual deployment env generation for non-dbpm installs.

### Changed

- Gate `pkg_application.delete_system_p` behind confirmation and
  `DEPLOY_LOCKED`.
- Make the `DEPLOY_LOCKED` package helper initial-config only.

## [3.4.2] - 2026-06-03

### Changed

- Publish Core under the 512itconsulting dbpm registry publisher.

## [3.4.1] - 2026-06-02

### Changed

- Prevent lower-version deployments.
- Add serialized version component bounds checks.

## [3.4.0] - 2026-05-26

### Added

- Add `pkg_application.record_deployment_provenance_p`.

## [3.3.0] - 2026-05-26

### Added

- Add `pkg_application.get_deployment_provenance_json_f`. Includes the
  initial deploy and update path.

## [3.2.0] - 2026-05-25

### Added

- Add `APP_DEPLOY_PROVENANCE_PENDING`.
- Add `pkg_application.stage_deployment_provenance_p`.
- Consume pending deployment provenance from
  `pkg_application.begin_deployment_p`.

## [3.1.0] - 2026-05-25

### Added

- Add `APP_DEPLOY_PROVENANCE`.
- Add `pkg_application.begin_artifact_deployment_p`.

## [3.0.0] - 2025-07-23

### Added

- Add table `SYSTEM_LOG`.
- Add `PKG_SYSLOG`.

### Removed

- Drop `PKG_ERROR_UTIL`.
- Drop table `ERROR_LOG`.

## [2.5.0] - 2025-07-17

### Added

- Add `VARCHAR_TAB`.
- Add `PKG_STRING`.

## [2.4.0] - 2025-05-20

### Added

- Add `pkg_application.serialize_version_f`.
- Add `pkg_application.deserialize_version_f`.

## [2.3.0] - 2025-05-14

### Added

- Add `"MATERIALIZED VIEW"` object type.
- Add `pkg_application.drop_and_forget_object_p`.
- Add `pkg_application.change_object_application_p`.

## [2.2.0] - 2025-04-16

### Changed

- Replace the `APP_OBJECT_METADATA` table with a new structure.
- Modify `pkg_application` to update `add_object_metadata_p`, add
  `delete_object_metadata_p`, and call `delete_object_metadata_p` from
  within `delete_application_p`.

## [2.1.0] - 2025-02-05

### Added

- Add the table `APP_DEPLOY_NOTES`.
- Add `pkg_application.get_current_version_f`.
- Add `pkg_application.set_deploy_notes_p`.

## [2.0.0] - 2025-02-04

### Added

- Add support for semantic versioning (major, minor, patch).
