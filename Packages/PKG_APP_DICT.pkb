CREATE OR REPLACE PACKAGE BODY PKG_APP_DICT
AS

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


END PKG_APP_DICT;
/
