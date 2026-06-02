SET SERVEROUTPUT ON
SET FEEDBACK OFF
SET HEADING OFF
WHENEVER SQLERROR EXIT FAILURE

PROMPT Running deployment downgrade guard checks

DECLARE
   c_app  CONSTANT VARCHAR2(30) := 'TEST_DOWNGRADE_BUG';
   c_hash CONSTANT VARCHAR2(40) := '0000000000000000000000000000000000000000';

   PROCEDURE cleanup
   IS
   BEGIN
      pkg_application.delete_application_p
         ( ip_application_name  => c_app
         , ip_fail_on_not_found => 'N' );
   END;

   PROCEDURE complete
   IS
   BEGIN
      pkg_application.set_deployment_complete_p(ip_application_name => c_app);
   END;

   PROCEDURE begin_deploy
      ( ip_major IN INTEGER
      , ip_minor IN INTEGER
      , ip_patch IN INTEGER
      , ip_type  IN VARCHAR2 )
   IS
   BEGIN
      pkg_application.begin_deployment_p
         ( ip_application_name   => c_app
         , ip_major_version      => ip_major
         , ip_minor_version      => ip_minor
         , ip_patch_version      => ip_patch
         , ip_deployment_type    => ip_type
         , ip_deploy_commit_hash => c_hash );
   END;

   PROCEDURE expect_success
      ( ip_label IN VARCHAR2
      , ip_major IN INTEGER
      , ip_minor IN INTEGER
      , ip_patch IN INTEGER
      , ip_type  IN VARCHAR2 )
   IS
   BEGIN
      begin_deploy(ip_major, ip_minor, ip_patch, ip_type);
      dbms_output.put_line('PASS success '||ip_label);
   END;

   PROCEDURE expect_failure
      ( ip_label IN VARCHAR2
      , ip_major IN INTEGER
      , ip_minor IN INTEGER
      , ip_patch IN INTEGER
      , ip_type  IN VARCHAR2 )
   IS
   BEGIN
      begin_deploy(ip_major, ip_minor, ip_patch, ip_type);
      raise_application_error(-20000, ip_label||' unexpectedly succeeded');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLERRM NOT LIKE '%Assertion Error:%' THEN
            RAISE;
         END IF;

         dbms_output.put_line('PASS failure '||ip_label||' => '||SQLERRM);
   END;
BEGIN
   cleanup;

   expect_success('initial 1.2.3', 1, 2, 3, pkg_application.c_deploy_type_initial);
   complete;

   expect_failure('patch downgrade 1.2.2', 1, 2, 2, pkg_application.c_deploy_type_patch);
   expect_failure('minor downgrade 1.1.9', 1, 1, 9, pkg_application.c_deploy_type_minor);
   expect_failure('major downgrade 0.9.9', 0, 9, 9, pkg_application.c_deploy_type_major);

   expect_success('same-version redeploy 1.2.3', 1, 2, 3, pkg_application.c_deploy_type_patch);
   complete;

   expect_success('patch upgrade 1.2.4', 1, 2, 4, pkg_application.c_deploy_type_patch);
   complete;

   expect_success('minor upgrade 1.3.0', 1, 3, 0, pkg_application.c_deploy_type_minor);
   complete;

   expect_success('major upgrade 2.0.0', 2, 0, 0, pkg_application.c_deploy_type_major);
   complete;

   expect_success('failed deployment start 2.0.1', 2, 0, 1, pkg_application.c_deploy_type_patch);
   pkg_application.set_deployment_fail_p(ip_application_name => c_app);
   expect_failure('failed restart lower 2.0.0', 2, 0, 0, pkg_application.c_deploy_type_patch);
   expect_failure('failed restart higher 2.0.2', 2, 0, 2, pkg_application.c_deploy_type_patch);
   expect_success('failed restart same 2.0.1', 2, 0, 1, pkg_application.c_deploy_type_patch);
   complete;

   cleanup;
END;
/

DECLARE
   l_count INTEGER;
BEGIN
   SELECT COUNT(*)
     INTO l_count
     FROM application
    WHERE application_name = 'TEST_DOWNGRADE_BUG';

   IF l_count != 0 THEN
      raise_application_error(-20000, 'TEST_DOWNGRADE_BUG cleanup failed; application rows: '||l_count);
   END IF;

   dbms_output.put_line('PASS cleanup TEST_DOWNGRADE_BUG');
END;
/

EXIT SUCCESS
