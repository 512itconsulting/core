SET DEFINE ON
DEFINE APPLICATION_NAME = 'CORE'
DEFINE DEPLOY_VERSION_MAJOR = '3'
DEFINE DEPLOY_VERSION_MINOR = '5'
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
3.5.0
* Add DEPLOY_LOCKED deployment safety metadata
* Add manual deployment env generation for non-dbpm installs
* Gate pkg_application.delete_system_p behind confirmation and DEPLOY_LOCKED
}'
      );
END;
/

EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_APPLICATION', ip_object_type => pkg_application.c_object_type_package);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_APPLICATION', ip_object_type => pkg_application.c_object_type_package_body);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_APP_DICT', ip_object_type => pkg_application.c_object_type_package);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_APP_DICT', ip_object_type => pkg_application.c_object_type_package_body);

PROMPT Creating Package Specifications
@@../../../Packages/PKG_APPLICATION.pks
@@../../../Packages/PKG_APP_DICT.pks

PROMPT Creating Package Bodies
@@../../../Packages/PKG_APPLICATION.pkb
@@../../../Packages/PKG_APP_DICT.pkb

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
