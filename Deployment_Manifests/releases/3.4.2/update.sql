SET DEFINE ON
DEFINE APPLICATION_NAME = 'CORE'
DEFINE DEPLOY_VERSION_MAJOR = '3'
DEFINE DEPLOY_VERSION_MINOR = '4'
DEFINE DEPLOY_VERSION_PATCH = '2'
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
      , ip_deployment_type    => pkg_application.c_deploy_type_patch
      , ip_notes =>
Q'{
3.4.2
* Publish Core under the 512itconsulting dbpm registry publisher
}'
      );
END;
/

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
