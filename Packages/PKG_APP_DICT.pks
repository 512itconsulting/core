CREATE OR REPLACE PACKAGE PKG_APP_DICT
AS

   FUNCTION exists_f( ip_application IN app_dictionary.application_name%TYPE
                    , ip_key IN app_dictionary.key%TYPE )
      RETURN BOOLEAN;

   FUNCTION get_val_f( ip_application IN app_dictionary.application_name%TYPE
                     , ip_key IN app_dictionary.key%TYPE )
      RETURN VARCHAR2;

   PROCEDURE add_val_p( ip_application IN app_dictionary.application_name%TYPE
                      , ip_key IN app_dictionary.key%TYPE
                      , ip_value IN app_dictionary.value%TYPE
                      , ip_note IN app_dictionary.note%TYPE DEFAULT NULL
                      );

   PROCEDURE merge_val_p( ip_application IN app_dictionary.application_name%TYPE
                        , ip_key IN app_dictionary.key%TYPE
                        , ip_value IN app_dictionary.value%TYPE
                        , ip_note IN app_dictionary.note%TYPE DEFAULT NULL
                        );

   PROCEDURE delete_val_p( ip_application IN app_dictionary.application_name%TYPE
                         , ip_key IN app_dictionary.key%TYPE
                         );

   PROCEDURE set_deployment_metadata_p
      ( ip_deploy_locked      IN app_dictionary.value%TYPE
      , ip_deploy_environment IN app_dictionary.value%TYPE DEFAULT NULL
      );

END PKG_APP_DICT;
/
