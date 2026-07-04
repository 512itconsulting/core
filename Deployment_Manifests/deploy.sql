SET DEFINE ON
DEFINE APPLICATION_NAME = 'CORE'
DEFINE DEPLOY_VERSION_MAJOR = '3'
DEFINE DEPLOY_VERSION_MINOR = '5'
DEFINE DEPLOY_VERSION_PATCH = '0'
DEFINE DEPLOY_COMMIT_HASH = '&&1'

COLUMN CURRENT_SCHEMA       new_value CURRENT_SCHEMA      
SELECT sys_context('USERENV','CURRENT_SCHEMA') AS CURRENT_SCHEMA FROM DUAL;

SPOOL deploy.&&APPLICATION_NAME..&&CURRENT_SCHEMA..&&DEPLOY_VERSION_MAJOR..&&DEPLOY_VERSION_MINOR..&&DEPLOY_VERSION_PATCH..log

--PRINT BIND VARIABLE VALUES
SET AUTOPRINT ON                    

--THE START COMMAND WILL LIST EACH COMMAND IN A SCRIPT
REM SET ECHO ON                         

--DISPLAY DBMS_OUTPUT.PUT_LINE OUTPUT
SET SERVEROUTPUT ON                 

--SHOW THE OLD AND NEW SETTINGS OF A SQLPLUS SYSTEM VARIABLE
REM SET SHOWMODE ON                     

--ALLOW BLANK LINES WITHIN A SQL COMMAND OR SCRIPT
SET SQLBLANKLINES ON                

WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE

EXEC EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';

PROMPT Beginning deployment of &&APPLICATION_NAME

DECLARE
    l_object_count NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO l_object_count
      FROM user_objects
     WHERE object_name IN (
               'PKG_APPLICATION',
               'APPLICATION',
               'APP_DICTIONARY'
           );

    IF l_object_count > 0 THEN
        raise_application_error(
            -20000,
            'CORE appears to already be deployed. Aborting deployment. ' ||
            'Run the uninstall script first, or use an upgrade/redeploy script.'
        );
    END IF;
END;
/

--Sequences
PROMPT Creating Sequences

--Tables
Prompt Creating Tables
@@../Tables/APP_OBJ_NAMESPACE.sql
@@../Tables/APPLICATION.sql
@@../Tables/APP_DEPLOY_NOTES.sql --Depends on: APPLICATION
@@../Tables/APP_DEPENDENCY.sql   --Depends on: APPLICATION
@@../Tables/APP_OBJECT_TYPE.sql  --Depends on: APP_OBJ_NAMESPACE
@@../Tables/APP_OBJECTS.sql      --Depends on: APPLICATION, APP_OBJECT_TYPE
@@../Tables/APP_OBJ_PRIVS.sql    --Depends on: APPLICATION
@@../Tables/APP_SYS_PRIVS.sql    --Depends on: APPLICATION
@@../Tables/APP_OBJECT_METADATA.sql --Depends on: APP_OBJECTS
@@../Tables/APP_DEPLOY_HIST.sql
@@../Tables/APP_DEPLOY_PROVENANCE.sql --Depends on: APPLICATION
@@../Tables/APP_DEPLOY_PROVENANCE_PENDING.sql
@@../Tables/APP_DICTIONARY.sql
@@../Tables/SYSTEM_LOG.sql
@@../Tables/TRACE_LOG.sql

--Procedures
Prompt Creating Procedures
@@../Procedures/Assert.prc.sql

--Types
Prompt Creating Types
@@../Types/NUM_TAB.sql
@@../Types/VARCHAR_TAB.sql

--Package Specifications
Prompt Creating Package Specifications
@@../Packages/PKG_APPLICATION.pks
@@../Packages/PKG_APP_DICT.pks
@@../Packages/PKG_SYSLOG.pks
@@../Packages/PKG_STRING.pks
@@../Packages/PKG_TRACE.pks

--Package Bodies
Prompt Creating Package Bodies
@@../Packages/PKG_APPLICATION.pkb
@@../Packages/PKG_APP_DICT.pkb
@@../Packages/PKG_SYSLOG.pkb
@@../Packages/PKG_STRING.pkb
@@../Packages/PKG_TRACE.pkb

--Metadata
Prompt Deploying Metadata
@@../Metadata/APP_OBJ_NAMESPACE
@@../Metadata/APP_OBJECT_TYPE

--since we just created them, let's do begin and end deployment here, so it is tracked.
SET DEFINE ON
--
BEGIN
   pkg_application.begin_deployment_p     
      ( ip_deploy_commit_hash => '&&DEPLOY_COMMIT_HASH'
      , ip_application_name   => '&&APPLICATION_NAME'
      , ip_major_version      => &&DEPLOY_VERSION_MAJOR
      , ip_minor_version      => &&DEPLOY_VERSION_MINOR
      , ip_patch_version      => &&DEPLOY_VERSION_PATCH
      , ip_deployment_type    => pkg_application.c_deploy_type_initial  --c_deploy_type_minor
      --, ip_redeploy_curr_okay => TRUE
      , ip_notes => 
Q'{
3.5.0
* Add DEPLOY_LOCKED deployment safety metadata
* Add manual deployment env generation for non-dbpm installs
* Gate pkg_application.delete_system_p behind confirmation and DEPLOY_LOCKED
* Make DEPLOY_LOCKED package helper initial-config only
3.4.2
* Publish Core under the 512itconsulting dbpm registry publisher
3.4.1
* Prevent lower-version deployments
* Add serialized version component bounds checks
3.4.0
* Add pkg_application.record_deployment_provenance_p
3.3.0
* Add pkg_application.get_deployment_provenance_json_f
3.2.0
* Add APP_DEPLOY_PROVENANCE_PENDING
* Add pkg_application.stage_deployment_provenance_p
* Consume pending deployment provenance from pkg_application.begin_deployment_p
3.1.0
* Add APP_DEPLOY_PROVENANCE
* Add pkg_application.begin_artifact_deployment_p
3.0.0
* Add table SYSTEM_LOG
* Add PKG_SYSLOG
* Drop PKG_ERROR_UTIL
* Drop table ERROR_LOG
2.5.0
* Add varchar_tab
* Add pkg_string
2.4.0
* Add pkg_application.serialize_version_f
* Add pkg_application.deserialize_version_f
2.3.0:
* Add "MATERIALIZED VIEW" object type
* Add pkg_application.drop_and_forget_object_p
* Add pkg_application.change_object_application_p
2.2.0:
* Replace app_object_metadata table with new structure
* Modify pkg_application to update add_object_metadata_p, add delete_object_metadata_p, call delete_object_metadata_p from within delete_application_p
2.1.0:
* Add the table APP_DEPLOY_NOTES
* Add pkg_application.get_current_version_f
* Add pkg_application.set_deploy_notes_p
--
2.0.0:
* Add support for semantic versioning (major, minor, patch)
}'
      );
END;
/

--SEQUENCES
--TABLES
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_DEPENDENCY'   , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_DEPLOY_NOTES' , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_OBJ_NAMESPACE', ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_OBJ_PRIVS'    , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_OBJECT_TYPE'  , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_OBJECTS'      , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_OBJECT_METADATA', ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_SYS_PRIVS'    , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APPLICATION'      , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_DEPLOY_HIST'      , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_DEPLOY_PROVENANCE', ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_DEPLOY_PROVENANCE_PENDING', ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'APP_DICTIONARY'      , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'SYSTEM_LOG'        , ip_object_type => pkg_application.c_object_type_table);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'TRACE_LOG'      , ip_object_type => pkg_application.c_object_type_table);
--PROCEDURES
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'ASSERT'           , ip_object_type => pkg_application.c_object_type_procedure);
--TYPES
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'NUM_TAB'          , ip_object_type => pkg_application.c_object_type_type);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'VARCHAR_TAB'      , ip_object_type => pkg_application.c_object_type_type);
--PACKAGE SPECS / PACKAGE BODIES
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_APPLICATION'  , ip_object_type => pkg_application.c_object_type_package);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_APPLICATION'  , ip_object_type => pkg_application.c_object_type_package_body);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_APP_DICT'  , ip_object_type => pkg_application.c_object_type_package);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_APP_DICT'  , ip_object_type => pkg_application.c_object_type_package_body);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_SYSLOG'   , ip_object_type => pkg_application.c_object_type_package);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_SYSLOG'   , ip_object_type => pkg_application.c_object_type_package_body);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_STRING'  , ip_object_type => pkg_application.c_object_type_package);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_STRING'  , ip_object_type => pkg_application.c_object_type_package_body);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_TRACE'  , ip_object_type => pkg_application.c_object_type_package);
EXEC pkg_application.add_object_p(ip_application_name => '&&APPLICATION_NAME', ip_object_name => 'PKG_TRACE'  , ip_object_type => pkg_application.c_object_type_package_body);
--SYS PRIVS
--EXEC pkg_application.add_sys_priv_p(ip_application_name => '&&APPLICATION_NAME', ip_privilege => 'SELECT ANY DICTIONARY');
--
EXEC pkg_application.validate_objects_p(ip_application_name => '&&APPLICATION_NAME');
EXEC pkg_application.validate_sys_privs_p(ip_application_name => '&&APPLICATION_NAME');
EXEC pkg_app_dict.set_deployment_metadata_p(ip_deploy_locked => q'[&&DEPLOY_LOCKED]', ip_deploy_environment => q'[&&DEPLOY_ENVIRONMENT]');
--
EXEC pkg_application.set_deployment_complete_p(ip_application_name => '&&APPLICATION_NAME');

PROMPT  &&APPLICATION_NAME deployment complete

SPOOL OFF
EXIT SUCCESS
