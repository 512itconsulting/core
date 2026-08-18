CREATE OR REPLACE PACKAGE PKG_APP_DICT
AS
--Usage:
-- Lifecycle capability keys and profiles (DBPM_ALLOW_*, DBPM_LIFECYCLE) are
-- provisioned here, per docs/core-operation-api-followup.md's "Lifecycle
-- capability profiles and provisioning" section. DEPLOY_LOCKED remains
-- authoritative over every capability and profile: granting (Y) any
-- capability, or applying a profile, requires DEPLOY_LOCKED=N. Revoking (N)
-- is always allowed. DBPM_ALLOW_ENVIRONMENT_RESET is never implied by a
-- profile and must always be granted as its own explicit key.
--------------------------------------------------------------------------------
   c_capability_mutable_source     CONSTANT app_dictionary.key%TYPE := 'DBPM_ALLOW_MUTABLE_SOURCE';
   c_capability_same_version_replace CONSTANT app_dictionary.key%TYPE := 'DBPM_ALLOW_SAME_VERSION_REPLACE';
   c_capability_runtime_replace    CONSTANT app_dictionary.key%TYPE := 'DBPM_ALLOW_RUNTIME_REPLACE';
   c_capability_graph_reset        CONSTANT app_dictionary.key%TYPE := 'DBPM_ALLOW_GRAPH_RESET';
   c_capability_environment_reset  CONSTANT app_dictionary.key%TYPE := 'DBPM_ALLOW_ENVIRONMENT_RESET';

   c_lifecycle_profile_developer   CONSTANT app_dictionary.value%TYPE := 'DEVELOPER';
   c_lifecycle_profile_disposable  CONSTANT app_dictionary.value%TYPE := 'DISPOSABLE';

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

/**
 * @description Sets one of the five explicit DBPM_ALLOW_* lifecycle
 * capability keys under CORE, validating the key is one of the five known
 * keys and the value is Y or N. Granting (Y) requires DEPLOY_LOCKED=N;
 * revoking (N) is always allowed regardless of lock status. Every call is
 * recorded in CORE_CAPABILITY_AUDIT with the actor, previous value, and new
 * value. Commits.
 * @param ip_key One of the five DBPM_ALLOW_* keys; see the c_capability_*
 * constants.
 */
   PROCEDURE set_capability_p
      ( ip_key   IN app_dictionary.key%TYPE
      , ip_value IN app_dictionary.value%TYPE
      , ip_actor IN app_dictionary.value%TYPE DEFAULT NULL
      , ip_note  IN app_dictionary.note%TYPE DEFAULT NULL
      );

/**
 * @description Expands a DEVELOPER or DISPOSABLE lifecycle profile into its
 * documented explicit DBPM_ALLOW_* keys (see development-lifecycle-design.md
 * for the target-class table) and records DBPM_LIFECYCLE=<profile> for
 * informational display. Requires DEPLOY_LOCKED=N, same as set_capability_p.
 * Never grants DBPM_ALLOW_ENVIRONMENT_RESET, and never grants
 * DBPM_ALLOW_GRAPH_RESET for DEVELOPER — both remain explicit-grant-only
 * regardless of profile. Every resulting key change is individually audited
 * via set_capability_p. Commits.
 */
   PROCEDURE apply_lifecycle_profile_p
      ( ip_profile IN app_dictionary.value%TYPE
      , ip_actor   IN app_dictionary.value%TYPE DEFAULT NULL
      );

/**
 * @description Returns the current effective value of all five explicit
 * DBPM_ALLOW_* keys plus the informational DBPM_LIFECYCLE value, each 'Y',
 * 'N', or NULL if never configured.
 */
   PROCEDURE get_lifecycle_capabilities_p
      ( op_mutable_source        OUT app_dictionary.value%TYPE
      , op_same_version_replace  OUT app_dictionary.value%TYPE
      , op_runtime_replace       OUT app_dictionary.value%TYPE
      , op_graph_reset           OUT app_dictionary.value%TYPE
      , op_environment_reset     OUT app_dictionary.value%TYPE
      , op_lifecycle_profile     OUT app_dictionary.value%TYPE
      );

END PKG_APP_DICT;
/
