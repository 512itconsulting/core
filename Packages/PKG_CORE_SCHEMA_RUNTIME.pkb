CREATE OR REPLACE PACKAGE BODY PKG_CORE_SCHEMA_RUNTIME
AS

  -- =========================================================================
  -- Private Procedures and Functions
  -- =========================================================================

   FUNCTION format_guid_f(ip_raw IN RAW)
      RETURN VARCHAR2
   IS
      l_hex VARCHAR2(32) := LOWER(RAWTOHEX(ip_raw));
   BEGIN
      RETURN SUBSTR(l_hex,1,8)||'-'||SUBSTR(l_hex,9,4)||'-'||SUBSTR(l_hex,13,4)
             ||'-'||SUBSTR(l_hex,17,4)||'-'||SUBSTR(l_hex,21,12);
   END format_guid_f;



   PROCEDURE assert_scope_p
   (
      ip_operation_id    IN VARCHAR2
    , ip_allowed_scopes  IN VARCHAR_TAB
   )
   IS
      l_count NUMBER;
   BEGIN
      SELECT COUNT(*)
        INTO l_count
        FROM core_operation_scope os
       WHERE os.operation_id = ip_operation_id
         AND os.scope_key IN (SELECT column_value FROM TABLE(ip_allowed_scopes));

      assert(l_count > 0, 'Operation does not hold a required scope for this call');
   END assert_scope_p;



   FUNCTION deploy_locked_f
      RETURN VARCHAR2
   IS
   BEGIN
      IF pkg_app_dict.exists_f('CORE', 'DEPLOY_LOCKED') THEN
         RETURN pkg_app_dict.get_val_f('CORE', 'DEPLOY_LOCKED');
      END IF;

      RETURN 'Y';
   END deploy_locked_f;



   FUNCTION capability_granted_f(ip_key IN VARCHAR2)
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN pkg_app_dict.exists_f('CORE', ip_key)
             AND pkg_app_dict.get_val_f('CORE', ip_key) = 'Y';
   END capability_granted_f;



   FUNCTION bound_runtime_id_f
      RETURN VARCHAR2
   IS
      l_runtime_id core_schema_runtime.runtime_id%TYPE;
   BEGIN
      SELECT runtime_id
        INTO l_runtime_id
        FROM core_schema_runtime
       WHERE binding_status = c_binding_status_bound;

      RETURN l_runtime_id;
   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         assert(FALSE, 'Schema has no bound runtime; call bind_schema_runtime_p first');
   END bound_runtime_id_f;



   -- Shared implementation for stage_runtime_revision_p and
   -- begin_runtime_removal_p. NULL/empty JSON stages an empty revision.
   PROCEDURE stage_revision_ip
   (
      ip_operation_id       IN  VARCHAR2
    , ip_attempt_number     IN  NUMBER
    , ip_fencing_token      IN  VARCHAR2
    , ip_contributions_json IN  CLOB
    , ip_requirements_json  IN  CLOB
    , ip_plan_digest        IN  VARCHAR2
    , ip_transition_status  IN  VARCHAR2
    , op_revision           OUT NUMBER
   )
   IS
      l_runtime_id     core_schema_runtime.runtime_id%TYPE;
      l_revision       core_runtime_revision.revision%TYPE;
      l_conflicts      NUMBER;
   BEGIN
      SAVEPOINT stage_revision_start;

      assert(ip_plan_digest IS NOT NULL, 'ip_plan_digest is required');

      pkg_core_operation.verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);
      assert_scope_p(ip_operation_id, VARCHAR_TAB(pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle));

      SELECT runtime_id, desired_revision + 1
        INTO l_runtime_id, l_revision
        FROM core_schema_runtime
       WHERE binding_status = c_binding_status_bound
         FOR UPDATE;

      INSERT INTO core_runtime_revision
      (
          runtime_id
        , revision
        , operation_id
        , attempt_number
        , plan_digest
        , revision_status
        , created_at
      )
      VALUES
      (
          l_runtime_id
        , l_revision
        , ip_operation_id
        , ip_attempt_number
        , ip_plan_digest
        , c_revision_status_staged
        , SYSTIMESTAMP
      );

      IF ip_contributions_json IS NOT NULL THEN
         BEGIN
            INSERT INTO core_runtime_contribution
            (
                runtime_id
              , revision
              , package_name
              , package_version
              , application_name
              , artifact_uri
              , artifact_checksum
              , checksum_algorithm
              , payload_digest
              , manifest_digest
            )
            SELECT l_runtime_id
                 , l_revision
                 , jt.package_name
                 , jt.package_version
                 , jt.application_name
                 , jt.artifact_uri
                 , jt.artifact_checksum
                 , jt.checksum_algorithm
                 , jt.payload_digest
                 , jt.manifest_digest
              FROM JSON_TABLE
                   (
                       ip_contributions_json, '$[*]'
                       COLUMNS
                       (
                           package_name       VARCHAR2(100)  PATH '$.package_name'
                         , package_version    VARCHAR2(100)  PATH '$.package_version'
                         , application_name   VARCHAR2(30)   PATH '$.application_name'
                         , artifact_uri       VARCHAR2(1000) PATH '$.artifact_uri'
                         , artifact_checksum  VARCHAR2(128)  PATH '$.artifact_checksum'
                         , checksum_algorithm VARCHAR2(20)   PATH '$.checksum_algorithm'
                         , payload_digest     VARCHAR2(128)  PATH '$.payload_digest'
                         , manifest_digest    VARCHAR2(128)  PATH '$.manifest_digest'
                       )
                   ) jt;
         EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
               ROLLBACK TO stage_revision_start;
               assert(FALSE, 'Duplicate package_name in contribution set: a revision may contain at most one contribution per package_name');
         END;
      END IF;

      IF ip_requirements_json IS NOT NULL THEN
         BEGIN
            INSERT INTO core_runtime_requirement
            (
                runtime_id
              , revision
              , owner_type
              , owner_key
              , requiring_application_name
              , package_name
              , package_version
              , requirement_type
            )
            SELECT l_runtime_id
                 , l_revision
                 , jt.owner_type
                 , jt.owner_key
                 , jt.requiring_application_name
                 , jt.package_name
                 , jt.package_version
                 , jt.requirement_type
              FROM JSON_TABLE
                   (
                       ip_requirements_json, '$[*]'
                       COLUMNS
                       (
                           owner_type                 VARCHAR2(20)  PATH '$.owner_type'
                         , owner_key                   VARCHAR2(100) PATH '$.owner_key'
                         , requiring_application_name  VARCHAR2(30)  PATH '$.requiring_application_name'
                         , package_name                VARCHAR2(100) PATH '$.package_name'
                         , package_version              VARCHAR2(100) PATH '$.package_version'
                         , requirement_type             VARCHAR2(20)  PATH '$.requirement_type'
                       )
                   ) jt;
         EXCEPTION
            WHEN OTHERS THEN
               ROLLBACK TO stage_revision_start;
               RAISE;
         END;

         -- Reject a version conflict: two requirements desiring different
         -- versions of the same package rather than one shared contribution.
         SELECT COUNT(*)
           INTO l_conflicts
           FROM core_runtime_requirement rq
           JOIN core_runtime_contribution rc
             ON rc.runtime_id = rq.runtime_id
            AND rc.revision   = rq.revision
            AND rc.package_name = rq.package_name
          WHERE rq.runtime_id = l_runtime_id
            AND rq.revision   = l_revision
            AND rq.package_version != rc.package_version;

         IF l_conflicts > 0 THEN
            ROLLBACK TO stage_revision_start;
            assert(FALSE, 'Version conflict: a requirement package_version does not match the desired contribution version for the same package_name');
         END IF;

         -- A MANUAL_RUNTIME_ROOT owner_key must match exactly one root contribution.
         FOR rec IN
         (
            SELECT DISTINCT owner_key
              FROM core_runtime_requirement
             WHERE runtime_id = l_runtime_id
               AND revision   = l_revision
               AND owner_type = c_owner_type_manual_runtime_root
         )
         LOOP
            SELECT COUNT(*)
              INTO l_conflicts
              FROM core_runtime_contribution
             WHERE runtime_id = l_runtime_id
               AND revision   = l_revision
               AND package_name = rec.owner_key;

            IF l_conflicts != 1 THEN
               ROLLBACK TO stage_revision_start;
               assert(FALSE, 'MANUAL_RUNTIME_ROOT owner_key '||rec.owner_key||' does not match exactly one root contribution');
            END IF;
         END LOOP;
      END IF;

      UPDATE core_schema_runtime
         SET desired_revision     = l_revision
           , transition_status    = ip_transition_status
           , current_operation_id = ip_operation_id
           , updated_at           = SYSTIMESTAMP
       WHERE runtime_id = l_runtime_id;

      COMMIT;

      op_revision := l_revision;
   EXCEPTION
      WHEN OTHERS THEN
         ROLLBACK TO stage_revision_start;
         RAISE;
   END stage_revision_ip;

  -- =========================================================================
  -- Public Procedures
  -- =========================================================================

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
   )
   IS
   BEGIN
      SELECT runtime_id, binding_status, prefix_identity, binding_token
           , desired_revision, active_revision, active_generation, active_receipt_checksum
           , transition_status, reachability_status, last_acknowledged_at, actor
        INTO op_runtime_id, op_binding_status, op_prefix_identity, op_binding_token
           , op_desired_revision, op_active_revision, op_active_generation, op_active_receipt_checksum
           , op_transition_status, op_reachability_status, op_last_acknowledged_at, op_actor
        FROM core_schema_runtime
       WHERE binding_status = c_binding_status_bound;
   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         NULL;
   END get_schema_runtime_p;



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
   )
   IS
      l_existing_id     core_schema_runtime.runtime_id%TYPE;
      l_existing_prefix core_schema_runtime.prefix_identity%TYPE;
      l_existing_token  core_schema_runtime.binding_token%TYPE;
      l_event_type      core_schema_runtime_audit.event_type%TYPE;
   BEGIN
      pkg_core_operation.verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);
      assert_scope_p(ip_operation_id, VARCHAR_TAB(pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle));

      assert(ip_prefix_identity IS NOT NULL, 'ip_prefix_identity is required');
      assert(UPPER(NVL(ip_rebind,'N')) IN ('Y','N'), 'ip_rebind must be Y or N');

      BEGIN
         SELECT runtime_id, prefix_identity, binding_token
           INTO l_existing_id, l_existing_prefix, l_existing_token
           FROM core_schema_runtime
          WHERE binding_status = c_binding_status_bound
            FOR UPDATE;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            l_existing_id := NULL;
      END;

      IF l_existing_id IS NOT NULL AND l_existing_prefix = ip_prefix_identity THEN
         op_runtime_id := l_existing_id;

         -- Idempotent verify of an unchanged binding: not itself audited.
         UPDATE core_schema_runtime
            SET actor      = NVL(ip_actor, actor)
              , updated_at = SYSTIMESTAMP
          WHERE runtime_id = l_existing_id
         RETURNING binding_token INTO op_binding_token;

         RETURN;
      END IF;

      IF l_existing_id IS NOT NULL THEN
         assert(UPPER(ip_rebind) = 'Y', 'A different runtime prefix is already bound; explicit rebind is required');
         assert(deploy_locked_f = 'N', 'Runtime rebind requires DEPLOY_LOCKED=N');
         assert(capability_granted_f('DBPM_ALLOW_RUNTIME_REPLACE'), 'Runtime rebind requires DBPM_ALLOW_RUNTIME_REPLACE=Y');

         UPDATE core_schema_runtime
            SET binding_status = c_binding_status_removed
              , updated_at     = SYSTIMESTAMP
          WHERE runtime_id = l_existing_id;

         l_event_type := 'REBIND';
      ELSE
         l_event_type := 'BIND';
      END IF;

      op_runtime_id    := format_guid_f(SYS_GUID());
      op_binding_token := LOWER(RAWTOHEX(SYS_GUID()));

      INSERT INTO core_schema_runtime
      (
          runtime_id
        , binding_status
        , prefix_identity
        , binding_token
        , desired_revision
        , transition_status
        , reachability_status
        , actor
        , created_at
        , updated_at
      )
      VALUES
      (
          op_runtime_id
        , c_binding_status_bound
        , ip_prefix_identity
        , op_binding_token
        , 0
        , c_transition_idle
        , c_reachability_unknown
        , ip_actor
        , SYSTIMESTAMP
        , SYSTIMESTAMP
      );

      INSERT INTO core_schema_runtime_audit
      (
          audit_id
        , runtime_id
        , event_type
        , operation_id
        , attempt_number
        , actor
        , old_prefix_identity
        , new_prefix_identity
        , old_binding_token
        , new_binding_token
        , changed_at
      )
      VALUES
      (
          core_schema_runtime_audit_seq.NEXTVAL
        , op_runtime_id
        , l_event_type
        , ip_operation_id
        , ip_attempt_number
        , ip_actor
        , l_existing_prefix
        , ip_prefix_identity
        , l_existing_token
        , op_binding_token
        , SYSTIMESTAMP
      );

      COMMIT;
   END bind_schema_runtime_p;



   PROCEDURE stage_runtime_revision_p
   (
      ip_operation_id       IN  VARCHAR2
    , ip_attempt_number     IN  NUMBER
    , ip_fencing_token      IN  VARCHAR2
    , ip_contributions_json IN  CLOB
    , ip_requirements_json  IN  CLOB
    , ip_plan_digest        IN  VARCHAR2
    , op_revision           OUT NUMBER
   )
   IS
   BEGIN
      assert(ip_contributions_json IS NOT NULL, 'ip_contributions_json is required; submit [] for an empty desired runtime');

      stage_revision_ip
      (
          ip_operation_id       => ip_operation_id
        , ip_attempt_number     => ip_attempt_number
        , ip_fencing_token      => ip_fencing_token
        , ip_contributions_json => ip_contributions_json
        , ip_requirements_json  => ip_requirements_json
        , ip_plan_digest        => ip_plan_digest
        , ip_transition_status  => c_transition_pending
        , op_revision           => op_revision
      );
   END stage_runtime_revision_p;



   PROCEDURE get_runtime_revision_p
   (
      ip_revision         IN  NUMBER
    , op_operation_id     OUT VARCHAR2
    , op_attempt_number   OUT NUMBER
    , op_plan_digest      OUT VARCHAR2
    , op_revision_status  OUT VARCHAR2
    , op_created_at       OUT TIMESTAMP WITH TIME ZONE
    , op_completed_at     OUT TIMESTAMP WITH TIME ZONE
   )
   IS
      l_runtime_id core_schema_runtime.runtime_id%TYPE := bound_runtime_id_f;
   BEGIN
      SELECT operation_id, attempt_number, plan_digest, revision_status, created_at, completed_at
        INTO op_operation_id, op_attempt_number, op_plan_digest, op_revision_status, op_created_at, op_completed_at
        FROM core_runtime_revision
       WHERE runtime_id = l_runtime_id
         AND revision   = ip_revision;
   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         NULL;
   END get_runtime_revision_p;



   PROCEDURE record_database_complete_p
   (
      ip_operation_id    IN VARCHAR2
    , ip_attempt_number  IN NUMBER
    , ip_fencing_token   IN VARCHAR2
    , ip_revision        IN NUMBER
   )
   IS
      l_runtime_id      core_schema_runtime.runtime_id%TYPE;
      l_desired         core_schema_runtime.desired_revision%TYPE;
      l_revision_status core_runtime_revision.revision_status%TYPE;
   BEGIN
      pkg_core_operation.verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);
      assert_scope_p(ip_operation_id, VARCHAR_TAB(pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle));

      SELECT runtime_id, desired_revision
        INTO l_runtime_id, l_desired
        FROM core_schema_runtime
       WHERE binding_status = c_binding_status_bound
         FOR UPDATE;

      assert(l_desired = ip_revision, 'ip_revision is not the schema''s current staged desired revision');

      SELECT revision_status
        INTO l_revision_status
        FROM core_runtime_revision
       WHERE runtime_id = l_runtime_id
         AND revision   = ip_revision;

      assert(l_revision_status = c_revision_status_staged, 'Revision '||ip_revision||' is '||l_revision_status||', not STAGED');

      UPDATE core_runtime_revision
         SET revision_status = c_revision_status_database_complete
       WHERE runtime_id = l_runtime_id
         AND revision   = ip_revision;

      COMMIT;
   END record_database_complete_p;



   PROCEDURE abandon_runtime_revision_p
   (
      ip_operation_id    IN VARCHAR2
    , ip_attempt_number  IN NUMBER
    , ip_fencing_token   IN VARCHAR2
    , ip_revision        IN NUMBER
   )
   IS
      l_runtime_id      core_schema_runtime.runtime_id%TYPE;
      l_desired         core_schema_runtime.desired_revision%TYPE;
      l_revision_status core_runtime_revision.revision_status%TYPE;
   BEGIN
      pkg_core_operation.verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);
      assert_scope_p(ip_operation_id, VARCHAR_TAB(pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle));

      SELECT runtime_id, desired_revision
        INTO l_runtime_id, l_desired
        FROM core_schema_runtime
       WHERE binding_status = c_binding_status_bound
         FOR UPDATE;

      assert(l_desired = ip_revision, 'ip_revision is not the schema''s current staged desired revision');

      SELECT revision_status
        INTO l_revision_status
        FROM core_runtime_revision
       WHERE runtime_id = l_runtime_id
         AND revision   = ip_revision;

      assert(
          l_revision_status IN (c_revision_status_staged, c_revision_status_database_complete)
        , 'Revision '||ip_revision||' is '||l_revision_status||', not abandonable'
      );

      UPDATE core_runtime_revision
         SET revision_status = c_revision_status_failed
           , completed_at    = SYSTIMESTAMP
       WHERE runtime_id = l_runtime_id
         AND revision   = ip_revision;

      UPDATE core_schema_runtime
         SET transition_status = c_transition_failed
           , updated_at        = SYSTIMESTAMP
       WHERE runtime_id = l_runtime_id;

      COMMIT;
   END abandon_runtime_revision_p;



   PROCEDURE acknowledge_runtime_active_p
   (
      ip_operation_id      IN VARCHAR2
    , ip_attempt_number    IN NUMBER
    , ip_fencing_token     IN VARCHAR2
    , ip_revision          IN NUMBER
    , ip_plan_digest       IN VARCHAR2
    , ip_generation        IN VARCHAR2
    , ip_receipt_checksum  IN VARCHAR2
   )
   IS
      l_runtime_id      core_schema_runtime.runtime_id%TYPE;
      l_desired         core_schema_runtime.desired_revision%TYPE;
      l_active          core_schema_runtime.active_revision%TYPE;
      l_stored_digest   core_runtime_revision.plan_digest%TYPE;
      l_revision_status core_runtime_revision.revision_status%TYPE;
   BEGIN
      pkg_core_operation.verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);
      assert_scope_p(ip_operation_id, VARCHAR_TAB(pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle));
      assert(ip_receipt_checksum IS NOT NULL, 'ip_receipt_checksum is required');

      SELECT runtime_id, desired_revision, active_revision
        INTO l_runtime_id, l_desired, l_active
        FROM core_schema_runtime
       WHERE binding_status = c_binding_status_bound
         FOR UPDATE;

      assert(l_desired = ip_revision, 'ip_revision is not the schema''s current staged desired revision');

      SELECT plan_digest, revision_status
        INTO l_stored_digest, l_revision_status
        FROM core_runtime_revision
       WHERE runtime_id = l_runtime_id
         AND revision   = ip_revision;

      assert(
          l_revision_status IN (c_revision_status_staged, c_revision_status_database_complete)
        , 'Revision '||ip_revision||' is '||l_revision_status||', not STAGED or DATABASE_COMPLETE'
      );
      assert(l_stored_digest = ip_plan_digest, 'Receipt contribution set does not match the staged plan_digest');

      INSERT INTO core_runtime_ack
      (
          ack_id
        , runtime_id
        , revision
        , operation_id
        , attempt_number
        , fencing_token
        , generation
        , receipt_checksum
        , acknowledgement_type
        , acknowledged_at
      )
      VALUES
      (
          core_runtime_ack_seq.NEXTVAL
        , l_runtime_id
        , ip_revision
        , ip_operation_id
        , ip_attempt_number
        , ip_fencing_token
        , ip_generation
        , ip_receipt_checksum
        , c_ack_type_active
        , SYSTIMESTAMP
      );

      IF l_active IS NOT NULL AND l_active != ip_revision THEN
         UPDATE core_runtime_revision
            SET revision_status = c_revision_status_superseded
              , completed_at    = SYSTIMESTAMP
          WHERE runtime_id = l_runtime_id
            AND revision   = l_active
            AND revision_status = c_revision_status_active;
      END IF;

      UPDATE core_runtime_revision
         SET revision_status = c_revision_status_active
           , completed_at    = SYSTIMESTAMP
       WHERE runtime_id = l_runtime_id
         AND revision   = ip_revision;

      UPDATE core_schema_runtime
         SET active_revision         = ip_revision
           , active_generation       = ip_generation
           , active_receipt_checksum = ip_receipt_checksum
           , transition_status       = c_transition_idle
           , reachability_status     = c_reachability_reachable
           , last_acknowledged_at    = SYSTIMESTAMP
           , updated_at              = SYSTIMESTAMP
       WHERE runtime_id = l_runtime_id;

      COMMIT;
   END acknowledge_runtime_active_p;



   PROCEDURE record_runtime_unreachable_p
   (
      ip_operation_id   IN VARCHAR2
    , ip_attempt_number IN NUMBER
    , ip_fencing_token  IN VARCHAR2
   )
   IS
      l_runtime_id core_schema_runtime.runtime_id%TYPE;
      l_desired    core_schema_runtime.desired_revision%TYPE;
   BEGIN
      pkg_core_operation.verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);
      assert_scope_p(ip_operation_id, VARCHAR_TAB(pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle));

      SELECT runtime_id, desired_revision
        INTO l_runtime_id, l_desired
        FROM core_schema_runtime
       WHERE binding_status = c_binding_status_bound
         FOR UPDATE;

      INSERT INTO core_runtime_ack
      (
          ack_id, runtime_id, revision, operation_id, attempt_number
        , fencing_token, acknowledgement_type, acknowledged_at
      )
      VALUES
      (
          core_runtime_ack_seq.NEXTVAL, l_runtime_id, l_desired, ip_operation_id, ip_attempt_number
        , ip_fencing_token, c_ack_type_unreachable, SYSTIMESTAMP
      );

      UPDATE core_schema_runtime
         SET reachability_status = c_reachability_unreachable
           , updated_at          = SYSTIMESTAMP
       WHERE runtime_id = l_runtime_id;

      COMMIT;
   END record_runtime_unreachable_p;



   PROCEDURE record_runtime_validated_p
   (
      ip_operation_id      IN VARCHAR2
    , ip_attempt_number    IN NUMBER
    , ip_fencing_token     IN VARCHAR2
    , ip_revision          IN NUMBER
    , ip_generation        IN VARCHAR2
    , ip_receipt_checksum  IN VARCHAR2
   )
   IS
      l_runtime_id core_schema_runtime.runtime_id%TYPE;
      l_desired    core_schema_runtime.desired_revision%TYPE;
   BEGIN
      pkg_core_operation.verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);
      assert_scope_p(ip_operation_id, VARCHAR_TAB(pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle));
      assert(ip_receipt_checksum IS NOT NULL, 'ip_receipt_checksum is required');

      SELECT runtime_id, desired_revision
        INTO l_runtime_id, l_desired
        FROM core_schema_runtime
       WHERE binding_status = c_binding_status_bound
         FOR UPDATE;

      assert(l_desired = ip_revision, 'Reconciliation targets the schema''s current desired revision, not an arbitrary prior revision');

      INSERT INTO core_runtime_ack
      (
          ack_id, runtime_id, revision, operation_id, attempt_number
        , fencing_token, generation, receipt_checksum, acknowledgement_type, acknowledged_at
      )
      VALUES
      (
          core_runtime_ack_seq.NEXTVAL, l_runtime_id, ip_revision, ip_operation_id, ip_attempt_number
        , ip_fencing_token, ip_generation, ip_receipt_checksum, c_ack_type_validated, SYSTIMESTAMP
      );

      UPDATE core_schema_runtime
         SET reachability_status  = c_reachability_reachable
           , last_acknowledged_at = SYSTIMESTAMP
           , updated_at           = SYSTIMESTAMP
       WHERE runtime_id = l_runtime_id;

      COMMIT;
   END record_runtime_validated_p;



   PROCEDURE begin_runtime_removal_p
   (
      ip_operation_id    IN  VARCHAR2
    , ip_attempt_number  IN  NUMBER
    , ip_fencing_token   IN  VARCHAR2
    , op_revision        OUT NUMBER
   )
   IS
   BEGIN
      assert(deploy_locked_f = 'N', 'Runtime removal requires DEPLOY_LOCKED=N');
      assert(capability_granted_f('DBPM_ALLOW_ENVIRONMENT_RESET'), 'Runtime removal requires DBPM_ALLOW_ENVIRONMENT_RESET=Y');

      stage_revision_ip
      (
          ip_operation_id       => ip_operation_id
        , ip_attempt_number     => ip_attempt_number
        , ip_fencing_token      => ip_fencing_token
        , ip_contributions_json => NULL
        , ip_requirements_json  => NULL
        , ip_plan_digest        => 'EMPTY-RUNTIME'
        , ip_transition_status  => c_transition_removal_pending
        , op_revision           => op_revision
      );
   END begin_runtime_removal_p;



   PROCEDURE acknowledge_runtime_removed_p
   (
      ip_operation_id      IN VARCHAR2
    , ip_attempt_number    IN NUMBER
    , ip_fencing_token     IN VARCHAR2
    , ip_revision          IN NUMBER
    , ip_generation        IN VARCHAR2
    , ip_receipt_checksum  IN VARCHAR2
   )
   IS
      l_runtime_id core_schema_runtime.runtime_id%TYPE;
      l_desired    core_schema_runtime.desired_revision%TYPE;
      l_active     core_schema_runtime.active_revision%TYPE;
      l_transition core_schema_runtime.transition_status%TYPE;
   BEGIN
      pkg_core_operation.verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);
      assert_scope_p(ip_operation_id, VARCHAR_TAB(pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle));

      SELECT runtime_id, desired_revision, active_revision, transition_status
        INTO l_runtime_id, l_desired, l_active, l_transition
        FROM core_schema_runtime
       WHERE binding_status = c_binding_status_bound
         FOR UPDATE;

      assert(l_transition = c_transition_removal_pending, 'Schema runtime does not have a removal pending');
      assert(l_desired = ip_revision, 'ip_revision is not the schema''s current staged removal revision');

      INSERT INTO core_runtime_ack
      (
          ack_id, runtime_id, revision, operation_id, attempt_number
        , fencing_token, generation, receipt_checksum, acknowledgement_type, acknowledged_at
      )
      VALUES
      (
          core_runtime_ack_seq.NEXTVAL, l_runtime_id, ip_revision, ip_operation_id, ip_attempt_number
        , ip_fencing_token, ip_generation, ip_receipt_checksum, c_ack_type_removed, SYSTIMESTAMP
      );

      IF l_active IS NOT NULL THEN
         UPDATE core_runtime_revision
            SET revision_status = c_revision_status_superseded
              , completed_at    = SYSTIMESTAMP
          WHERE runtime_id = l_runtime_id
            AND revision   = l_active
            AND revision_status = c_revision_status_active;
      END IF;

      UPDATE core_runtime_revision
         SET revision_status = c_revision_status_removed
           , completed_at    = SYSTIMESTAMP
       WHERE runtime_id = l_runtime_id
         AND revision   = ip_revision;

      UPDATE core_schema_runtime
         SET binding_status           = c_binding_status_removed
           , active_revision          = NULL
           , active_generation        = NULL
           , active_receipt_checksum  = NULL
           , transition_status        = c_transition_idle
           , last_acknowledged_at     = SYSTIMESTAMP
           , updated_at               = SYSTIMESTAMP
       WHERE runtime_id = l_runtime_id;

      COMMIT;
   END acknowledge_runtime_removed_p;



   PROCEDURE list_runtime_contributions_p
   (
      ip_revision      IN  NUMBER
    , op_contributions OUT SYS_REFCURSOR
   )
   IS
      l_runtime_id core_schema_runtime.runtime_id%TYPE := bound_runtime_id_f;
   BEGIN
      OPEN op_contributions FOR
         SELECT package_name, package_version, application_name
              , artifact_uri, artifact_checksum, checksum_algorithm
              , payload_digest, manifest_digest
           FROM core_runtime_contribution
          WHERE runtime_id = l_runtime_id
            AND revision   = ip_revision
          ORDER BY package_name;
   END list_runtime_contributions_p;



   PROCEDURE list_runtime_requirements_p
   (
      ip_revision     IN  NUMBER
    , op_requirements OUT SYS_REFCURSOR
   )
   IS
      l_runtime_id core_schema_runtime.runtime_id%TYPE := bound_runtime_id_f;
   BEGIN
      OPEN op_requirements FOR
         SELECT owner_type, owner_key, requiring_application_name
              , package_name, package_version, requirement_type
           FROM core_runtime_requirement
          WHERE runtime_id = l_runtime_id
            AND revision   = ip_revision
          ORDER BY owner_type, owner_key, package_name;
   END list_runtime_requirements_p;

END PKG_CORE_SCHEMA_RUNTIME;
/
