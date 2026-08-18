SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE

PROMPT Running PKG_CORE_SCHEMA_RUNTIME lifecycle checks

DECLARE
   c_prefix CONSTANT VARCHAR2(200) := '/opt/dbpm/check_core_schema_runtime_test_prefix';

   c_contrib CONSTANT CLOB :=
      '[{"package_name":"CHECK_PKG_A","package_version":"1.0.0","application_name":"CORE","payload_digest":"pd1","manifest_digest":"md1"},'||
      ' {"package_name":"CHECK_PKG_B","package_version":"2.0.0","payload_digest":"pd2","manifest_digest":"md2"}]';
   c_reqs CONSTANT CLOB :=
      '[{"owner_type":"APPLICATION","owner_key":"CORE","requiring_application_name":"CORE","package_name":"CHECK_PKG_A","package_version":"1.0.0","requirement_type":"DIRECT"},'||
      ' {"owner_type":"MANUAL_RUNTIME_ROOT","owner_key":"CHECK_PKG_B","package_name":"CHECK_PKG_B","package_version":"2.0.0","requirement_type":"ROOT"}]';

   l_runtime_id VARCHAR2(36);
   l_token      VARCHAR2(32);

   l_op   VARCHAR2(36);
   l_att  NUMBER;
   l_fence VARCHAR2(32);
   l_exp   TIMESTAMP WITH TIME ZONE;
   l_busy  VARCHAR2(1);
   l_busy_until TIMESTAMP WITH TIME ZONE;

   l_rev  NUMBER;
   l_rev2 NUMBER;
   l_rev3 NUMBER;
   l_rev4 NUMBER;

   l_b_runtime_id VARCHAR2(36);
   l_b_status     VARCHAR2(20);
   l_b_prefix     VARCHAR2(1000);
   l_b_token      VARCHAR2(32);
   l_b_desired    NUMBER;
   l_b_active     NUMBER;
   l_b_gen        VARCHAR2(100);
   l_b_checksum   VARCHAR2(128);
   l_b_transition VARCHAR2(20);
   l_b_reach      VARCHAR2(20);
   l_b_ack_at     TIMESTAMP WITH TIME ZONE;
   l_b_actor      VARCHAR2(128);

   l_r_op         VARCHAR2(36);
   l_r_att        NUMBER;
   l_r_digest     VARCHAR2(128);
   l_r_status     VARCHAR2(20);
   l_r_created_at TIMESTAMP WITH TIME ZONE;
   l_r_completed_at TIMESTAMP WITH TIME ZONE;

   l_ack_count NUMBER;

   l_allow_reset_exists BOOLEAN;
   l_allow_reset_value  app_dictionary.value%TYPE;
   l_allow_reset_note   app_dictionary.note%TYPE;

   l_allow_replace_exists BOOLEAN;
   l_allow_replace_value  app_dictionary.value%TYPE;
   l_allow_replace_note   app_dictionary.note%TYPE;

   c_rebind_prefix CONSTANT VARCHAR2(200) := '/opt/dbpm/check_core_schema_runtime_rebind_prefix';

   PROCEDURE release_if_leased
   IS
   BEGIN
      IF l_op IS NOT NULL THEN
         pkg_core_operation.release_operation_lease_p(l_op, l_att, l_fence);
      END IF;
   EXCEPTION
      WHEN OTHERS THEN NULL;
   END release_if_leased;

   PROCEDURE save_allow_reset
   IS
   BEGIN
      l_allow_reset_exists := pkg_app_dict.exists_f('CORE', 'DBPM_ALLOW_ENVIRONMENT_RESET');
      IF l_allow_reset_exists THEN
         SELECT value, note
           INTO l_allow_reset_value, l_allow_reset_note
           FROM app_dictionary
          WHERE application_name = 'CORE'
            AND key = 'DBPM_ALLOW_ENVIRONMENT_RESET';
      END IF;
   END save_allow_reset;

   PROCEDURE restore_allow_reset
   IS
   BEGIN
      IF l_allow_reset_exists THEN
         pkg_app_dict.merge_val_p('CORE', 'DBPM_ALLOW_ENVIRONMENT_RESET', l_allow_reset_value, l_allow_reset_note);
      ELSE
         pkg_app_dict.delete_val_p('CORE', 'DBPM_ALLOW_ENVIRONMENT_RESET');
      END IF;
   END restore_allow_reset;

   PROCEDURE save_allow_replace
   IS
   BEGIN
      l_allow_replace_exists := pkg_app_dict.exists_f('CORE', 'DBPM_ALLOW_RUNTIME_REPLACE');
      IF l_allow_replace_exists THEN
         SELECT value, note
           INTO l_allow_replace_value, l_allow_replace_note
           FROM app_dictionary
          WHERE application_name = 'CORE'
            AND key = 'DBPM_ALLOW_RUNTIME_REPLACE';
      END IF;
   END save_allow_replace;

   PROCEDURE restore_allow_replace
   IS
   BEGIN
      IF l_allow_replace_exists THEN
         pkg_app_dict.merge_val_p('CORE', 'DBPM_ALLOW_RUNTIME_REPLACE', l_allow_replace_value, l_allow_replace_note);
      ELSE
         pkg_app_dict.delete_val_p('CORE', 'DBPM_ALLOW_RUNTIME_REPLACE');
      END IF;
   END restore_allow_replace;
BEGIN
   save_allow_reset;
   save_allow_replace;

   pkg_core_operation.begin_and_acquire_operation_p(
      ip_primary_scope => pkg_core_operation.c_scope_schema_runtime,
      ip_participant_scopes => varchar_tab(pkg_core_operation.application_scope_f('CORE')),
      ip_actor => 'check_core_schema_runtime.sql', ip_lease_seconds => 120,
      op_operation_id => l_op, op_attempt_number => l_att, op_fencing_token => l_fence,
      op_lease_expires_at => l_exp, op_busy => l_busy, op_busy_until => l_busy_until
   );
   assert(l_busy = 'N', 'expected to acquire SCHEMA_RUNTIME scope');

   -- bind
   pkg_core_schema_runtime.bind_schema_runtime_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_prefix_identity => c_prefix,
      ip_actor => 'check_core_schema_runtime.sql',
      op_runtime_id => l_runtime_id, op_binding_token => l_token
   );

   SELECT COUNT(*)
     INTO l_ack_count
     FROM core_schema_runtime_audit
    WHERE runtime_id = l_runtime_id
      AND event_type = 'BIND'
      AND operation_id = l_op
      AND attempt_number = l_att
      AND actor = 'check_core_schema_runtime.sql'
      AND old_prefix_identity IS NULL
      AND new_prefix_identity = c_prefix;
   assert(l_ack_count = 1, 'expected one BIND audit row with operation/attempt/actor/old-new prefix');

   -- idempotent bind of the same prefix must be a no-op returning the same identity, and is not audited again.
   pkg_core_schema_runtime.bind_schema_runtime_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_prefix_identity => c_prefix,
      op_runtime_id => l_b_runtime_id, op_binding_token => l_b_token
   );
   assert(l_b_runtime_id = l_runtime_id, 'expected idempotent bind to return the same runtime_id');

   SELECT COUNT(*)
     INTO l_ack_count
     FROM core_schema_runtime_audit
    WHERE runtime_id = l_runtime_id;
   assert(l_ack_count = 1, 'expected idempotent verify-only bind to not add another audit row');

   pkg_core_schema_runtime.stage_runtime_revision_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_contributions_json => c_contrib, ip_requirements_json => c_reqs,
      ip_plan_digest => 'check-digest-v1', op_revision => l_rev
   );
   assert(l_rev = 1, 'expected first staged revision to be 1');

   -- record_database_complete_p checkpoints STAGED -> DATABASE_COMPLETE.
   pkg_core_schema_runtime.record_database_complete_p(l_op, l_att, l_fence, l_rev);
   pkg_core_schema_runtime.get_runtime_revision_p(
      l_rev, l_r_op, l_r_att, l_r_digest, l_r_status, l_r_created_at, l_r_completed_at
   );
   assert(l_r_status = 'DATABASE_COMPLETE', 'expected revision status DATABASE_COMPLETE after record_database_complete_p');

   -- acknowledge_runtime_active_p must still accept a DATABASE_COMPLETE revision.
   pkg_core_schema_runtime.acknowledge_runtime_active_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_revision => l_rev, ip_plan_digest => 'check-digest-v1',
      ip_generation => 'gen-1', ip_receipt_checksum => 'chk-1'
   );

   pkg_core_schema_runtime.get_schema_runtime_p(
      l_b_runtime_id, l_b_status, l_b_prefix, l_b_token, l_b_desired, l_b_active,
      l_b_gen, l_b_checksum, l_b_transition, l_b_reach, l_b_ack_at, l_b_actor
   );
   assert(l_b_active = l_rev, 'expected active_revision to equal the acknowledged revision');
   assert(l_b_actor = 'check_core_schema_runtime.sql', 'expected bind_schema_runtime_p to persist the actor');
   assert(l_b_transition = 'IDLE', 'expected transition_status IDLE after activation');
   assert(l_b_reach = 'REACHABLE', 'expected reachability_status REACHABLE after activation');

   -- record_runtime_validated_p records reconciliation evidence without changing state.
   pkg_core_schema_runtime.record_runtime_validated_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_revision => l_rev, ip_generation => 'gen-1', ip_receipt_checksum => 'chk-1'
   );

   SELECT COUNT(*)
     INTO l_ack_count
     FROM core_runtime_ack
    WHERE runtime_id = l_runtime_id
      AND revision = l_rev
      AND acknowledgement_type = 'VALIDATED';
   assert(l_ack_count = 1, 'expected one VALIDATED acknowledgement to be recorded');

   pkg_core_operation.release_operation_lease_p(l_op, l_att, l_fence);
   l_op := NULL;

   -- A requirement whose version disagrees with the desired contribution must be rejected.
   pkg_core_operation.begin_and_acquire_operation_p(
      ip_primary_scope => pkg_core_operation.c_scope_schema_runtime,
      op_operation_id => l_op, op_attempt_number => l_att, op_fencing_token => l_fence,
      op_lease_expires_at => l_exp, op_busy => l_busy, op_busy_until => l_busy_until
   );
   assert(l_busy = 'N', 'expected to reacquire SCHEMA_RUNTIME scope');

   BEGIN
      pkg_core_schema_runtime.stage_runtime_revision_p(
         ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
         ip_contributions_json => c_contrib,
         ip_requirements_json => '[{"owner_type":"APPLICATION","owner_key":"CORE","requiring_application_name":"CORE","package_name":"CHECK_PKG_A","package_version":"9.9.9","requirement_type":"DIRECT"}]',
         ip_plan_digest => 'check-digest-conflict', op_revision => l_rev2
      );
      raise_application_error(-20000, 'expected version conflict to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%Version conflict%' THEN
            NULL;
         ELSE
            RAISE;
         END IF;
   END;

   pkg_core_schema_runtime.get_schema_runtime_p(
      l_b_runtime_id, l_b_status, l_b_prefix, l_b_token, l_b_desired, l_b_active,
      l_b_gen, l_b_checksum, l_b_transition, l_b_reach, l_b_ack_at, l_b_actor
   );
   assert(l_b_desired = 1, 'expected desired_revision unchanged after a rejected stage');

   -- MANUAL_RUNTIME_ROOT owner_key must match exactly one root contribution.
   BEGIN
      pkg_core_schema_runtime.stage_runtime_revision_p(
         ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
         ip_contributions_json => '[{"package_name":"CHECK_PKG_C","package_version":"1.0.0"}]',
         ip_requirements_json => '[{"owner_type":"MANUAL_RUNTIME_ROOT","owner_key":"WRONG_NAME","package_name":"CHECK_PKG_C","package_version":"1.0.0","requirement_type":"ROOT"}]',
         ip_plan_digest => 'check-digest-badroot', op_revision => l_rev2
      );
      raise_application_error(-20000, 'expected MANUAL_RUNTIME_ROOT owner_key mismatch to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%does not match exactly one root contribution%' THEN
            NULL;
         ELSE
            RAISE;
         END IF;
   END;

   -- abandon_runtime_revision_p explicitly fails a stuck revision.
   pkg_core_schema_runtime.stage_runtime_revision_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_contributions_json => c_contrib, ip_requirements_json => c_reqs,
      ip_plan_digest => 'check-digest-v2', op_revision => l_rev2
   );
   assert(l_rev2 = 2, 'expected second staged revision to be 2');

   pkg_core_schema_runtime.abandon_runtime_revision_p(l_op, l_att, l_fence, l_rev2);

   pkg_core_schema_runtime.get_runtime_revision_p(
      l_rev2, l_r_op, l_r_att, l_r_digest, l_r_status, l_r_created_at, l_r_completed_at
   );
   assert(l_r_status = 'FAILED', 'expected abandoned revision status FAILED');

   pkg_core_schema_runtime.get_schema_runtime_p(
      l_b_runtime_id, l_b_status, l_b_prefix, l_b_token, l_b_desired, l_b_active,
      l_b_gen, l_b_checksum, l_b_transition, l_b_reach, l_b_ack_at, l_b_actor
   );
   assert(l_b_transition = 'FAILED', 'expected schema transition_status FAILED after abandon');
   assert(l_b_active = 1, 'expected active_revision unchanged by abandon');

   -- An abandoned (FAILED) revision can no longer be acknowledged active.
   BEGIN
      pkg_core_schema_runtime.acknowledge_runtime_active_p(
         ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
         ip_revision => l_rev2, ip_plan_digest => 'check-digest-v2',
         ip_generation => 'gen-2', ip_receipt_checksum => 'chk-2'
      );
      raise_application_error(-20000, 'expected acknowledge of an abandoned revision to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%not STAGED or DATABASE_COMPLETE%' THEN
            NULL;
         ELSE
            RAISE;
         END IF;
   END;

   -- Stage and activate a third, successful revision to leave the runtime active again.
   pkg_core_schema_runtime.stage_runtime_revision_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_contributions_json => c_contrib, ip_requirements_json => c_reqs,
      ip_plan_digest => 'check-digest-v3', op_revision => l_rev3
   );
   assert(l_rev3 = 3, 'expected third staged revision to be 3');

   pkg_core_schema_runtime.acknowledge_runtime_active_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_revision => l_rev3, ip_plan_digest => 'check-digest-v3',
      ip_generation => 'gen-3', ip_receipt_checksum => 'chk-3'
   );

   -- Rebind to a different prefix without ip_rebind='Y' must be rejected.
   BEGIN
      pkg_core_schema_runtime.bind_schema_runtime_p(
         ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
         ip_prefix_identity => c_rebind_prefix,
         op_runtime_id => l_b_runtime_id, op_binding_token => l_b_token
      );
      raise_application_error(-20000, 'expected rebind without ip_rebind=Y to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%explicit rebind is required%' THEN NULL; ELSE RAISE; END IF;
   END;

   -- Rebind without DBPM_ALLOW_RUNTIME_REPLACE=Y must be rejected.
   pkg_app_dict.delete_val_p('CORE', 'DBPM_ALLOW_RUNTIME_REPLACE');
   BEGIN
      pkg_core_schema_runtime.bind_schema_runtime_p(
         ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
         ip_prefix_identity => c_rebind_prefix, ip_rebind => 'Y',
         op_runtime_id => l_b_runtime_id, op_binding_token => l_b_token
      );
      raise_application_error(-20000, 'expected rebind without DBPM_ALLOW_RUNTIME_REPLACE to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%DBPM_ALLOW_RUNTIME_REPLACE%' THEN NULL; ELSE RAISE; END IF;
   END;

   -- Authorized rebind issues a new runtime_id/binding_token, tombstones the old
   -- binding, and is recorded as a REBIND audit row with the old and new values.
   pkg_app_dict.merge_val_p('CORE', 'DBPM_ALLOW_RUNTIME_REPLACE', 'Y', 'Test grant for check_schema_runtime.sql');

   pkg_core_schema_runtime.bind_schema_runtime_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_prefix_identity => c_rebind_prefix, ip_actor => 'check_core_schema_runtime.sql', ip_rebind => 'Y',
      op_runtime_id => l_b_runtime_id, op_binding_token => l_b_token
   );
   assert(l_b_runtime_id != l_runtime_id, 'expected rebind to issue a new runtime_id');
   assert(l_b_token != l_token, 'expected rebind to issue a new binding_token');

   SELECT COUNT(*)
     INTO l_ack_count
     FROM core_schema_runtime_audit
    WHERE runtime_id = l_b_runtime_id
      AND event_type = 'REBIND'
      AND operation_id = l_op
      AND actor = 'check_core_schema_runtime.sql'
      AND old_prefix_identity = c_prefix
      AND new_prefix_identity = c_rebind_prefix
      AND old_binding_token = l_token
      AND new_binding_token = l_b_token;
   assert(l_ack_count = 1, 'expected one REBIND audit row with old/new prefix and old/new binding_token');

   SELECT COUNT(*)
     INTO l_ack_count
     FROM core_schema_runtime
    WHERE runtime_id = l_runtime_id
      AND binding_status = 'REMOVED';
   assert(l_ack_count = 1, 'expected the old binding to be tombstoned after rebind');

   pkg_core_operation.release_operation_lease_p(l_op, l_att, l_fence);
   l_op := NULL;

   -- Removal must be rejected without DBPM_ALLOW_ENVIRONMENT_RESET=Y.
   pkg_app_dict.delete_val_p('CORE', 'DBPM_ALLOW_ENVIRONMENT_RESET');

   pkg_core_operation.begin_and_acquire_operation_p(
      ip_primary_scope => pkg_core_operation.c_scope_schema_runtime,
      op_operation_id => l_op, op_attempt_number => l_att, op_fencing_token => l_fence,
      op_lease_expires_at => l_exp, op_busy => l_busy, op_busy_until => l_busy_until
   );
   assert(l_busy = 'N', 'expected to reacquire SCHEMA_RUNTIME scope for removal');

   BEGIN
      pkg_core_schema_runtime.begin_runtime_removal_p(l_op, l_att, l_fence, l_rev4);
      raise_application_error(-20000, 'expected removal without DBPM_ALLOW_ENVIRONMENT_RESET to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%DBPM_ALLOW_ENVIRONMENT_RESET%' THEN
            NULL;
         ELSE
            RAISE;
         END IF;
   END;

   -- Removal flow, now explicitly authorized.
   pkg_app_dict.merge_val_p('CORE', 'DBPM_ALLOW_ENVIRONMENT_RESET', 'Y', 'Test grant for check_schema_runtime.sql');

   pkg_core_schema_runtime.begin_runtime_removal_p(l_op, l_att, l_fence, l_rev4);
   pkg_core_schema_runtime.acknowledge_runtime_removed_p(
      ip_operation_id => l_op, ip_attempt_number => l_att, ip_fencing_token => l_fence,
      ip_revision => l_rev4, ip_generation => 'gen-removed', ip_receipt_checksum => 'chk-removed'
   );
   pkg_core_operation.release_operation_lease_p(l_op, l_att, l_fence);
   l_op := NULL;

   restore_allow_reset;
   restore_allow_replace;

   pkg_core_schema_runtime.get_schema_runtime_p(
      l_b_runtime_id, l_b_status, l_b_prefix, l_b_token, l_b_desired, l_b_active,
      l_b_gen, l_b_checksum, l_b_transition, l_b_reach, l_b_ack_at, l_b_actor
   );
   assert(l_b_runtime_id IS NULL, 'expected no BOUND schema runtime after acknowledge_runtime_removed_p');

   DBMS_OUTPUT.PUT_LINE('PKG_CORE_SCHEMA_RUNTIME lifecycle checks passed');
EXCEPTION
   WHEN OTHERS THEN
      release_if_leased;
      restore_allow_reset;
      restore_allow_replace;
      RAISE;
END;
/

EXIT SUCCESS
