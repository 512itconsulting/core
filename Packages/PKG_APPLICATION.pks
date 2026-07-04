CREATE OR REPLACE PACKAGE PKG_APPLICATION
AS
--Usage:
-- This package is the core application registry and deployment-control API.
-- It records which database applications are installed, which version is currently
-- deployed, what other applications they depend on, which privileges they require,
-- which database objects they own, and which metadata rows they own inside tables
-- registered by other applications.
--
-- Typical deployment lifecycle:
--   1. Start or resume a deployment with begin_deployment_p.
--   2. Register dependencies, required privileges, owned objects, and owned metadata.
--   3. Validate dependencies, privileges, and objects.
--   4. Mark the deployment complete, or failed, before the script exits.
--
-- For an initial deployment using the default version 0.1.0:
--   EXEC pkg_application.begin_deployment_p(ip_application_name => ':APPLICATION_NAME:');
--
-- For an initial deployment using an explicit semantic version:
--   EXEC pkg_application.begin_deployment_p
--   ( ip_application_name => ':APPLICATION_NAME:'
--   , ip_major_version    => 1
--   , ip_minor_version    => 0
--   , ip_patch_version    => 0
--   , ip_deployment_type  => pkg_application.c_deploy_type_initial
--   );
--
-- Register dependencies and requirements:
--   EXEC pkg_application.add_dependency_p(ip_application_name => ':APPLICATION_NAME:', ip_depends_on => ':APPLICATION2_NAME:');
--   EXEC pkg_application.add_sys_priv_p  (ip_application_name => ':APPLICATION_NAME:', ip_privilege => ':SYS_PRIV:');
--   EXEC pkg_application.add_obj_priv_p
--   ( ip_application_name => ':APPLICATION_NAME:'
--   , ip_owner            => ':OBJECT_OWNER:'
--   , ip_type             => ':OBJECT_TYPE:'
--   , ip_name             => ':OBJECT_NAME:'
--   , ip_privilege        => ':OBJECT_PRIV:'
--   );
--
-- Validate and finish:
--   EXEC pkg_application.validate_dependencies_p  (ip_application_name => ':APPLICATION_NAME:');
--   EXEC pkg_application.validate_obj_privs_p     (ip_application_name => ':APPLICATION_NAME:');
--   EXEC pkg_application.validate_sys_privs_p     (ip_application_name => ':APPLICATION_NAME:');
--   EXEC pkg_application.validate_objects_p       (ip_application_name => ':APPLICATION_NAME:');
--   EXEC pkg_application.set_deployment_complete_p(ip_application_name => ':APPLICATION_NAME:');
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
   TYPE t_application IS RECORD
   ( application_name           application.application_name%TYPE
   , major_version              application.major_version%TYPE    := 0
   , minor_version              application.minor_version%TYPE    := 1
   , patch_version              application.patch_version%TYPE    := 0
   , pre_release                application.pre_release%TYPE
   , build                      application.build%TYPE  
   , deploy_type                application.deploy_type%TYPE
   , deploy_status              application.deploy_status%TYPE
   , deploy_commit_hash         application.deploy_commit_hash%TYPE
   , deploy_begin               application.deploy_begin%TYPE
   , deploy_end                 application.deploy_end%TYPE 
   )
   ;
   TYPE t_app_object_metadata IS RECORD
   ( object_name               app_object_metadata.object_name%TYPE
   , object_namespace          app_object_metadata.object_namespace%TYPE
   , object_type               app_object_metadata.object_type%TYPE
   , application_name          app_object_metadata.application_name%TYPE
   , discriminator_col         app_object_metadata.discriminator_col%TYPE
   , discriminator_val         app_object_metadata.discriminator_val%TYPE
   , last_update               app_object_metadata.last_update%TYPE
   , version                   app_object_metadata.version%TYPE
   , dml_override_proc         app_object_metadata.dml_override_proc%TYPE
   )
   ;
   TYPE t_deploy_provenance IS RECORD
   ( application_name          app_deploy_provenance.application_name%TYPE
   , major_version             app_deploy_provenance.major_version%TYPE
   , minor_version             app_deploy_provenance.minor_version%TYPE
   , patch_version             app_deploy_provenance.patch_version%TYPE
   , deploy_type               app_deploy_provenance.deploy_type%TYPE
   , deploy_commit_hash        app_deploy_provenance.deploy_commit_hash%TYPE
   , deploy_begin              app_deploy_provenance.deploy_begin%TYPE
   , artifact_uri              app_deploy_provenance.artifact_uri%TYPE
   , artifact_checksum         app_deploy_provenance.artifact_checksum%TYPE
   , artifact_checksum_alg     app_deploy_provenance.artifact_checksum_alg%TYPE
   , artifact_file_name        app_deploy_provenance.artifact_file_name%TYPE
   , artifact_repository_type  app_deploy_provenance.artifact_repository_type%TYPE
   , artifact_group_id         app_deploy_provenance.artifact_group_id%TYPE
   , artifact_id               app_deploy_provenance.artifact_id%TYPE
   , artifact_version          app_deploy_provenance.artifact_version%TYPE
   , artifact_classifier       app_deploy_provenance.artifact_classifier%TYPE
   , artifact_extension        app_deploy_provenance.artifact_extension%TYPE
   , package_coordinate        app_deploy_provenance.package_coordinate%TYPE
   , source_repository_url     app_deploy_provenance.source_repository_url%TYPE
   , source_commit_hash        app_deploy_provenance.source_commit_hash%TYPE
   , source_path               app_deploy_provenance.source_path%TYPE
   , build_id                  app_deploy_provenance.build_id%TYPE
   , build_url                 app_deploy_provenance.build_url%TYPE
   , build_time                app_deploy_provenance.build_time%TYPE
   , build_metadata_json       app_deploy_provenance.build_metadata_json%TYPE
   )
   ;
--------------------------------------------------------------------------------
   --PACKAGE CONSTANTS
   --
   --APPLICATION.version
   c_core_major_version       CONSTANT APPLICATION.major_version%TYPE     := 3;
   c_version_default_major    CONSTANT APPLICATION.major_version%TYPE     := 0;
   c_version_default_minor    CONSTANT APPLICATION.minor_version%TYPE     := 1;
   c_version_default_patch    CONSTANT APPLICATION.patch_version%TYPE     := 0;
   --APPLICATION.deploy_type
   c_deploy_type_initial      CONSTANT APPLICATION.deploy_type%TYPE := 'I';
   c_deploy_type_major        CONSTANT APPLICATION.deploy_type%TYPE := 'V';
   c_deploy_type_minor        CONSTANT APPLICATION.deploy_type%TYPE := 'M';
   c_deploy_type_patch        CONSTANT APPLICATION.deploy_type%TYPE := 'P';
   --APPLICATION.deploy_commit_hash
   c_deploy_commit_hash_unknown CONSTANT APPLICATION.deploy_commit_hash%TYPE := '0000000000000000000000000000000000000000';
   --APPLICATION.deploy_status
   c_deploy_status_running    CONSTANT APPLICATION.deploy_status%TYPE := 'R';
   c_deploy_status_complete   CONSTANT APPLICATION.deploy_status%TYPE := 'C';
   c_deploy_status_fail       CONSTANT APPLICATION.deploy_status%TYPE := 'F';
   --
   c_delete_system_confirm    CONSTANT VARCHAR2(100) := 'DELETE ALL NON-CORE APPLICATIONS';
   --
   --APP_DEPENDENCY.is_valid
   c_valid_unknown            CONSTANT APP_DEPENDENCY.is_valid%TYPE   := 'U';
   c_valid_yes                CONSTANT APP_DEPENDENCY.is_valid%TYPE   := 'Y';
   c_valid_no                 CONSTANT APP_DEPENDENCY.is_valid%TYPE   := 'N';
   --APP_DEPENDENCY.version_min
   c_version_min_any          CONSTANT APP_DEPENDENCY.version_min%TYPE := 0;
   c_version_max_any          CONSTANT APP_DEPENDENCY.version_max%TYPE := 999999999999;
   --APP_OBJECT_TYPE.object_type%TYPE
   c_object_type_table        CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'TABLE';
   c_object_type_sequence     CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'SEQUENCE';
   c_object_type_procedure    CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'PROCEDURE';
   c_object_type_function     CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'FUNCTION';
   c_object_type_materialized_view     CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'MATERIALIZED VIEW';
   c_object_type_type         CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'TYPE';
   c_object_type_type_body    CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'TYPE BODY';
   c_object_type_package      CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'PACKAGE';
   c_object_type_package_body CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'PACKAGE BODY';
   c_object_type_view         CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'VIEW';
   c_object_type_db_link      CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'DATABASE LINK';
   c_object_type_synonym      CONSTANT APP_OBJECT_TYPE.object_type%TYPE := 'SYNONYM';
   
   --FUNCTIONS
/**
 * @description Returns the currently registered semantic version for an application
 * in major.minor.patch format.
 * @param ip_application_name Application to inspect.
 * @return Current registered application version as text.
 */
   FUNCTION get_current_version_f( ip_application_name IN application.application_name%TYPE )
      RETURN VARCHAR;

/**
 * @description Returns the most recent deployment provenance row for an application
 * as JSON. Optional semantic-version parameters restrict the lookup to a specific
 * deployed version. Returns NULL when no matching provenance row exists.
 * @param ip_application_name Application to inspect.
 * @param ip_major_version Optional major version filter.
 * @param ip_minor_version Optional minor version filter.
 * @param ip_patch_version Optional patch version filter.
 * @return Deployment provenance JSON.
 */
   FUNCTION get_deployment_provenance_json_f
      ( ip_application_name IN application.application_name%TYPE
      , ip_major_version    IN application.major_version%TYPE DEFAULT NULL
      , ip_minor_version    IN application.minor_version%TYPE DEFAULT NULL
      , ip_patch_version    IN application.patch_version%TYPE DEFAULT NULL
      )
      RETURN CLOB;

/**
 * @description Converts a major.minor.patch version string into a sortable integer
 * in MMMMIIIIPPPP format. This allows version ranges to be compared numerically.
 * @param ip_version Semantic version string, such as '1.2.3'.
 * @return Serialized integer representation of the version.
 */
   FUNCTION serialize_version_f(ip_version IN VARCHAR)
      RETURN INTEGER;

/**
 * @description Converts a serialized MMMMIIIIPPPP integer version back into
 * major.minor.patch format.
 * @param ip_serialized_version Serialized integer version.
 * @return Semantic version string.
 */
   FUNCTION deserialize_version_f(ip_serialized_version IN INTEGER)
      RETURN VARCHAR;
   
   --PROCEDURES
/**
 * @description Raises an error unless ip_application_name is deployed at or above
 * the supplied minimum semantic version. Use this at the start of scripts that
 * require a previously installed application version.
 * @param ip_application_name Application whose version should be checked.
 * @param ip_min_major_version Minimum required major version.
 * @param ip_min_minor_version Minimum required minor version.
 * @param ip_min_patch_version Minimum required patch version.
 */
   PROCEDURE check_min_app_version_p( ip_application_name  IN application.application_name%TYPE
                                    , ip_min_major_version IN application.major_version%TYPE DEFAULT 0
                                    , ip_min_minor_version IN application.minor_version%TYPE DEFAULT 0
                                    , ip_min_patch_version IN application.patch_version%TYPE DEFAULT 0
                                    );

/**
 * @description Raises an error when the requested version or a higher version has
 * already been deployed. Use this to prevent accidental re-execution of
 * non-idempotent deployment scripts.
 * @param ip_application_name Application whose deployed version should be checked.
 * @param ip_min_major_version Version being deployed - major component.
 * @param ip_min_minor_version Version being deployed - minor component.
 * @param ip_min_patch_version Version being deployed - patch component.
 */
   PROCEDURE check_already_deployed_p( ip_application_name  IN application.application_name%TYPE
                                     , ip_min_major_version IN application.major_version%TYPE DEFAULT 0
                                     , ip_min_minor_version IN application.minor_version%TYPE DEFAULT 0
                                     , ip_min_patch_version IN application.patch_version%TYPE DEFAULT 0 );

/**
 * @description Starts a deployment run for ip_application_name. The procedure records
 * the target semantic version, deployment type, commit hash, start timestamp, and
 * running status. This is normally the first call in an application deployment script.
 * If dbpm or another deployment tool previously staged matching provenance with
 * stage_deployment_provenance_p, this call consumes it into APP_DEPLOY_PROVENANCE.
 * @param ip_application_name Application being deployed.
 * @param ip_major_version Target major version.
 * @param ip_minor_version Target minor version.
 * @param ip_patch_version Target patch version.
 * @param ip_deployment_type Initial, major, minor, or patch deployment type constant.
 * @param ip_deploy_commit_hash: Optional but strongly recommended.
                                 Identifies the exact source control commit associated with the
                                 deployment. This allows environments running the same semantic
                                 version to still be differentiated by source revision during
                                 active development, hotfixes, or unreleased builds.
 * @param ip_redeploy_okay Retained for backward compatibility. Exact-version
 * redeploys are allowed for idempotent scripts; lower-version deployments are
 * never allowed.
 */
   PROCEDURE begin_deployment_p( ip_application_name   IN application.application_name%TYPE
                               , ip_major_version      IN application.major_version%TYPE
                               , ip_minor_version      IN application.minor_version%TYPE
                               , ip_patch_version      IN application.patch_version%TYPE
                               , ip_deployment_type    IN application.deploy_type%TYPE DEFAULT c_deploy_type_initial
                               , ip_deploy_commit_hash IN application.deploy_commit_hash%TYPE DEFAULT c_deploy_commit_hash_unknown
                               , ip_redeploy_okay      IN BOOLEAN DEFAULT FALSE
                               , ip_notes              IN app_deploy_notes.notes%TYPE DEFAULT NULL
                               );
/**
 * @description Stages artifact/build provenance for a later begin_deployment_p call.
 * This allows dbpm to record resolved artifact metadata while deployment scripts
 * remain identical for manual and dbpm-driven deployments.
 * @param ip_application_name Application being deployed.
 * @param ip_major_version Target major version.
 * @param ip_minor_version Target minor version.
 * @param ip_patch_version Target patch version.
 * @param ip_deployment_type Initial, major, minor, or patch deployment type constant.
 * @param ip_deploy_commit_hash Source control commit expected by the deployment script.
 * @param ip_artifact_uri Resolved artifact URL, repository URL, or local path.
 * @param ip_artifact_checksum Checksum of the exact artifact bytes deployed.
 * @param ip_artifact_checksum_alg Checksum algorithm, such as SHA-256.
 * @param ip_package_coordinate Resolved package coordinate from deployment tooling.
 * @param ip_build_metadata_json Free-form build metadata captured as JSON text.
 */
   PROCEDURE stage_deployment_provenance_p
                              ( ip_application_name          IN application.application_name%TYPE
                              , ip_major_version             IN application.major_version%TYPE
                              , ip_minor_version             IN application.minor_version%TYPE
                              , ip_patch_version             IN application.patch_version%TYPE
                              , ip_deployment_type           IN application.deploy_type%TYPE DEFAULT c_deploy_type_initial
                              , ip_deploy_commit_hash        IN application.deploy_commit_hash%TYPE DEFAULT c_deploy_commit_hash_unknown
                              , ip_artifact_uri              IN app_deploy_provenance_pending.artifact_uri%TYPE DEFAULT NULL
                              , ip_artifact_checksum         IN app_deploy_provenance_pending.artifact_checksum%TYPE DEFAULT NULL
                              , ip_artifact_checksum_alg     IN app_deploy_provenance_pending.artifact_checksum_alg%TYPE DEFAULT 'SHA-256'
                              , ip_artifact_file_name        IN app_deploy_provenance_pending.artifact_file_name%TYPE DEFAULT NULL
                              , ip_artifact_repository_type  IN app_deploy_provenance_pending.artifact_repository_type%TYPE DEFAULT NULL
                              , ip_artifact_group_id         IN app_deploy_provenance_pending.artifact_group_id%TYPE DEFAULT NULL
                              , ip_artifact_id               IN app_deploy_provenance_pending.artifact_id%TYPE DEFAULT NULL
                              , ip_artifact_version          IN app_deploy_provenance_pending.artifact_version%TYPE DEFAULT NULL
                              , ip_artifact_classifier       IN app_deploy_provenance_pending.artifact_classifier%TYPE DEFAULT NULL
                              , ip_artifact_extension        IN app_deploy_provenance_pending.artifact_extension%TYPE DEFAULT NULL
                              , ip_package_coordinate        IN app_deploy_provenance_pending.package_coordinate%TYPE DEFAULT NULL
                              , ip_source_repository_url     IN app_deploy_provenance_pending.source_repository_url%TYPE DEFAULT NULL
                              , ip_source_commit_hash        IN app_deploy_provenance_pending.source_commit_hash%TYPE DEFAULT NULL
                              , ip_source_path               IN app_deploy_provenance_pending.source_path%TYPE DEFAULT NULL
                              , ip_build_id                  IN app_deploy_provenance_pending.build_id%TYPE DEFAULT NULL
                              , ip_build_url                 IN app_deploy_provenance_pending.build_url%TYPE DEFAULT NULL
                              , ip_build_time                IN app_deploy_provenance_pending.build_time%TYPE DEFAULT NULL
                              , ip_build_metadata_json       IN app_deploy_provenance_pending.build_metadata_json%TYPE DEFAULT NULL
                              );
/**
 * @description Starts a deployment run and records artifact/build provenance for
 * deployment tooling such as dbpm. Manual deployment scripts can continue using
 * begin_deployment_p without supplying artifact metadata.
 * @param ip_application_name Application being deployed.
 * @param ip_major_version Target major version.
 * @param ip_minor_version Target minor version.
 * @param ip_patch_version Target patch version.
 * @param ip_deployment_type Initial, major, minor, or patch deployment type constant.
 * @param ip_deploy_commit_hash Source control commit associated with the deployment.
 * @param ip_artifact_uri Resolved artifact URL, repository URL, or local path.
 * @param ip_artifact_checksum Checksum of the exact artifact bytes deployed.
 * @param ip_artifact_checksum_alg Checksum algorithm, such as SHA-256.
 * @param ip_package_coordinate Resolved package coordinate from deployment tooling.
 * @param ip_build_metadata_json Free-form build metadata captured as JSON text.
 * @param ip_redeploy_okay Retained for backward compatibility. Exact-version
 * redeploys are allowed for idempotent scripts; lower-version deployments are
 * never allowed.
 * @param ip_notes Optional deployment notes.
 */
   PROCEDURE begin_artifact_deployment_p
                              ( ip_application_name          IN application.application_name%TYPE
                              , ip_major_version             IN application.major_version%TYPE
                              , ip_minor_version             IN application.minor_version%TYPE
                              , ip_patch_version             IN application.patch_version%TYPE
                              , ip_deployment_type           IN application.deploy_type%TYPE DEFAULT c_deploy_type_initial
                              , ip_deploy_commit_hash        IN application.deploy_commit_hash%TYPE DEFAULT c_deploy_commit_hash_unknown
                              , ip_artifact_uri              IN app_deploy_provenance.artifact_uri%TYPE DEFAULT NULL
                              , ip_artifact_checksum         IN app_deploy_provenance.artifact_checksum%TYPE DEFAULT NULL
                              , ip_artifact_checksum_alg     IN app_deploy_provenance.artifact_checksum_alg%TYPE DEFAULT 'SHA-256'
                              , ip_artifact_file_name        IN app_deploy_provenance.artifact_file_name%TYPE DEFAULT NULL
                              , ip_artifact_repository_type  IN app_deploy_provenance.artifact_repository_type%TYPE DEFAULT NULL
                              , ip_artifact_group_id         IN app_deploy_provenance.artifact_group_id%TYPE DEFAULT NULL
                              , ip_artifact_id               IN app_deploy_provenance.artifact_id%TYPE DEFAULT NULL
                              , ip_artifact_version          IN app_deploy_provenance.artifact_version%TYPE DEFAULT NULL
                              , ip_artifact_classifier       IN app_deploy_provenance.artifact_classifier%TYPE DEFAULT NULL
                              , ip_artifact_extension        IN app_deploy_provenance.artifact_extension%TYPE DEFAULT NULL
                              , ip_package_coordinate        IN app_deploy_provenance.package_coordinate%TYPE DEFAULT NULL
                              , ip_source_repository_url     IN app_deploy_provenance.source_repository_url%TYPE DEFAULT NULL
                              , ip_source_commit_hash        IN app_deploy_provenance.source_commit_hash%TYPE DEFAULT NULL
                              , ip_source_path               IN app_deploy_provenance.source_path%TYPE DEFAULT NULL
                              , ip_build_id                  IN app_deploy_provenance.build_id%TYPE DEFAULT NULL
                              , ip_build_url                 IN app_deploy_provenance.build_url%TYPE DEFAULT NULL
                              , ip_build_time                IN app_deploy_provenance.build_time%TYPE DEFAULT NULL
                              , ip_build_metadata_json       IN app_deploy_provenance.build_metadata_json%TYPE DEFAULT NULL
                              , ip_redeploy_okay             IN BOOLEAN DEFAULT FALSE
                              , ip_notes                     IN app_deploy_notes.notes%TYPE DEFAULT NULL
                              );
/**
 * @description Records artifact/build provenance for an already completed
 * deployment. Use this for controlled backfill cases, such as Core bootstrap,
 * when provenance could not be staged before begin_deployment_p ran. This does
 * not create or update deployment status and does not consume pending provenance.
 * @param ip_application_name Application whose completed deployment is being backfilled.
 * @param ip_major_version Completed deployment major version.
 * @param ip_minor_version Completed deployment minor version.
 * @param ip_patch_version Completed deployment patch version.
 * @param ip_deployment_type Completed deployment type.
 * @param ip_deploy_commit_hash Completed deployment commit hash.
 * @param ip_artifact_uri Resolved artifact URL, repository URL, or local path.
 * @param ip_artifact_checksum Checksum of the exact artifact bytes deployed.
 * @param ip_artifact_checksum_alg Checksum algorithm, such as SHA-256.
 * @param ip_package_coordinate Resolved package coordinate from deployment tooling.
 * @param ip_build_metadata_json Free-form build metadata captured as JSON text.
 */
   PROCEDURE record_deployment_provenance_p
                              ( ip_application_name          IN application.application_name%TYPE
                              , ip_major_version             IN application.major_version%TYPE
                              , ip_minor_version             IN application.minor_version%TYPE
                              , ip_patch_version             IN application.patch_version%TYPE
                              , ip_deployment_type           IN application.deploy_type%TYPE DEFAULT c_deploy_type_initial
                              , ip_deploy_commit_hash        IN application.deploy_commit_hash%TYPE DEFAULT c_deploy_commit_hash_unknown
                              , ip_artifact_uri              IN app_deploy_provenance.artifact_uri%TYPE DEFAULT NULL
                              , ip_artifact_checksum         IN app_deploy_provenance.artifact_checksum%TYPE DEFAULT NULL
                              , ip_artifact_checksum_alg     IN app_deploy_provenance.artifact_checksum_alg%TYPE DEFAULT 'SHA-256'
                              , ip_artifact_file_name        IN app_deploy_provenance.artifact_file_name%TYPE DEFAULT NULL
                              , ip_artifact_repository_type  IN app_deploy_provenance.artifact_repository_type%TYPE DEFAULT NULL
                              , ip_artifact_group_id         IN app_deploy_provenance.artifact_group_id%TYPE DEFAULT NULL
                              , ip_artifact_id               IN app_deploy_provenance.artifact_id%TYPE DEFAULT NULL
                              , ip_artifact_version          IN app_deploy_provenance.artifact_version%TYPE DEFAULT NULL
                              , ip_artifact_classifier       IN app_deploy_provenance.artifact_classifier%TYPE DEFAULT NULL
                              , ip_artifact_extension        IN app_deploy_provenance.artifact_extension%TYPE DEFAULT NULL
                              , ip_package_coordinate        IN app_deploy_provenance.package_coordinate%TYPE DEFAULT NULL
                              , ip_source_repository_url     IN app_deploy_provenance.source_repository_url%TYPE DEFAULT NULL
                              , ip_source_commit_hash        IN app_deploy_provenance.source_commit_hash%TYPE DEFAULT NULL
                              , ip_source_path               IN app_deploy_provenance.source_path%TYPE DEFAULT NULL
                              , ip_build_id                  IN app_deploy_provenance.build_id%TYPE DEFAULT NULL
                              , ip_build_url                 IN app_deploy_provenance.build_url%TYPE DEFAULT NULL
                              , ip_build_time                IN app_deploy_provenance.build_time%TYPE DEFAULT NULL
                              , ip_build_metadata_json       IN app_deploy_provenance.build_metadata_json%TYPE DEFAULT NULL
                              );
/**
 * @description Stores free-form deployment notes for the current deployment.
 * @param ip_application_name Application whose deployment notes should be updated.
 * @param ip_notes Notes to record.
 */
   PROCEDURE set_deploy_notes_p( ip_application_name IN application.application_name%TYPE
                               , ip_notes            IN app_deploy_notes.notes%TYPE);
/**
 * @description Marks the active deployment complete and records its end timestamp.
 * @param ip_application_name Application whose deployment should be marked complete.
 */
   PROCEDURE set_deployment_complete_p( ip_application_name IN application.application_name%TYPE);
/**
 * @description Marks the active deployment failed and records its end timestamp.
 * @param ip_application_name Application whose deployment should be marked failed.
 */
   PROCEDURE set_deployment_fail_p( ip_application_name IN application.application_name%TYPE);
/**
 * @description Registers that ip_application_name depends on another application,
 * optionally constrained to a serialized minimum and maximum version range.
 * @param ip_application_name Application declaring the dependency.
 * @param ip_depends_on Required application.
 * @param ip_version_min Minimum serialized version allowed.
 * @param ip_version_max Maximum serialized version allowed.
 */
   PROCEDURE add_dependency_p( ip_application_name IN application.application_name%TYPE
                             , ip_depends_on       IN app_dependency.depends_on%TYPE
                             , ip_version_min      IN app_dependency.version_min%TYPE DEFAULT c_version_min_any
                             , ip_version_max      IN app_dependency.version_max%TYPE DEFAULT c_version_max_any
                             );
/**
 * @description Validates all registered dependencies for an application and records
 * whether each dependency is currently satisfied.
 * @param ip_application_name Application whose dependencies should be validated.
 */
   PROCEDURE validate_dependencies_p( ip_application_name IN application.application_name%TYPE);
/**
 * @description Registers a required system privilege for an application.
 * @param ip_application_name Application requiring the privilege.
 * @param ip_privilege System privilege name.
 */
   PROCEDURE add_sys_priv_p( ip_application_name IN application.application_name%TYPE
                           , ip_privilege        IN app_sys_privs.privilege%TYPE);
/**
 * @description Validates registered system privileges for an application against
 * privileges currently available to the executing schema.
 * @param ip_application_name Application whose system privileges should be validated.
 */
   PROCEDURE validate_sys_privs_p( ip_application_name IN application.application_name%TYPE);
/**
 * @description Registers a required object privilege for an application.
 * @param ip_application_name Application requiring the privilege.
 * @param ip_owner Owner of the referenced object.
 * @param ip_type Object type.
 * @param ip_name Object name.
 * @param ip_privilege Required object privilege.
 */
   PROCEDURE add_obj_priv_p( ip_application_name IN application.application_name%TYPE
                           , ip_owner            IN app_obj_privs.owner%TYPE
                           , ip_type             IN app_obj_privs.type%TYPE
                           , ip_name             IN app_obj_privs.name%TYPE
                           , ip_privilege        IN app_obj_privs.privilege%TYPE);
/**
 * @description Validates registered object privileges for an application against
 * privileges currently available to the executing schema.
 * @param ip_application_name Application whose object privileges should be validated.
 */
   PROCEDURE validate_obj_privs_p( ip_application_name IN application.application_name%TYPE);
/**
 * @description Registers a database object as being owned by an application. Registered
 * objects can later be validated and physically dropped by delete_application_p.
 * @param ip_application_name Application that owns the object.
 * @param ip_object_name Object name.
 * @param ip_object_type Object type.
 */
   PROCEDURE add_object_p( ip_application_name IN application.application_name%TYPE
                         , ip_object_name      IN app_objects.object_name%TYPE
                         , ip_object_type      IN app_object_type.object_type%TYPE DEFAULT c_object_type_table
                         );
   --
/**
 * @description Registers metadata rows owned by ip_application_name that reside in a table
 * belonging to another application. On delete_application_p, core will automatically remove
 * these rows via DELETE FROM ip_object_name WHERE ip_discriminator_col = ip_discriminator_val,
 * or by calling ip_dml_override_proc when a plain DELETE is insufficient.
 * @param ip_application_name The application claiming ownership of the metadata rows.
 * @param ip_object_name The table containing the metadata rows. Must already be registered
 * in APP_OBJECTS (under any application).
 * @param ip_object_type Object type of ip_object_name. Currently only TABLE is supported.
 * @param ip_discriminator_col The column name that identifies rows belonging to this application.
 * Use 'NONE' when ip_dml_override_proc handles all identification internally.
 * @param ip_discriminator_val The value in ip_discriminator_col that marks rows as owned by
 * ip_application_name. Use 'NONE' together with ip_dml_override_proc.
 * @param ip_version Optional semantic version (major.minor.patch) of the metadata registration.
 * @param ip_dml_override_proc Optional procedure name called as BEGIN <proc>; END; instead of
 * the default DELETE. Use when cleanup requires dropping dynamic objects or cascading deletes.
 */
   PROCEDURE add_object_metadata_p( ip_application_name  IN application.application_name%TYPE
                                  , ip_object_name       IN app_objects.object_name%TYPE
                                  , ip_object_type       IN app_object_type.object_type%TYPE DEFAULT c_object_type_table
                                  , ip_discriminator_col IN app_object_metadata.discriminator_col%TYPE DEFAULT 'NONE'
                                  , ip_discriminator_val IN app_object_metadata.discriminator_val%TYPE DEFAULT 'NONE'
                                  , ip_version           IN app_object_metadata.version%TYPE DEFAULT NULL
                                  , ip_dml_override_proc IN app_object_metadata.dml_override_proc%TYPE DEFAULT NULL
                                  );
/**
 * @description Removes a single metadata registration and executes its associated cleanup
 * (DELETE or dml_override_proc). Called automatically by delete_application_p for all
 * registered metadata; call directly only to deregister a specific entry mid-deployment.
 * @param ip_application_name The application that owns the metadata registration.
 * @param ip_object_name The table the metadata registration points to.
 * @param ip_object_type Object type of ip_object_name.
 * @param ip_discriminator_col The discriminator column recorded at registration time.
 * @param ip_discriminator_val The discriminator value recorded at registration time.
 */
   --
   PROCEDURE delete_object_metadata_p( ip_application_name  IN application.application_name%TYPE
                                     , ip_object_name       IN app_objects.object_name%TYPE
                                     , ip_object_type       IN app_object_type.object_type%TYPE DEFAULT c_object_type_table
                                     , ip_discriminator_col IN app_object_metadata.discriminator_col%TYPE
                                     , ip_discriminator_val IN app_object_metadata.discriminator_val%TYPE
                                     );
/**
 * @description Validates that all database objects registered to an application
 * currently exist.
 * @param ip_application_name Application whose registered objects should be validated.
 */
   PROCEDURE validate_objects_p( ip_application_name IN application.application_name%TYPE); --bugbug: should we validate object_metadata?
/**
 * @description Fully removes an application and all objects registered to it. Cleanup order:
 * (1) all metadata registrations are processed (dml_override_proc called where set, otherwise
 * DELETE FROM table WHERE col = val); (2) all registered database objects are physically dropped
 * via DROP statements; (3) application and dictionary records are deleted.
 * @param ip_application_name The application to remove.
 * @param ip_fail_on_not_found 'Y' (default) raises an error if the application is not found;
 * 'N' silently succeeds.
 */
   PROCEDURE delete_application_p( ip_application_name  IN application.application_name%TYPE
                                 , ip_fail_on_not_found IN VARCHAR2 DEFAULT 'Y' );
/**
 * @description Deletes all non-CORE application-registry data and drops all registered
 * objects. This is destructive and is intended only for explicit development reset
 * scenarios. Requires exact confirmation text and DEPLOY_LOCKED=N.
 * @param ip_confirm Must equal c_delete_system_confirm. Defaults to NULL so
 * legacy no-argument calls fail safely at runtime instead of failing to compile.
 */
   PROCEDURE delete_system_p( ip_confirm IN VARCHAR2 DEFAULT NULL );
/**
 * @description Physically drops a database object by type and name. The registry row,
 * if any, is not removed by this procedure.
 * @param ip_object_type Object type to drop.
 * @param ip_object_name Object name to drop.
 */
   PROCEDURE drop_object_p( ip_object_type IN app_objects.object_type%TYPE
                          , ip_object_name IN app_objects.object_name%TYPE );

/**
 * @description Removes an object from the registry without physically dropping it.
 * @param ip_object_type Object type to forget.
 * @param ip_object_name Object name to remove from the registry.
 */
   PROCEDURE forget_object_p( ip_object_type IN app_objects.object_type%TYPE
                            , ip_object_name IN app_objects.object_name%TYPE );
/**
 * @description Physically drops an object and removes its registry entry. This is
 * destructive and should be used only when the object is known to be application-owned.
 * @param ip_object_type Object type to drop and forget.
 * @param ip_object_name Object name to drop and remove from the registry.
 */
   PROCEDURE drop_and_forget_object_p( ip_object_type IN app_objects.object_type%TYPE
                                     , ip_object_name IN app_objects.object_name%TYPE );
/**
 * @description Transfers a registered object from one application owner to another.
 * Use this when refactoring application boundaries without physically moving or
 * recreating the database object.
 * @param ip_object_name Object whose registry ownership should change.
 * @param ip_new_application_name New owning application.
 * @param ip_object_type Object type.
 * @param ip_old_application_name Optional current owner used to disambiguate duplicate names.
 */
   PROCEDURE change_object_application_p( ip_object_name           IN app_objects.object_name%TYPE
                                        , ip_new_application_name  IN application.application_name%TYPE
                                        , ip_object_type           IN app_object_type.object_type%TYPE DEFAULT c_object_type_table
                                        , ip_old_application_name  IN application.application_name%TYPE DEFAULT NULL );
   --
END PKG_APPLICATION;
/
