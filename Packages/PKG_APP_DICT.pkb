CREATE OR REPLACE PACKAGE BODY PKG_APP_DICT
AS

  -- =========================================================================
  -- Private Procedures and Functions
  -- =========================================================================

FUNCTION deploy_locked_f
   RETURN VARCHAR2
IS
BEGIN
   IF exists_f('CORE', 'DEPLOY_LOCKED') THEN
      RETURN get_val_f('CORE', 'DEPLOY_LOCKED');
   END IF;

   RETURN 'Y';
END deploy_locked_f;



FUNCTION is_known_capability_f(ip_key IN app_dictionary.key%TYPE)
   RETURN BOOLEAN
IS
BEGIN
   RETURN UPPER(ip_key) IN
   (
       c_capability_mutable_source
     , c_capability_same_version_replace
     , c_capability_runtime_replace
     , c_capability_graph_reset
     , c_capability_environment_reset
   );
END is_known_capability_f;

  -- =========================================================================
  -- Public Procedures
  -- =========================================================================

FUNCTION exists_f( ip_application IN app_dictionary.application_name%TYPE
                 , ip_key IN app_dictionary.key%TYPE )
   RETURN BOOLEAN
IS
   l_value app_dictionary.value%TYPE;
BEGIN
   SELECT MAX(value)
     INTO l_value
     FROM app_dictionary
    WHERE application_name = ip_application
      AND key = UPPER(ip_key);

   RETURN CASE WHEN l_value IS NULL THEN FALSE ELSE TRUE END;
END exists_f;



FUNCTION get_val_f( ip_application IN app_dictionary.application_name%TYPE
                  , ip_key IN app_dictionary.key%TYPE )
   RETURN VARCHAR2
IS
   l_value app_dictionary.value%TYPE;
BEGIN
   SELECT value
     INTO l_value
     FROM app_dictionary
    WHERE application_name = ip_application
      AND key = UPPER(ip_key);

   RETURN l_value;
END get_val_f;



PROCEDURE add_val_p( ip_application IN app_dictionary.application_name%TYPE
                   , ip_key IN app_dictionary.key%TYPE
                   , ip_value IN app_dictionary.value%TYPE
                   , ip_note IN app_dictionary.note%TYPE DEFAULT NULL
                   )
IS
BEGIN
   INSERT
     INTO app_dictionary
        ( application_name
        , key
        , value 
        , note )
   VALUES
        ( ip_application
        , UPPER(ip_key)
        , ip_value 
        , ip_note );

   COMMIT;
END add_val_p;



PROCEDURE merge_val_p( ip_application IN app_dictionary.application_name%TYPE
                     , ip_key IN app_dictionary.key%TYPE
                     , ip_value IN app_dictionary.value%TYPE
                     , ip_note IN app_dictionary.note%TYPE DEFAULT NULL
                     )
IS
BEGIN
   DELETE
     FROM app_dictionary
    WHERE application_name = ip_application
      AND key = UPPER(ip_key);

   add_val_p( ip_application, ip_key, ip_value, ip_note );
END merge_val_p;



PROCEDURE delete_val_p( ip_application IN app_dictionary.application_name%TYPE
                      , ip_key IN app_dictionary.key%TYPE
                      )
IS
BEGIN
   DELETE
     FROM app_dictionary
    WHERE application_name = ip_application
      AND key = UPPER(ip_key);

   COMMIT;
END delete_val_p;



PROCEDURE set_deployment_metadata_p
   ( ip_deploy_locked      IN app_dictionary.value%TYPE
   , ip_deploy_environment IN app_dictionary.value%TYPE DEFAULT NULL
   )
IS
   l_deploy_locked app_dictionary.value%TYPE := UPPER(TRIM(ip_deploy_locked));
BEGIN
   assert(l_deploy_locked IS NOT NULL,
          'DEPLOY_LOCKED is required. Supply Y for protected databases or N for development databases.');

   assert(l_deploy_locked IN ('Y', 'N'),
          'DEPLOY_LOCKED must be Y or N.');

   assert(NOT pkg_app_dict.exists_f('CORE', 'DEPLOY_LOCKED'),
          'DEPLOY_LOCKED is already configured and cannot be changed by set_deployment_metadata_p.');

   merge_val_p(
      'CORE',
      'DEPLOY_LOCKED',
      l_deploy_locked,
      'Y blocks dangerous deployment behavior; N allows development deployment workflows.'
   );

   IF ip_deploy_environment IS NOT NULL THEN
      merge_val_p(
         'CORE',
         'DEPLOY_ENVIRONMENT',
         ip_deploy_environment,
         'Human-readable deployment environment label (i.e. DEV, QLAB01, PLAB, PROD).'
      );
   END IF;
END set_deployment_metadata_p;



PROCEDURE set_capability_p
   ( ip_key   IN app_dictionary.key%TYPE
   , ip_value IN app_dictionary.value%TYPE
   , ip_actor IN app_dictionary.value%TYPE DEFAULT NULL
   , ip_note  IN app_dictionary.note%TYPE DEFAULT NULL
   )
IS
   l_key       app_dictionary.key%TYPE := UPPER(TRIM(ip_key));
   l_value     app_dictionary.value%TYPE := UPPER(TRIM(ip_value));
   l_old_value app_dictionary.value%TYPE;
BEGIN
   assert(is_known_capability_f(l_key), 'Unknown lifecycle capability key: '||ip_key);
   assert(l_value IN ('Y', 'N'), 'Capability value must be Y or N.');

   IF l_value = 'Y' THEN
      assert(deploy_locked_f = 'N', 'Granting '||l_key||' requires DEPLOY_LOCKED=N');
   END IF;

   IF exists_f('CORE', l_key) THEN
      l_old_value := get_val_f('CORE', l_key);
   ELSE
      l_old_value := NULL;
   END IF;

   merge_val_p('CORE', l_key, l_value, ip_note);

   INSERT INTO core_capability_audit
   ( audit_id, capability_key, old_value, new_value, actor, changed_at )
   VALUES
   ( core_capability_audit_seq.NEXTVAL, l_key, l_old_value, l_value, ip_actor, SYSTIMESTAMP );

   COMMIT;
END set_capability_p;



PROCEDURE apply_lifecycle_profile_p
   ( ip_profile IN app_dictionary.value%TYPE
   , ip_actor   IN app_dictionary.value%TYPE DEFAULT NULL
   )
IS
   l_profile   app_dictionary.value%TYPE := UPPER(TRIM(ip_profile));
   l_old_value app_dictionary.value%TYPE;
BEGIN
   assert(
       l_profile IN (c_lifecycle_profile_developer, c_lifecycle_profile_disposable)
     , 'Unknown lifecycle profile: '||ip_profile||'. Expected DEVELOPER or DISPOSABLE.'
   );
   assert(deploy_locked_f = 'N', 'Applying a lifecycle profile requires DEPLOY_LOCKED=N');

   set_capability_p(c_capability_mutable_source, 'Y', ip_actor, 'Granted by '||l_profile||' profile');
   set_capability_p(c_capability_same_version_replace, 'Y', ip_actor, 'Granted by '||l_profile||' profile');
   set_capability_p(c_capability_runtime_replace, 'Y', ip_actor, 'Granted by '||l_profile||' profile');

   -- GRAPH_RESET is granted only by DISPOSABLE; ENVIRONMENT_RESET is never
   -- implied by any profile and must always be granted explicitly.
   IF l_profile = c_lifecycle_profile_disposable THEN
      set_capability_p(c_capability_graph_reset, 'Y', ip_actor, 'Granted by '||l_profile||' profile');
   END IF;

   IF exists_f('CORE', 'DBPM_LIFECYCLE') THEN
      l_old_value := get_val_f('CORE', 'DBPM_LIFECYCLE');
   ELSE
      l_old_value := NULL;
   END IF;

   merge_val_p('CORE', 'DBPM_LIFECYCLE', l_profile, 'Informational label; explicit DBPM_ALLOW_* keys are authoritative.');

   INSERT INTO core_capability_audit
   ( audit_id, capability_key, old_value, new_value, actor, changed_at )
   VALUES
   ( core_capability_audit_seq.NEXTVAL, 'DBPM_LIFECYCLE', l_old_value, l_profile, ip_actor, SYSTIMESTAMP );

   COMMIT;
END apply_lifecycle_profile_p;



PROCEDURE get_lifecycle_capabilities_p
   ( op_mutable_source        OUT app_dictionary.value%TYPE
   , op_same_version_replace  OUT app_dictionary.value%TYPE
   , op_runtime_replace       OUT app_dictionary.value%TYPE
   , op_graph_reset           OUT app_dictionary.value%TYPE
   , op_environment_reset     OUT app_dictionary.value%TYPE
   , op_lifecycle_profile     OUT app_dictionary.value%TYPE
   )
IS
BEGIN
   IF exists_f('CORE', c_capability_mutable_source) THEN
      op_mutable_source := get_val_f('CORE', c_capability_mutable_source);
   END IF;

   IF exists_f('CORE', c_capability_same_version_replace) THEN
      op_same_version_replace := get_val_f('CORE', c_capability_same_version_replace);
   END IF;

   IF exists_f('CORE', c_capability_runtime_replace) THEN
      op_runtime_replace := get_val_f('CORE', c_capability_runtime_replace);
   END IF;

   IF exists_f('CORE', c_capability_graph_reset) THEN
      op_graph_reset := get_val_f('CORE', c_capability_graph_reset);
   END IF;

   IF exists_f('CORE', c_capability_environment_reset) THEN
      op_environment_reset := get_val_f('CORE', c_capability_environment_reset);
   END IF;

   IF exists_f('CORE', 'DBPM_LIFECYCLE') THEN
      op_lifecycle_profile := get_val_f('CORE', 'DBPM_LIFECYCLE');
   END IF;
END get_lifecycle_capabilities_p;


END PKG_APP_DICT;
/
