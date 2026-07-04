SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE

PROMPT Running deployment metadata checks

DECLARE
   c_app CONSTANT application.application_name%TYPE := 'CORE';

   l_locked_exists BOOLEAN;
   l_locked_value  app_dictionary.value%TYPE;
   l_locked_note   app_dictionary.note%TYPE;
   l_env_exists    BOOLEAN;
   l_env_value     app_dictionary.value%TYPE;
   l_env_note      app_dictionary.note%TYPE;
   l_saved         BOOLEAN := FALSE;

   PROCEDURE save_value
      ( ip_key    IN app_dictionary.key%TYPE
      , op_exists OUT BOOLEAN
      , op_value  OUT app_dictionary.value%TYPE
      , op_note   OUT app_dictionary.note%TYPE
      )
   IS
   BEGIN
      op_exists := pkg_app_dict.exists_f(c_app, ip_key);

      IF op_exists THEN
         SELECT value
              , note
           INTO op_value
              , op_note
           FROM app_dictionary
          WHERE application_name = c_app
            AND key = ip_key;
      END IF;
   END save_value;

   PROCEDURE restore_value
      ( ip_key    IN app_dictionary.key%TYPE
      , ip_exists IN BOOLEAN
      , ip_value  IN app_dictionary.value%TYPE
      , ip_note   IN app_dictionary.note%TYPE
      )
   IS
   BEGIN
      IF ip_exists THEN
         pkg_app_dict.merge_val_p(c_app, ip_key, ip_value, ip_note);
      ELSE
         pkg_app_dict.delete_val_p(c_app, ip_key);
      END IF;
   END restore_value;

   PROCEDURE restore_values
   IS
   BEGIN
      restore_value('DEPLOY_LOCKED', l_locked_exists, l_locked_value, l_locked_note);
      restore_value('DEPLOY_ENVIRONMENT', l_env_exists, l_env_value, l_env_note);
   END restore_values;

   PROCEDURE expect_value
      ( ip_key      IN app_dictionary.key%TYPE
      , ip_expected IN app_dictionary.value%TYPE
      )
   IS
      l_actual app_dictionary.value%TYPE;
   BEGIN
      SELECT value
        INTO l_actual
        FROM app_dictionary
       WHERE application_name = c_app
         AND key = ip_key;

      IF l_actual != ip_expected THEN
         raise_application_error(
            -20000,
            ip_key || ' expected ' || ip_expected || ' but found ' || l_actual
         );
      END IF;
   END expect_value;

   PROCEDURE expect_failure
      ( ip_label         IN VARCHAR2
      , ip_deploy_locked IN app_dictionary.value%TYPE
      )
   IS
   BEGIN
      pkg_app_dict.set_deployment_metadata_p(
         ip_deploy_locked => ip_deploy_locked
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
BEGIN
   save_value('DEPLOY_LOCKED', l_locked_exists, l_locked_value, l_locked_note);
   save_value('DEPLOY_ENVIRONMENT', l_env_exists, l_env_value, l_env_note);
   l_saved := TRUE;

   pkg_app_dict.delete_val_p(c_app, 'DEPLOY_LOCKED');
   pkg_app_dict.delete_val_p(c_app, 'DEPLOY_ENVIRONMENT');

   pkg_app_dict.set_deployment_metadata_p(
      ip_deploy_locked      => 'Y',
      ip_deploy_environment => 'DEV'
   );
   expect_value('DEPLOY_LOCKED', 'Y');
   expect_value('DEPLOY_ENVIRONMENT', 'DEV');

   expect_failure('Existing DEPLOY_LOCKED', 'N');
   expect_value('DEPLOY_LOCKED', 'Y');
   expect_value('DEPLOY_ENVIRONMENT', 'DEV');

   pkg_app_dict.delete_val_p(c_app, 'DEPLOY_LOCKED');
   pkg_app_dict.delete_val_p(c_app, 'DEPLOY_ENVIRONMENT');

   pkg_app_dict.set_deployment_metadata_p(
      ip_deploy_locked      => 'n',
      ip_deploy_environment => 'PROD'
   );
   expect_value('DEPLOY_LOCKED', 'N');
   expect_value('DEPLOY_ENVIRONMENT', 'PROD');

   pkg_app_dict.delete_val_p(c_app, 'DEPLOY_LOCKED');

   expect_failure('Missing DEPLOY_LOCKED', NULL);
   expect_failure('Invalid DEPLOY_LOCKED', 'MAYBE');

   restore_values;

   DBMS_OUTPUT.PUT_LINE('Deployment metadata checks passed');
EXCEPTION
   WHEN OTHERS THEN
      IF l_saved THEN
         restore_values;
      END IF;
      RAISE;
END;
/

EXIT SUCCESS
