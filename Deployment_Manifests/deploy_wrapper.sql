SET DEFINE ON
SET SHOWMODE OFF
COLUMN CURRENT_SCHEMA       new_value CURRENT_SCHEMA      

SELECT sys_context('USERENV','CURRENT_SCHEMA') AS CURRENT_SCHEMA FROM DUAL;

WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE

-- Manual install wrapper only. dbpm injects these values directly and does not
-- call this wrapper. Run ./generate_env.sh before this script.
@@./env.sql

ALTER SESSION DISABLE PARALLEL DML;
PROMPT Configure Core deployment metadata.
ACCEPT DEPLOY_ENVIRONMENT CHAR PROMPT 'Deployment environment label (i.e. DEV, QLAB01, PLAB, PROD): '
ACCEPT DEPLOY_LOCKED      CHAR PROMPT 'Deployment locked? Y blocks dangerous deployment behavior; N allows development workflows (Y/N): '

@@./deploy.sql &CORE

SELECT * FROM APP_DICTIONARY;
