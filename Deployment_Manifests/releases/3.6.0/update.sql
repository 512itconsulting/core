SET DEFINE ON
DEFINE APPLICATION_NAME = 'CORE'
DEFINE DEPLOY_VERSION_MAJOR = '3'
DEFINE DEPLOY_VERSION_MINOR = '6'
DEFINE DEPLOY_VERSION_PATCH = '0'
DEFINE DEPLOY_COMMIT_HASH = '&&1'

COLUMN CURRENT_SCHEMA new_value CURRENT_SCHEMA
SELECT sys_context('USERENV','CURRENT_SCHEMA') AS CURRENT_SCHEMA FROM DUAL;

SPOOL update.&&APPLICATION_NAME..&&CURRENT_SCHEMA..&&DEPLOY_VERSION_MAJOR..&&DEPLOY_VERSION_MINOR..&&DEPLOY_VERSION_PATCH..log

SET AUTOPRINT ON
SET SERVEROUTPUT ON
SET SQLBLANKLINES ON

WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE

EXEC EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';

PROMPT Beginning update of &&APPLICATION_NAME to &&DEPLOY_VERSION_MAJOR..&&DEPLOY_VERSION_MINOR..&&DEPLOY_VERSION_PATCH

BEGIN
   pkg_application.begin_deployment_p
      ( ip_deploy_commit_hash => '&&DEPLOY_COMMIT_HASH'
      , ip_application_name   => '&&APPLICATION_NAME'
      , ip_major_version      => &&DEPLOY_VERSION_MAJOR
      , ip_minor_version      => &&DEPLOY_VERSION_MINOR
      , ip_patch_version      => &&DEPLOY_VERSION_PATCH
      , ip_deployment_type    => pkg_application.c_deploy_type_minor
      , ip_notes =>
Q'{
3.6.0
* Add PKG_CORE_OPERATION: Core-owned fenced operation leases, replacing the
  transitional APP_DICTIONARY-based DBPM_OP_* scheme with a supported API
  (begin_and_acquire_operation_p, verify_fence_p, renew_operation_lease_p,
  record_operation_step_p, release_operation_lease_p) and a scope hierarchy
  (SCHEMA_LIFECYCLE, SCHEMA_RUNTIME, APPLICATION:<name>)
* Add PKG_CORE_SCHEMA_RUNTIME and the schema-runtime registry
  (CORE_SCHEMA_RUNTIME, CORE_RUNTIME_REVISION, CORE_RUNTIME_CONTRIBUTION,
  CORE_RUNTIME_REQUIREMENT, CORE_RUNTIME_ACK): Core-owned authority over the
  one dbpm runtime binding per schema, desired/active revision tracking, and
  fenced activation/removal acknowledgement, per
  docs/core-schema-runtime-architecture.md
* New Core-owned tables and packages use a CORE_ prefix to sort together and
  avoid colliding with installed-application object names in the shared schema
* Gate begin_runtime_removal_p behind DEPLOY_LOCKED=N and
  DBPM_ALLOW_ENVIRONMENT_RESET=Y, per Invariant 10
* Persist and expose the actor on bind_schema_runtime_p (CORE_SCHEMA_RUNTIME.ACTOR)
* Add record_database_complete_p and abandon_runtime_revision_p so
  CORE_RUNTIME_REVISION.revision_status can reach DATABASE_COMPLETE and
  FAILED; acknowledge_runtime_active_p now requires STAGED or
  DATABASE_COMPLETE
* Add record_runtime_validated_p and wire the VALIDATED acknowledgement type
  for reconciliation evidence
* Add PKG_APP_DICT.set_capability_p, apply_lifecycle_profile_p, and
  get_lifecycle_capabilities_p: Core-owned administration for the five
  DBPM_ALLOW_* keys and DEVELOPER/DISPOSABLE profile expansion, audited in
  the new CORE_CAPABILITY_AUDIT table, per
  docs/core-operation-api-followup.md's "Lifecycle capability profiles and
  provisioning" section. DBPM_ALLOW_ENVIRONMENT_RESET is never implied by
  either profile, and DBPM_ALLOW_GRAPH_RESET is granted only by DISPOSABLE
}'
      );
END;
/

PROMPT Creating Tables
@@../Tables/CORE_OPERATION.sql
@@../Tables/CORE_OPERATION_SCOPE.sql
@@../Tables/CORE_OPERATION_STEP.sql
@@../Tables/CORE_OPERATION_LOCK.sql
@@../Tables/CORE_SCHEMA_RUNTIME.sql
@@../Tables/CORE_SCHEMA_RUNTIME_AUDIT.sql
@@../Tables/CORE_RUNTIME_REVISION.sql
@@../Tables/CORE_RUNTIME_CONTRIBUTION.sql
@@../Tables/CORE_RUNTIME_REQUIREMENT.sql
@@../Tables/CORE_RUNTIME_ACK.sql
@@../Tables/CORE_CAPABILITY_AUDIT.sql

INSERT INTO core_operation_lock (lock_id) VALUES ('X');

PROMPT Creating Package Specifications
@@../Packages/PKG_APP_DICT.pks
@@../Packages/PKG_CORE_OPERATION.pks
@@../Packages/PKG_CORE_SCHEMA_RUNTIME.pks

PROMPT Creating Package Bodies
@@../Packages/PKG_APP_DICT.pkb
@@../Packages/PKG_CORE_OPERATION.pkb
@@../Packages/PKG_CORE_SCHEMA_RUNTIME.pkb

EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_OPERATION'               , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_OPERATION_SCOPE'         , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_OPERATION_STEP'          , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_OPERATION_LOCK' , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_SCHEMA_RUNTIME'          , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_SCHEMA_RUNTIME_AUDIT'    , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_SCHEMA_RUNTIME_AUDIT_SEQ', ip_object_type => pkg_application.c_object_type_sequence);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_RUNTIME_REVISION'        , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_RUNTIME_CONTRIBUTION'    , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_RUNTIME_REQUIREMENT'     , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_RUNTIME_ACK' , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_RUNTIME_ACK_SEQ', ip_object_type => pkg_application.c_object_type_sequence);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_CORE_OPERATION'           , ip_object_type => pkg_application.c_object_type_package);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_CORE_OPERATION'           , ip_object_type => pkg_application.c_object_type_package_body);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_CORE_SCHEMA_RUNTIME'      , ip_object_type => pkg_application.c_object_type_package);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_CORE_SCHEMA_RUNTIME'      , ip_object_type => pkg_application.c_object_type_package_body);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_CAPABILITY_AUDIT'        , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'CORE_CAPABILITY_AUDIT_SEQ'    , ip_object_type => pkg_application.c_object_type_sequence);

PROMPT Recompiling invalid objects
BEGIN
   DBMS_UTILITY.COMPILE_SCHEMA
      ( schema         => SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
      , compile_all    => FALSE
      , reuse_settings => TRUE
      );
END;
/

EXEC pkg_application.validate_objects_p(ip_application_name => '&&APPLICATION_NAME');
EXEC pkg_application.validate_sys_privs_p(ip_application_name => '&&APPLICATION_NAME');
EXEC pkg_application.set_deployment_complete_p(ip_application_name => '&&APPLICATION_NAME');

PROMPT &&APPLICATION_NAME update complete

SPOOL OFF
EXIT SUCCESS
