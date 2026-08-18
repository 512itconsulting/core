--
-- PKG_CORE_SCHEMA_RUNTIME (Package)
--
CREATE OR REPLACE PACKAGE PKG_CORE_SCHEMA_RUNTIME
AS
--Usage:
-- Core's authority over the schema-wide dbpm runtime: one schema has zero or
-- one managed runtime, bound to one DBPM_RUNTIME_PREFIX. Core tracks the
-- desired contribution/requirement graph and the evidence dbpm reports after
-- filesystem activation. Core never reads or mutates the runtime filesystem;
-- see docs/core-schema-runtime-architecture.md for the full design.
--
-- Every mutating procedure here requires a fencing token from
-- PKG_CORE_OPERATION.begin_and_acquire_operation_p held under the SCHEMA_RUNTIME
-- scope (or SCHEMA_LIFECYCLE for schema-wide operations such as environment
-- reset). Callers use the module-level ip_operation_id/ip_attempt_number/
-- ip_fencing_token trio for every mutating call.
--
-- Typical install/upgrade flow:
--   1. begin_and_acquire_operation_p   -- SCHEMA_RUNTIME + affected APPLICATION scopes
--   2. bind_schema_runtime_p           -- once, or to verify the existing binding
--   3. stage_runtime_revision_p        -- submit the complete desired contribution/requirement set
--   4. (dbpm executes database + filesystem lifecycle work)
--   5. acknowledge_runtime_active_p    -- record the verified receipt evidence
--   6. release_operation_lease_p
--
-- Contributions and requirements are submitted as JSON arrays, validated
-- completely inside Core before any state changes:
--   contributions: [{package_name, package_version, application_name,
--                     artifact_uri, artifact_checksum, checksum_algorithm,
--                     payload_digest, manifest_digest}, ...]
--   requirements:  [{owner_type, owner_key, requiring_application_name,
--                     package_name, package_version, requirement_type}, ...]
--------------------------------------------------------------------------------
   c_binding_status_bound   CONSTANT CORE_SCHEMA_RUNTIME.binding_status%TYPE := 'BOUND';
   c_binding_status_removed CONSTANT CORE_SCHEMA_RUNTIME.binding_status%TYPE := 'REMOVED';

   c_transition_idle             CONSTANT CORE_SCHEMA_RUNTIME.transition_status%TYPE := 'IDLE';
   c_transition_pending          CONSTANT CORE_SCHEMA_RUNTIME.transition_status%TYPE := 'PENDING';
   c_transition_removal_pending  CONSTANT CORE_SCHEMA_RUNTIME.transition_status%TYPE := 'REMOVAL_PENDING';
   c_transition_failed           CONSTANT CORE_SCHEMA_RUNTIME.transition_status%TYPE := 'FAILED';

   c_reachability_unknown   CONSTANT CORE_SCHEMA_RUNTIME.reachability_status%TYPE := 'UNKNOWN';
   c_reachability_reachable CONSTANT CORE_SCHEMA_RUNTIME.reachability_status%TYPE := 'REACHABLE';
   c_reachability_unreachable CONSTANT CORE_SCHEMA_RUNTIME.reachability_status%TYPE := 'UNREACHABLE';

   c_revision_status_staged            CONSTANT CORE_RUNTIME_REVISION.revision_status%TYPE := 'STAGED';
   c_revision_status_database_complete CONSTANT CORE_RUNTIME_REVISION.revision_status%TYPE := 'DATABASE_COMPLETE';
   c_revision_status_active            CONSTANT CORE_RUNTIME_REVISION.revision_status%TYPE := 'ACTIVE';
   c_revision_status_superseded        CONSTANT CORE_RUNTIME_REVISION.revision_status%TYPE := 'SUPERSEDED';
   c_revision_status_removed           CONSTANT CORE_RUNTIME_REVISION.revision_status%TYPE := 'REMOVED';
   c_revision_status_failed            CONSTANT CORE_RUNTIME_REVISION.revision_status%TYPE := 'FAILED';

   c_owner_type_application         CONSTANT CORE_RUNTIME_REQUIREMENT.owner_type%TYPE := 'APPLICATION';
   c_owner_type_manual_runtime_root CONSTANT CORE_RUNTIME_REQUIREMENT.owner_type%TYPE := 'MANUAL_RUNTIME_ROOT';

   c_requirement_type_root        CONSTANT CORE_RUNTIME_REQUIREMENT.requirement_type%TYPE := 'ROOT';
   c_requirement_type_direct      CONSTANT CORE_RUNTIME_REQUIREMENT.requirement_type%TYPE := 'DIRECT';
   c_requirement_type_transitive  CONSTANT CORE_RUNTIME_REQUIREMENT.requirement_type%TYPE := 'TRANSITIVE';

   c_ack_type_active      CONSTANT CORE_RUNTIME_ACK.acknowledgement_type%TYPE := 'ACTIVE';
   c_ack_type_validated   CONSTANT CORE_RUNTIME_ACK.acknowledgement_type%TYPE := 'VALIDATED';
   c_ack_type_unreachable CONSTANT CORE_RUNTIME_ACK.acknowledgement_type%TYPE := 'UNREACHABLE';
   c_ack_type_removed     CONSTANT CORE_RUNTIME_ACK.acknowledgement_type%TYPE := 'REMOVED';

/**
 * @description Returns the current schema-runtime binding, if any. All OUT
 * params are NULL when the schema has no runtime.
 */
   PROCEDURE get_schema_runtime_p
   (
      op_runtime_id              OUT VARCHAR2
    , op_binding_status           OUT VARCHAR2
    , op_prefix_identity          OUT VARCHAR2
    , op_binding_token            OUT VARCHAR2
    , op_desired_revision         OUT NUMBER
    , op_active_revision          OUT NUMBER
    , op_active_generation        OUT VARCHAR2
    , op_active_receipt_checksum  OUT VARCHAR2
    , op_transition_status        OUT VARCHAR2
    , op_reachability_status      OUT VARCHAR2
    , op_last_acknowledged_at     OUT TIMESTAMP WITH TIME ZONE
    , op_actor                    OUT VARCHAR2
   );

/**
 * @description Creates the schema's one runtime binding, or verifies an
 * existing binding with the same prefix identity (idempotent no-op, not
 * audited). Replacing an already-bound prefix requires ip_rebind='Y' and,
 * per DEPLOY_LOCKED and DBPM_ALLOW_RUNTIME_REPLACE, retires the old binding
 * as a tombstone and issues a new runtime_id and binding_token. Requires a
 * fencing token held under the SCHEMA_RUNTIME or SCHEMA_LIFECYCLE scope, same
 * as every other mutating procedure in this package. Every actual bind or
 * rebind (not a same-prefix verify) is recorded in
 * CORE_SCHEMA_RUNTIME_AUDIT with the actor, operation, attempt, and old/new
 * prefix and binding_token. Commits.
 * @param ip_prefix_identity Canonical or opaque DBPM_RUNTIME_PREFIX identity. Never treated as executable.
 * @param ip_rebind 'Y' to authorize replacing an already-bound different prefix.
 */
   PROCEDURE bind_schema_runtime_p
   (
      ip_operation_id    IN  VARCHAR2
    , ip_attempt_number  IN  NUMBER
    , ip_fencing_token   IN  VARCHAR2
    , ip_prefix_identity IN  VARCHAR2
    , ip_actor           IN  VARCHAR2 DEFAULT NULL
    , ip_rebind          IN  VARCHAR2 DEFAULT 'N'
    , op_runtime_id      OUT VARCHAR2
    , op_binding_token   OUT VARCHAR2
   );

/**
 * @description Stages one complete, immutable desired runtime revision from a
 * normalized contribution and requirement set. Rejects a version conflict
 * (two requirements for the same package_name at different versions) rather
 * than producing sibling contributions. Requires a fencing token held under
 * the SCHEMA_RUNTIME scope. Advances CORE_SCHEMA_RUNTIME.desired_revision and
 * sets transition_status=PENDING. Does not claim filesystem activation occurred.
 * Commits.
 */
   PROCEDURE stage_runtime_revision_p
   (
      ip_operation_id       IN  VARCHAR2
    , ip_attempt_number     IN  NUMBER
    , ip_fencing_token      IN  VARCHAR2
    , ip_contributions_json IN  CLOB
    , ip_requirements_json  IN  CLOB
    , ip_plan_digest        IN  VARCHAR2
    , op_revision           OUT NUMBER
   );

/**
 * @description Returns header fields for one staged revision.
 */
   PROCEDURE get_runtime_revision_p
   (
      ip_revision         IN  NUMBER
    , op_operation_id     OUT VARCHAR2
    , op_attempt_number   OUT NUMBER
    , op_plan_digest      OUT VARCHAR2
    , op_revision_status  OUT VARCHAR2
    , op_created_at       OUT TIMESTAMP WITH TIME ZONE
    , op_completed_at     OUT TIMESTAMP WITH TIME ZONE
   );

/**
 * @description Checkpoints that the database-side lifecycle work for the
 * schema's current staged desired revision is complete, before filesystem
 * activation begins. Moves the revision from STAGED to DATABASE_COMPLETE.
 * A resumed operation that crashed after this call does not need to repeat
 * database lifecycle work, only filesystem activation. Commits.
 */
   PROCEDURE record_database_complete_p
   (
      ip_operation_id    IN VARCHAR2
    , ip_attempt_number  IN NUMBER
    , ip_fencing_token   IN VARCHAR2
    , ip_revision        IN NUMBER
   );

/**
 * @description Explicitly abandons the schema's current staged desired
 * revision (STAGED or DATABASE_COMPLETE only), marking it FAILED and setting
 * the schema's transition_status to FAILED. Core never infers abandonment;
 * a revision left STAGED or DATABASE_COMPLETE remains resumable until this
 * is called. Does not touch active_revision or its acknowledgement
 * evidence. Commits.
 */
   PROCEDURE abandon_runtime_revision_p
   (
      ip_operation_id    IN VARCHAR2
    , ip_attempt_number  IN NUMBER
    , ip_fencing_token   IN VARCHAR2
    , ip_revision        IN NUMBER
   );

/**
 * @description Records dbpm's verified activation evidence for the schema's
 * current staged desired revision, matching the receipt's contribution set
 * against the revision's plan_digest. Requires the revision to be STAGED or
 * DATABASE_COMPLETE. Makes the revision ACTIVE, supersedes the former active
 * revision, and completes the pending transition. Rejects a stale, expired,
 * or superseded fence, or a revision that is not the current desired
 * revision. Commits.
 */
   PROCEDURE acknowledge_runtime_active_p
   (
      ip_operation_id      IN VARCHAR2
    , ip_attempt_number    IN NUMBER
    , ip_fencing_token     IN VARCHAR2
    , ip_revision          IN NUMBER
    , ip_plan_digest       IN VARCHAR2
    , ip_generation        IN VARCHAR2
    , ip_receipt_checksum  IN VARCHAR2
   );

/**
 * @description Records that the runtime host was unreachable for the current
 * operation. Does not change the desired/active revision or the transition
 * state. Commits.
 */
   PROCEDURE record_runtime_unreachable_p
   (
      ip_operation_id   IN VARCHAR2
    , ip_attempt_number IN NUMBER
    , ip_fencing_token  IN VARCHAR2
   );

/**
 * @description Records reconciliation evidence that a live receipt was
 * checked against Core's records and found consistent. Targets the schema's
 * current desired revision only — reconciliation never validates an
 * arbitrary prior revision. Does not change desired_revision,
 * active_revision, or transition_status; only records evidence and marks
 * the host REACHABLE. Commits.
 */
   PROCEDURE record_runtime_validated_p
   (
      ip_operation_id      IN VARCHAR2
    , ip_attempt_number    IN NUMBER
    , ip_fencing_token     IN VARCHAR2
    , ip_revision          IN NUMBER
    , ip_generation        IN VARCHAR2
    , ip_receipt_checksum  IN VARCHAR2
   );

/**
 * @description Stages a new empty desired revision and sets
 * transition_status=REMOVAL_PENDING. Requires a fencing token held under the
 * SCHEMA_RUNTIME or SCHEMA_LIFECYCLE scope, plus DEPLOY_LOCKED=N and
 * DBPM_ALLOW_ENVIRONMENT_RESET=Y, per Invariant 10's requirement that
 * DEPLOY_LOCKED and missing lifecycle capabilities remain authoritative over
 * runtime removal. Commits.
 */
   PROCEDURE begin_runtime_removal_p
   (
      ip_operation_id    IN  VARCHAR2
    , ip_attempt_number  IN  NUMBER
    , ip_fencing_token   IN  VARCHAR2
    , op_revision        OUT NUMBER
   );

/**
 * @description Records dbpm's verified removal evidence. Clears the active
 * revision, marks the binding REMOVED (a tombstone), and returns the
 * transition to IDLE. Commits.
 */
   PROCEDURE acknowledge_runtime_removed_p
   (
      ip_operation_id      IN VARCHAR2
    , ip_attempt_number    IN NUMBER
    , ip_fencing_token     IN VARCHAR2
    , ip_revision          IN NUMBER
    , ip_generation        IN VARCHAR2
    , ip_receipt_checksum  IN VARCHAR2
   );

/**
 * @description Opens op_contributions over CORE_RUNTIME_CONTRIBUTION for one revision.
 */
   PROCEDURE list_runtime_contributions_p
   (
      ip_revision      IN  NUMBER
    , op_contributions OUT SYS_REFCURSOR
   );

/**
 * @description Opens op_requirements over CORE_RUNTIME_REQUIREMENT for one revision.
 */
   PROCEDURE list_runtime_requirements_p
   (
      ip_revision     IN  NUMBER
    , op_requirements OUT SYS_REFCURSOR
   );

END PKG_CORE_SCHEMA_RUNTIME;
/
