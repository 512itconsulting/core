SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE

PROMPT Running delete_system_p guard checks

DECLARE
   c_app CONSTANT application.application_name%TYPE := 'CORE';

   l_locked_exists BOOLEAN;
   l_locked_value  app_dictionary.value%TYPE;
   l_locked_note   app_dictionary.note%TYPE;
   l_saved         BOOLEAN := FALSE;

   PROCEDURE save_value
   IS
   BEGIN
      l_locked_exists := pkg_app_dict.exists_f(c_app, 'DEPLOY_LOCKED');

      IF l_locked_exists THEN
         SELECT value
              , note
           INTO l_locked_value
              , l_locked_note
           FROM app_dictionary
          WHERE application_name = c_app
            AND key = 'DEPLOY_LOCKED';
      END IF;

      l_saved := TRUE;
   END save_value;

   PROCEDURE restore_value
   IS
   BEGIN
      IF l_locked_exists THEN
         pkg_app_dict.merge_val_p(c_app, 'DEPLOY_LOCKED', l_locked_value, l_locked_note);
      ELSE
         pkg_app_dict.delete_val_p(c_app, 'DEPLOY_LOCKED');
      END IF;
   END restore_value;

   PROCEDURE expect_failure
      ( ip_label        IN VARCHAR2
      , ip_confirm      IN VARCHAR2
      )
   IS
   BEGIN
      pkg_application.delete_system_p(
         ip_confirm => ip_confirm
      );

      raise_application_error(-20000, ip_label || ' should have failed');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000
            AND SQLERRM LIKE '%' || ip_label || ' should have failed%'
         THEN
            RAISE;
         END IF;
   END expect_failure;

   PROCEDURE expect_no_arg_failure
   IS
   BEGIN
      pkg_application.delete_system_p;

      raise_application_error(-20000, 'No-argument call should have failed');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20000
            AND SQLERRM LIKE '%No-argument call should have failed%'
         THEN
            RAISE;
         END IF;
   END expect_no_arg_failure;
BEGIN
   save_value;

   pkg_app_dict.delete_val_p(c_app, 'DEPLOY_LOCKED');
   expect_no_arg_failure;
   expect_failure('Missing DEPLOY_LOCKED', pkg_application.c_delete_system_confirm);

   pkg_app_dict.set_deployment_metadata_p(ip_deploy_locked => 'N');
   expect_failure('Bad confirmation', 'DELETE STUFF');

   pkg_app_dict.set_deployment_metadata_p(ip_deploy_locked => 'Y');
   expect_failure('Locked database', pkg_application.c_delete_system_confirm);

   restore_value;

   DBMS_OUTPUT.PUT_LINE('delete_system_p guard checks passed');
EXCEPTION
   WHEN OTHERS THEN
      IF l_saved THEN
         restore_value;
      END IF;
      RAISE;
END;
/

EXIT SUCCESS
