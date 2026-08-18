--
-- PKG_CORE_OPERATION (Package)
--
CREATE OR REPLACE PACKAGE PKG_CORE_OPERATION
AS
--Usage:
-- Core's fenced-operation and lease API. A "scope" is a serialization unit:
-- SCHEMA_LIFECYCLE (the whole schema), SCHEMA_RUNTIME (the aggregate schema
-- runtime), or APPLICATION:<name> (one application's database state).
-- SCHEMA_LIFECYCLE conflicts with every other scope; SCHEMA_RUNTIME and
-- APPLICATION:<name> conflict with SCHEMA_LIFECYCLE and with themselves.
--
-- Typical caller flow:
--   1. begin_and_acquire_operation_p to claim a primary scope (and any
--      participant scopes) and obtain a fencing token.
--   2. record_operation_step_p to leave evidence as work progresses, and
--      renew_operation_lease_p if the work will outlive the initial lease.
--   3. release_operation_lease_p when the operation is done.
-- A caller that dies mid-operation leaves the lease to expire; the next
-- begin_and_acquire_operation_p for the same primary scope resumes the same
-- operation_id with an incremented attempt_number and a fresh fencing token.
--------------------------------------------------------------------------------
   c_scope_schema_lifecycle   CONSTANT VARCHAR2(30) := 'SCHEMA_LIFECYCLE';
   c_scope_schema_runtime     CONSTANT VARCHAR2(30) := 'SCHEMA_RUNTIME';
   c_scope_application_prefix CONSTANT VARCHAR2(30) := 'APPLICATION:';

   c_operation_status_active   CONSTANT CORE_OPERATION.operation_status%TYPE := 'ACTIVE';
   c_operation_status_released CONSTANT CORE_OPERATION.operation_status%TYPE := 'RELEASED';
   c_operation_status_expired  CONSTANT CORE_OPERATION.operation_status%TYPE := 'EXPIRED';

   c_lease_seconds_min CONSTANT NUMBER := 30;
   c_lease_seconds_max CONSTANT NUMBER := 3600;

/**
 * @description Builds the canonical APPLICATION:<name> scope key for an application.
 * @param ip_application_name Application to scope.
 */
   FUNCTION application_scope_f(ip_application_name IN VARCHAR2)
      RETURN VARCHAR2;

/**
 * @description Atomically claims a primary scope (and optional participant
 * scopes) as one fenced operation. Resumes and re-fences the existing
 * operation for the primary scope when its previous lease has expired;
 * otherwise creates a new operation. Never raises for ordinary contention:
 * a conflicting live lease is reported via op_busy instead. Commits on
 * success or on a busy result.
 * @param ip_primary_scope The scope this operation exists to protect.
 * @param ip_participant_scopes Additional scopes claimed atomically with the primary scope.
 * @param op_busy 'Y' when a conflicting scope is currently leased by another operation; all other OUT params are NULL in that case.
 */
   PROCEDURE begin_and_acquire_operation_p
   (
      ip_primary_scope      IN  VARCHAR2
    , ip_participant_scopes IN  VARCHAR_TAB DEFAULT NULL
    , ip_actor              IN  VARCHAR2 DEFAULT NULL
    , ip_lease_seconds      IN  NUMBER DEFAULT 300
    , op_operation_id       OUT VARCHAR2
    , op_attempt_number     OUT NUMBER
    , op_fencing_token      OUT VARCHAR2
    , op_lease_expires_at   OUT TIMESTAMP WITH TIME ZONE
    , op_busy               OUT VARCHAR2
    , op_busy_until         OUT TIMESTAMP WITH TIME ZONE
   );

/**
 * @description Returns the current operation, if any, for a primary scope.
 */
   PROCEDURE get_current_operation_p
   (
      ip_primary_scope     IN  VARCHAR2
    , op_operation_id      OUT VARCHAR2
    , op_attempt_number    OUT NUMBER
    , op_operation_status  OUT VARCHAR2
    , op_lease_expires_at  OUT TIMESTAMP WITH TIME ZONE
    , op_last_step_name    OUT VARCHAR2
    , op_last_step_status  OUT VARCHAR2
   );

/**
 * @description Raises an assertion error unless ip_operation_id/ip_attempt_number/
 * ip_fencing_token identify the current, active, unexpired lease. Callable by
 * other Core packages that need to verify a caller-presented fence before a
 * fenced mutation.
 */
   PROCEDURE verify_fence_p
   (
      ip_operation_id   IN VARCHAR2
    , ip_attempt_number IN NUMBER
    , ip_fencing_token  IN VARCHAR2
   );

/**
 * @description Extends the lease of an active, correctly-fenced operation. Commits.
 */
   PROCEDURE renew_operation_lease_p
   (
      ip_operation_id     IN  VARCHAR2
    , ip_attempt_number   IN  NUMBER
    , ip_fencing_token    IN  VARCHAR2
    , ip_lease_seconds    IN  NUMBER DEFAULT 300
    , op_lease_expires_at OUT TIMESTAMP WITH TIME ZONE
   );

/**
 * @description Records evidence for one named step of a fenced operation attempt.
 * Upserts CORE_OPERATION_STEP and updates CORE_OPERATION.last_step_name/status. Commits.
 */
   PROCEDURE record_operation_step_p
   (
      ip_operation_id   IN VARCHAR2
    , ip_attempt_number IN NUMBER
    , ip_fencing_token  IN VARCHAR2
    , ip_step_name      IN VARCHAR2
    , ip_step_status    IN VARCHAR2
    , ip_detail         IN VARCHAR2 DEFAULT NULL
   );

/**
 * @description Voluntarily releases a fenced operation's lease and frees its
 * claimed scopes immediately, rather than waiting for the lease to expire.
 * Commits.
 */
   PROCEDURE release_operation_lease_p
   (
      ip_operation_id   IN VARCHAR2
    , ip_attempt_number IN NUMBER
    , ip_fencing_token  IN VARCHAR2
   );

END PKG_CORE_OPERATION;
/
