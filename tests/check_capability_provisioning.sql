SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE

PROMPT Running lifecycle capability provisioning checks

DECLARE
   l_deploy_locked_saved app_dictionary.value%TYPE;

   l_mut  VARCHAR2(1);
   l_svr  VARCHAR2(1);
   l_rr   VARCHAR2(1);
   l_gr   VARCHAR2(1);
   l_er   VARCHAR2(1);
   l_prof VARCHAR2(30);

   l_cnt NUMBER;

   PROCEDURE cleanup
   IS
   BEGIN
      pkg_app_dict.merge_val_p('CORE', 'DEPLOY_LOCKED', l_deploy_locked_saved, NULL);
      pkg_app_dict.delete_val_p('CORE', 'DBPM_ALLOW_MUTABLE_SOURCE');
      pkg_app_dict.delete_val_p('CORE', 'DBPM_ALLOW_SAME_VERSION_REPLACE');
      pkg_app_dict.delete_val_p('CORE', 'DBPM_ALLOW_RUNTIME_REPLACE');
      pkg_app_dict.delete_val_p('CORE', 'DBPM_ALLOW_GRAPH_RESET');
      pkg_app_dict.delete_val_p('CORE', 'DBPM_ALLOW_ENVIRONMENT_RESET');
      pkg_app_dict.delete_val_p('CORE', 'DBPM_LIFECYCLE');
      DELETE FROM core_capability_audit WHERE actor = 'check_capability_provisioning.sql';
      COMMIT;
   END cleanup;
BEGIN
   SELECT value INTO l_deploy_locked_saved FROM app_dictionary WHERE application_name = 'CORE' AND key = 'DEPLOY_LOCKED';
   cleanup;
   pkg_app_dict.merge_val_p('CORE', 'DEPLOY_LOCKED', 'N', NULL);

   -- Unknown key and bad value are rejected.
   BEGIN
      pkg_app_dict.set_capability_p('DBPM_ALLOW_BOGUS', 'Y');
      raise_application_error(-20000, 'expected unknown capability key to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%Unknown lifecycle capability key%' THEN NULL; ELSE RAISE; END IF;
   END;

   BEGIN
      pkg_app_dict.set_capability_p('DBPM_ALLOW_RUNTIME_REPLACE', 'MAYBE');
      raise_application_error(-20000, 'expected non Y/N capability value to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%must be Y or N%' THEN NULL; ELSE RAISE; END IF;
   END;

   -- A grant persists and is audited with actor, old value, and new value.
   pkg_app_dict.set_capability_p('DBPM_ALLOW_RUNTIME_REPLACE', 'Y', 'check_capability_provisioning.sql', 'test grant');
   assert(pkg_app_dict.get_val_f('CORE', 'DBPM_ALLOW_RUNTIME_REPLACE') = 'Y', 'expected grant to persist');

   SELECT COUNT(*)
     INTO l_cnt
     FROM core_capability_audit
    WHERE capability_key = 'DBPM_ALLOW_RUNTIME_REPLACE'
      AND old_value IS NULL
      AND new_value = 'Y'
      AND actor = 'check_capability_provisioning.sql';
   assert(l_cnt = 1, 'expected one audit row for the grant with old_value NULL');

   pkg_app_dict.set_capability_p('DBPM_ALLOW_RUNTIME_REPLACE', 'N', 'check_capability_provisioning.sql');

   SELECT COUNT(*)
     INTO l_cnt
     FROM core_capability_audit
    WHERE capability_key = 'DBPM_ALLOW_RUNTIME_REPLACE'
      AND old_value = 'Y'
      AND new_value = 'N'
      AND actor = 'check_capability_provisioning.sql';
   assert(l_cnt = 1, 'expected one audit row for the revoke with old_value Y');

   -- DEVELOPER grants the three base keys, never GRAPH_RESET or ENVIRONMENT_RESET.
   pkg_app_dict.apply_lifecycle_profile_p('DEVELOPER', 'check_capability_provisioning.sql');
   pkg_app_dict.get_lifecycle_capabilities_p(l_mut, l_svr, l_rr, l_gr, l_er, l_prof);
   assert(l_mut = 'Y' AND l_svr = 'Y' AND l_rr = 'Y', 'expected DEVELOPER to grant MUTABLE_SOURCE, SAME_VERSION_REPLACE, RUNTIME_REPLACE');
   assert(l_gr IS NULL, 'expected DEVELOPER to never imply GRAPH_RESET');
   assert(l_er IS NULL, 'expected DEVELOPER to never imply ENVIRONMENT_RESET');
   assert(l_prof = 'DEVELOPER', 'expected DBPM_LIFECYCLE informational value to be set to DEVELOPER');

   -- DISPOSABLE additionally grants GRAPH_RESET, but still never ENVIRONMENT_RESET.
   pkg_app_dict.apply_lifecycle_profile_p('DISPOSABLE', 'check_capability_provisioning.sql');
   pkg_app_dict.get_lifecycle_capabilities_p(l_mut, l_svr, l_rr, l_gr, l_er, l_prof);
   assert(l_gr = 'Y', 'expected DISPOSABLE to grant GRAPH_RESET');
   assert(l_er IS NULL, 'expected DISPOSABLE to never imply ENVIRONMENT_RESET');
   assert(l_prof = 'DISPOSABLE', 'expected DBPM_LIFECYCLE informational value to be updated to DISPOSABLE');

   BEGIN
      pkg_app_dict.apply_lifecycle_profile_p('BOGUS');
      raise_application_error(-20000, 'expected unknown profile to be rejected');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%Unknown lifecycle profile%' THEN NULL; ELSE RAISE; END IF;
   END;

   -- DEPLOY_LOCKED=Y blocks every grant and profile apply, but never blocks a revoke.
   pkg_app_dict.merge_val_p('CORE', 'DEPLOY_LOCKED', 'Y', NULL);

   BEGIN
      pkg_app_dict.set_capability_p('DBPM_ALLOW_RUNTIME_REPLACE', 'Y');
      raise_application_error(-20000, 'expected a grant to be rejected while DEPLOY_LOCKED=Y');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%requires DEPLOY_LOCKED=N%' THEN NULL; ELSE RAISE; END IF;
   END;

   pkg_app_dict.set_capability_p('DBPM_ALLOW_RUNTIME_REPLACE', 'N');

   BEGIN
      pkg_app_dict.apply_lifecycle_profile_p('DISPOSABLE');
      raise_application_error(-20000, 'expected a profile apply to be rejected while DEPLOY_LOCKED=Y');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000 AND SQLERRM LIKE '%requires DEPLOY_LOCKED=N%' THEN NULL; ELSE RAISE; END IF;
   END;

   cleanup;

   DBMS_OUTPUT.PUT_LINE('lifecycle capability provisioning checks passed');
EXCEPTION
   WHEN OTHERS THEN
      cleanup;
      RAISE;
END;
/

EXIT SUCCESS
