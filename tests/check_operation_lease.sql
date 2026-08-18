SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE

PROMPT Running PKG_CORE_OPERATION lease/fencing checks

DECLARE
   c_app CONSTANT VARCHAR2(30) := 'CHECK_OP_LEASE_APP';

   l_op1   VARCHAR2(36);
   l_att1  NUMBER;
   l_tok1  VARCHAR2(32);
   l_exp1  TIMESTAMP WITH TIME ZONE;
   l_busy  VARCHAR2(1);
   l_busy_until TIMESTAMP WITH TIME ZONE;

   l_op2   VARCHAR2(36);
   l_att2  NUMBER;
   l_tok2  VARCHAR2(32);
   l_exp2  TIMESTAMP WITH TIME ZONE;

   PROCEDURE cleanup
   IS
   BEGIN
      DELETE FROM core_operation_scope WHERE scope_key IN (pkg_core_operation.application_scope_f(c_app), pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle);
      DELETE FROM core_operation_step WHERE operation_id IN (l_op1, l_op2);
      DELETE FROM core_operation WHERE primary_scope IN (pkg_core_operation.application_scope_f(c_app), pkg_core_operation.c_scope_schema_runtime, pkg_core_operation.c_scope_schema_lifecycle);
      COMMIT;
   END cleanup;
BEGIN
   cleanup;

   -- Claim SCHEMA_RUNTIME with a participant application scope.
   pkg_core_operation.begin_and_acquire_operation_p(
      ip_primary_scope => pkg_core_operation.c_scope_schema_runtime,
      ip_participant_scopes => varchar_tab(pkg_core_operation.application_scope_f(c_app)),
      ip_actor => 'check_operation_lease.sql',
      ip_lease_seconds => 60,
      op_operation_id => l_op1, op_attempt_number => l_att1, op_fencing_token => l_tok1,
      op_lease_expires_at => l_exp1, op_busy => l_busy, op_busy_until => l_busy_until
   );
   assert(l_busy = 'N', 'expected initial acquire to succeed');
   assert(l_att1 = 1, 'expected attempt 1 on first acquire');

   -- A conflicting acquire of the participant application scope must be busy.
   pkg_core_operation.begin_and_acquire_operation_p(
      ip_primary_scope => pkg_core_operation.application_scope_f(c_app),
      op_operation_id => l_op2, op_attempt_number => l_att2, op_fencing_token => l_tok2,
      op_lease_expires_at => l_exp2, op_busy => l_busy, op_busy_until => l_busy_until
   );
   assert(l_busy = 'Y', 'expected participant scope conflict to be busy');

   -- SCHEMA_LIFECYCLE must be blocked by, and block, every other live scope.
   pkg_core_operation.begin_and_acquire_operation_p(
      ip_primary_scope => pkg_core_operation.c_scope_schema_lifecycle,
      op_operation_id => l_op2, op_attempt_number => l_att2, op_fencing_token => l_tok2,
      op_lease_expires_at => l_exp2, op_busy => l_busy, op_busy_until => l_busy_until
   );
   assert(l_busy = 'Y', 'expected SCHEMA_LIFECYCLE to conflict with a live SCHEMA_RUNTIME operation');

   pkg_core_operation.record_operation_step_p(l_op1, l_att1, l_tok1, 'CHECK_STEP', 'DATABASE_COMPLETE', 'evidence');

   BEGIN
      pkg_core_operation.record_operation_step_p(l_op1, l_att1, 'not-the-real-token', 'CHECK_STEP', 'X');
      raise_application_error(-20000, 'expected stale fencing token to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%fencing token is stale%' THEN
            NULL;
         ELSE
            RAISE;
         END IF;
   END;

   pkg_core_operation.release_operation_lease_p(l_op1, l_att1, l_tok1);

   -- The participant application scope must be free again after release.
   pkg_core_operation.begin_and_acquire_operation_p(
      ip_primary_scope => pkg_core_operation.application_scope_f(c_app),
      op_operation_id => l_op2, op_attempt_number => l_att2, op_fencing_token => l_tok2,
      op_lease_expires_at => l_exp2, op_busy => l_busy, op_busy_until => l_busy_until
   );
   assert(l_busy = 'N', 'expected scope free after release_operation_lease_p');
   pkg_core_operation.release_operation_lease_p(l_op2, l_att2, l_tok2);

   cleanup;

   DBMS_OUTPUT.PUT_LINE('PKG_CORE_OPERATION lease/fencing checks passed');
EXCEPTION
   WHEN OTHERS THEN
      cleanup;
      RAISE;
END;
/

EXIT SUCCESS
