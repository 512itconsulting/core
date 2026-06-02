CREATE OR REPLACE PACKAGE BODY PKG_APPLICATION
AS
--PRIVATE
PROCEDURE get_application_rec_p( ip_application_name IN application.application_name%TYPE
                               , op_rec_application OUT application%ROWTYPE
                               , ip_fail_on_not_found IN VARCHAR2 DEFAULT 'Y' )
IS
BEGIN
   assert(ip_fail_on_not_found IN ('Y','N'));

   SELECT *
     INTO op_rec_application
     FROM application
    WHERE application_name = ip_application_name;
EXCEPTION
   WHEN NO_DATA_FOUND THEN
      IF ip_fail_on_not_found = 'Y' THEN
         RAISE;
      END IF;
END get_application_rec_p;



PROCEDURE arch_application_rec_P( ip_rec_application IN application%ROWTYPE )
IS
BEGIN
   INSERT 
     INTO app_deploy_hist
        ( log_ts
        , application_name
        , major_version
        , minor_version
        , patch_version
        , deploy_type
        , deploy_status
        , deploy_begin
        , deploy_end
        , deploy_commit_hash
        )
   SELECT SYSDATE
        , ip_rec_application.application_name
        , ip_rec_application.major_version
        , ip_rec_application.minor_version
        , ip_rec_application.patch_version
        , ip_rec_application.deploy_type
        , ip_rec_application.deploy_status
        , ip_rec_application.deploy_begin
        , ip_rec_application.deploy_end
        , ip_rec_application.deploy_commit_hash
     FROM dual;

   --calling proc commits
END arch_application_rec_P;



FUNCTION same_varchar_f( ip_left IN VARCHAR2
                       , ip_right IN VARCHAR2 )
   RETURN BOOLEAN
IS
BEGIN
   IF ip_left IS NULL AND ip_right IS NULL THEN
      RETURN TRUE;
   ELSIF ip_left IS NULL OR ip_right IS NULL THEN
      RETURN FALSE;
   ELSE
      RETURN ip_left = ip_right;
   END IF;
END same_varchar_f;



FUNCTION same_clob_f( ip_left IN CLOB
                    , ip_right IN CLOB )
   RETURN BOOLEAN
IS
BEGIN
   IF ip_left IS NULL AND ip_right IS NULL THEN
      RETURN TRUE;
   ELSIF ip_left IS NULL OR ip_right IS NULL THEN
      RETURN FALSE;
   ELSE
      RETURN DBMS_LOB.COMPARE(ip_left, ip_right) = 0;
   END IF;
END same_clob_f;



PROCEDURE record_deploy_provenance_p
                           ( ip_rec_application          IN application%ROWTYPE
                           , ip_artifact_uri             IN app_deploy_provenance.artifact_uri%TYPE DEFAULT NULL
                           , ip_artifact_checksum        IN app_deploy_provenance.artifact_checksum%TYPE DEFAULT NULL
                           , ip_artifact_checksum_alg    IN app_deploy_provenance.artifact_checksum_alg%TYPE DEFAULT 'SHA-256'
                           , ip_artifact_file_name       IN app_deploy_provenance.artifact_file_name%TYPE DEFAULT NULL
                           , ip_artifact_repository_type IN app_deploy_provenance.artifact_repository_type%TYPE DEFAULT NULL
                           , ip_artifact_group_id        IN app_deploy_provenance.artifact_group_id%TYPE DEFAULT NULL
                           , ip_artifact_id              IN app_deploy_provenance.artifact_id%TYPE DEFAULT NULL
                           , ip_artifact_version         IN app_deploy_provenance.artifact_version%TYPE DEFAULT NULL
                           , ip_artifact_classifier      IN app_deploy_provenance.artifact_classifier%TYPE DEFAULT NULL
                           , ip_artifact_extension       IN app_deploy_provenance.artifact_extension%TYPE DEFAULT NULL
                           , ip_package_coordinate       IN app_deploy_provenance.package_coordinate%TYPE DEFAULT NULL
                           , ip_source_repository_url    IN app_deploy_provenance.source_repository_url%TYPE DEFAULT NULL
                           , ip_source_commit_hash       IN app_deploy_provenance.source_commit_hash%TYPE DEFAULT NULL
                           , ip_source_path              IN app_deploy_provenance.source_path%TYPE DEFAULT NULL
                           , ip_build_id                 IN app_deploy_provenance.build_id%TYPE DEFAULT NULL
                           , ip_build_url                IN app_deploy_provenance.build_url%TYPE DEFAULT NULL
                           , ip_build_time               IN app_deploy_provenance.build_time%TYPE DEFAULT NULL
                           , ip_build_metadata_json      IN app_deploy_provenance.build_metadata_json%TYPE DEFAULT NULL
                           , ip_replace_existing         IN BOOLEAN DEFAULT TRUE
                           )
IS
   rec_provenance      app_deploy_provenance%ROWTYPE;
   l_exists            BOOLEAN := FALSE;
   l_source_commit_hash app_deploy_provenance.source_commit_hash%TYPE;
   l_same              BOOLEAN;
BEGIN
   l_source_commit_hash := NVL(ip_source_commit_hash, ip_rec_application.deploy_commit_hash);

   BEGIN
      SELECT *
        INTO rec_provenance
        FROM app_deploy_provenance
       WHERE application_name = ip_rec_application.application_name
         AND deploy_begin = ip_rec_application.deploy_begin;

      l_exists := TRUE;
   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         l_exists := FALSE;
   END;

   IF l_exists THEN
      l_same := same_varchar_f(rec_provenance.artifact_uri, ip_artifact_uri)
            AND same_varchar_f(rec_provenance.artifact_checksum, ip_artifact_checksum)
            AND same_varchar_f(rec_provenance.artifact_checksum_alg, ip_artifact_checksum_alg)
            AND same_varchar_f(rec_provenance.artifact_file_name, ip_artifact_file_name)
            AND same_varchar_f(rec_provenance.artifact_repository_type, ip_artifact_repository_type)
            AND same_varchar_f(rec_provenance.artifact_group_id, ip_artifact_group_id)
            AND same_varchar_f(rec_provenance.artifact_id, ip_artifact_id)
            AND same_varchar_f(rec_provenance.artifact_version, ip_artifact_version)
            AND same_varchar_f(rec_provenance.artifact_classifier, ip_artifact_classifier)
            AND same_varchar_f(rec_provenance.artifact_extension, ip_artifact_extension)
            AND same_varchar_f(rec_provenance.package_coordinate, ip_package_coordinate)
            AND same_varchar_f(rec_provenance.source_repository_url, ip_source_repository_url)
            AND same_varchar_f(rec_provenance.source_commit_hash, l_source_commit_hash)
            AND same_varchar_f(rec_provenance.source_path, ip_source_path)
            AND same_varchar_f(rec_provenance.build_id, ip_build_id)
            AND same_varchar_f(rec_provenance.build_url, ip_build_url)
            AND same_varchar_f(rec_provenance.build_time, ip_build_time)
            AND same_clob_f(rec_provenance.build_metadata_json, ip_build_metadata_json);

      IF l_same THEN
         GOTO end_now;
      END IF;

      assert(ip_replace_existing, 'Deployment provenance already exists and differs for '
                                  ||ip_rec_application.application_name||' '
                                  ||ip_rec_application.major_version||'.'
                                  ||ip_rec_application.minor_version||'.'
                                  ||ip_rec_application.patch_version
                                  ||' commit '||ip_rec_application.deploy_commit_hash);

      DELETE
        FROM app_deploy_provenance
       WHERE application_name = ip_rec_application.application_name
         AND deploy_begin = ip_rec_application.deploy_begin;
   END IF;

   INSERT
     INTO app_deploy_provenance
        ( application_name
        , major_version
        , minor_version
        , patch_version
        , deploy_type
        , deploy_commit_hash
        , deploy_begin
        , artifact_uri
        , artifact_checksum
        , artifact_checksum_alg
        , artifact_file_name
        , artifact_repository_type
        , artifact_group_id
        , artifact_id
        , artifact_version
        , artifact_classifier
        , artifact_extension
        , package_coordinate
        , source_repository_url
        , source_commit_hash
        , source_path
        , build_id
        , build_url
        , build_time
        , build_metadata_json
        )
   VALUES
        ( ip_rec_application.application_name
        , ip_rec_application.major_version
        , ip_rec_application.minor_version
        , ip_rec_application.patch_version
        , ip_rec_application.deploy_type
        , ip_rec_application.deploy_commit_hash
        , ip_rec_application.deploy_begin
        , ip_artifact_uri
        , ip_artifact_checksum
        , ip_artifact_checksum_alg
        , ip_artifact_file_name
        , ip_artifact_repository_type
        , ip_artifact_group_id
        , ip_artifact_id
        , ip_artifact_version
        , ip_artifact_classifier
        , ip_artifact_extension
        , ip_package_coordinate
        , ip_source_repository_url
        , l_source_commit_hash
        , ip_source_path
        , ip_build_id
        , ip_build_url
        , ip_build_time
        , ip_build_metadata_json
        );

   <<end_now>>
   NULL;

   --calling proc commits
END record_deploy_provenance_p;



PROCEDURE consume_pending_deploy_provenance_p( ip_rec_application IN application%ROWTYPE )
IS
BEGIN
   FOR rec_pending
    IN
    (
      SELECT *
        FROM app_deploy_provenance_pending
       WHERE application_name = ip_rec_application.application_name
         AND major_version = ip_rec_application.major_version
         AND minor_version = ip_rec_application.minor_version
         AND patch_version = ip_rec_application.patch_version
         AND deploy_type = ip_rec_application.deploy_type
         AND deploy_commit_hash = ip_rec_application.deploy_commit_hash
    )
   LOOP
      record_deploy_provenance_p
         ( ip_rec_application          => ip_rec_application
         , ip_artifact_uri             => rec_pending.artifact_uri
         , ip_artifact_checksum        => rec_pending.artifact_checksum
         , ip_artifact_checksum_alg    => rec_pending.artifact_checksum_alg
         , ip_artifact_file_name       => rec_pending.artifact_file_name
         , ip_artifact_repository_type => rec_pending.artifact_repository_type
         , ip_artifact_group_id        => rec_pending.artifact_group_id
         , ip_artifact_id              => rec_pending.artifact_id
         , ip_artifact_version         => rec_pending.artifact_version
         , ip_artifact_classifier      => rec_pending.artifact_classifier
         , ip_artifact_extension       => rec_pending.artifact_extension
         , ip_package_coordinate       => rec_pending.package_coordinate
         , ip_source_repository_url    => rec_pending.source_repository_url
         , ip_source_commit_hash       => rec_pending.source_commit_hash
         , ip_source_path              => rec_pending.source_path
         , ip_build_id                 => rec_pending.build_id
         , ip_build_url                => rec_pending.build_url
         , ip_build_time               => rec_pending.build_time
         , ip_build_metadata_json      => rec_pending.build_metadata_json
         );

      DELETE
        FROM app_deploy_provenance_pending
       WHERE application_name = rec_pending.application_name
         AND major_version = rec_pending.major_version
         AND minor_version = rec_pending.minor_version
         AND patch_version = rec_pending.patch_version
         AND deploy_type = rec_pending.deploy_type
         AND deploy_commit_hash = rec_pending.deploy_commit_hash;
   END LOOP;

   --calling proc commits
END consume_pending_deploy_provenance_p;



PROCEDURE get_object_type_p( ip_object_type      IN app_object_type.object_type%TYPE
                           , op_rec_object_type OUT app_object_type%ROWTYPE )
IS
BEGIN
   SELECT *
     INTO op_rec_object_type
     FROM app_object_type
    WHERE object_type = ip_object_type;
END get_object_type_p;



PROCEDURE get_object_p( ip_object_name      IN app_objects.object_name%TYPE
                      , ip_object_namespace IN app_objects.object_namespace%TYPE
                      , op_rec_object      OUT app_objects%ROWTYPE )
IS
BEGIN
   SELECT *
     INTO op_rec_object
     FROM app_objects
    WHERE object_name = ip_object_name
      AND object_namespace = ip_object_namespace;
END get_object_p;



--PUBLIC
FUNCTION get_current_version_f( ip_application_name IN application.application_name%TYPE )
   RETURN VARCHAR
IS 
   l_retvar VARCHAR(100);
BEGIN
   SELECT major_version||'.'||minor_version||'.'||patch_version AS sem_ver
     INTO l_retvar
     FROM application
    WHERE application_name = ip_application_name;
   
   RETURN l_retvar;
END get_current_version_f;



FUNCTION get_deployment_provenance_json_f
   ( ip_application_name IN application.application_name%TYPE
   , ip_major_version    IN application.major_version%TYPE DEFAULT NULL
   , ip_minor_version    IN application.minor_version%TYPE DEFAULT NULL
   , ip_patch_version    IN application.patch_version%TYPE DEFAULT NULL
   )
   RETURN CLOB
IS
   l_retvar CLOB;
BEGIN
   SELECT JSON_OBJECT
          ( 'application_name'          VALUE application_name
          , 'major_version'             VALUE major_version
          , 'minor_version'             VALUE minor_version
          , 'patch_version'             VALUE patch_version
          , 'deploy_type'               VALUE deploy_type
          , 'deploy_commit_hash'        VALUE deploy_commit_hash
          , 'deploy_begin'              VALUE TO_CHAR(deploy_begin, 'YYYY-MM-DD"T"HH24:MI:SS')
          , 'artifact_uri'              VALUE artifact_uri
          , 'artifact_checksum'         VALUE artifact_checksum
          , 'artifact_checksum_alg'     VALUE artifact_checksum_alg
          , 'artifact_file_name'        VALUE artifact_file_name
          , 'artifact_repository_type'  VALUE artifact_repository_type
          , 'artifact_group_id'         VALUE artifact_group_id
          , 'artifact_id'               VALUE artifact_id
          , 'artifact_version'          VALUE artifact_version
          , 'artifact_classifier'       VALUE artifact_classifier
          , 'artifact_extension'        VALUE artifact_extension
          , 'package_coordinate'        VALUE package_coordinate
          , 'source_repository_url'     VALUE source_repository_url
          , 'source_commit_hash'        VALUE source_commit_hash
          , 'source_path'               VALUE source_path
          , 'build_id'                  VALUE build_id
          , 'build_url'                 VALUE build_url
          , 'build_time'                VALUE build_time
          , 'build_metadata_json'       VALUE DBMS_LOB.SUBSTR(build_metadata_json, 4000, 1)
          , 'record_ts'                 VALUE TO_CHAR(record_ts, 'YYYY-MM-DD"T"HH24:MI:SS')
          RETURNING CLOB
          )
     INTO l_retvar
     FROM
          (
            SELECT *
              FROM app_deploy_provenance
             WHERE application_name = UPPER(ip_application_name)
               AND (ip_major_version IS NULL OR major_version = ip_major_version)
               AND (ip_minor_version IS NULL OR minor_version = ip_minor_version)
               AND (ip_patch_version IS NULL OR patch_version = ip_patch_version)
             ORDER
                BY deploy_begin DESC
                 , record_ts DESC
          )
    WHERE ROWNUM = 1;

   RETURN l_retvar;
EXCEPTION
   WHEN NO_DATA_FOUND THEN
      RETURN NULL;
END get_deployment_provenance_json_f;



FUNCTION serialize_version_f(ip_version IN VARCHAR)
   RETURN INTEGER
IS
  l_major INTEGER;
  l_minor INTEGER;
  l_patch INTEGER;
BEGIN
   IF ip_version IS NULL THEN
      RETURN NULL;
   END IF
   ;
   assert(REGEXP_LIKE(ip_version, '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'), 'ip_version does not meet criteria for serialization: '||ip_version)
   ;
   l_major := REGEXP_SUBSTR(ip_version,'^(\d+\.)?(\d+\.)?(\*|\d+)$',1,1,null,1);
   l_minor := REGEXP_SUBSTR(ip_version,'^(\d+\.)?(\d+\.)?(\*|\d+)$',1,1,null,2);
   l_patch := REGEXP_SUBSTR(ip_version,'^(\d+\.)?(\d+\.)?(\*|\d+)$',1,1,null,3)
   ;
   assert(l_major BETWEEN 0 AND 9999, 'major version component must be between 0 and 9999: '||l_major)
   ;
   assert(l_minor BETWEEN 0 AND 9999, 'minor version component must be between 0 and 9999: '||l_minor)
   ;
   assert(l_patch BETWEEN 0 AND 9999, 'patch version component must be between 0 and 9999: '||l_patch)
   ;
   RETURN (l_major * 100000000) + (l_minor * 10000) + l_patch;
END serialize_version_f;



FUNCTION deserialize_version_f(ip_serialized_version IN INTEGER)
   RETURN VARCHAR
IS
  l_major_serialized INTEGER;
  l_minor_patch      INTEGER;
  l_major INTEGER;
  l_minor INTEGER;
  l_patch INTEGER;
BEGIN
   IF ip_serialized_version IS NULL THEN
      RETURN NULL;
   END IF;
   l_major_serialized := TRUNC(ip_serialized_version,-8);
   l_major := l_major_serialized/100000000;
   l_minor_patch := ip_serialized_version - l_major_serialized;
   l_minor := TRUNC(l_minor_patch,-4)/10000;
   l_patch := ip_serialized_version - TRUNC(ip_serialized_version,-4)
   ;
   RETURN TO_CHAR(l_major)||'.'||TO_CHAR(l_minor)||'.'||TO_CHAR(l_patch);
END deserialize_version_f;



PROCEDURE check_min_app_version_p( ip_application_name  IN application.application_name%TYPE
                                 , ip_min_major_version IN application.major_version%TYPE DEFAULT 0
                                 , ip_min_minor_version IN application.minor_version%TYPE DEFAULT 0
                                 , ip_min_patch_version IN application.patch_version%TYPE DEFAULT 0
                                 )
IS
   rec_application application%ROWTYPE;
BEGIN
   SELECT *
     INTO rec_application
     FROM application
    WHERE application_name = UPPER(ip_application_name);

--   assert(rec_application.version >= NVL(ip_min_version,0), 'Application version is: '||rec_application.version||'. Minimum required version is: '||ip_min_version);
   assert(rec_application.major_version >= NVL(ip_min_major_version,0), 'Application major_version is: '||rec_application.major_version||'. Minimum required major_version is: '||ip_min_major_version);
   IF rec_application.major_version = ip_min_major_version THEN
      assert(rec_application.minor_version >= NVL(ip_min_minor_version,0), 'Application minor_version is: '||rec_application.minor_version||'. Minimum required minor_version is: '||ip_min_minor_version);
      IF rec_application.minor_version = ip_min_minor_version THEN
         assert(rec_application.patch_version >= NVL(ip_min_patch_version,0), 'Application patch_version is: '||rec_application.patch_version||'. Minimum required patch_version is: '||ip_min_patch_version);
     END IF;
   END IF;
END check_min_app_version_p;



PROCEDURE check_already_deployed_p( ip_application_name  IN application.application_name%TYPE
                                  , ip_min_major_version IN application.major_version%TYPE DEFAULT 0
                                  , ip_min_minor_version IN application.minor_version%TYPE DEFAULT 0
                                  , ip_min_patch_version IN application.patch_version%TYPE DEFAULT 0 )
IS
   rec_application application%ROWTYPE;
BEGIN
   SELECT *
     INTO rec_application
     FROM application
    WHERE application_name = UPPER(ip_application_name);

   assert(rec_application.major_version <= NVL(ip_min_major_version,0), 'It appears major_version '||ip_min_major_version||' has already been deployed; application major_version is: '||rec_application.major_version);
   IF rec_application.major_version = ip_min_major_version THEN
      assert(rec_application.minor_version <= NVL(ip_min_minor_version,0), 'It appears minor_version '||ip_min_minor_version||' has already been deployed; application minor_version is: '||rec_application.minor_version);
      IF rec_application.minor_version = ip_min_minor_version THEN
         assert(rec_application.patch_version <  NVL(ip_min_minor_version,0), 'It appears patch_version '||ip_min_patch_version||' has already been deployed; application patch_version is: '||rec_application.patch_version);
      END IF;
   END IF;
END check_already_deployed_p;



PROCEDURE begin_deployment_p( ip_application_name   IN application.application_name%TYPE
                            , ip_major_version      IN application.major_version%TYPE
                            , ip_minor_version      IN application.minor_version%TYPE
                            , ip_patch_version      IN application.patch_version%TYPE
                            , ip_deployment_type    IN application.deploy_type%TYPE DEFAULT c_deploy_type_initial
                            , ip_deploy_commit_hash IN application.deploy_commit_hash%TYPE DEFAULT c_deploy_commit_hash_unknown
                            , ip_redeploy_okay      IN BOOLEAN DEFAULT FALSE
                            , ip_notes              IN app_deploy_notes.notes%TYPE DEFAULT NULL
                            )
IS
   rec_application         application%ROWTYPE;
   l_exists                BOOLEAN := FALSE;
   l_restart_failed_deploy BOOLEAN := FALSE;
   l_redeploy_curr_ver     BOOLEAN := FALSE;
BEGIN
   assert(ip_application_name = UPPER(ip_application_name));
   
   CASE ip_deployment_type
   WHEN c_deploy_type_initial THEN
      BEGIN
         get_application_rec_p( ip_application_name => ip_application_name
                              , op_rec_application  => rec_application );
         l_exists := TRUE;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            l_exists := FALSE;
      END;
      
      IF l_exists = FALSE THEN
         INSERT 
           INTO application 
              ( application_name, major_version , minor_version, patch_version, deploy_commit_hash )
         VALUES 
              ( ip_application_name, ip_major_version, ip_minor_version, ip_patch_version, ip_deploy_commit_hash );

         get_application_rec_p( ip_application_name => ip_application_name
                              , op_rec_application  => rec_application );
      ELSE
         assert(rec_application.deploy_status != c_deploy_status_complete, 'Initial application deployment already marked complete');
         assert(rec_application.deploy_status IN (c_deploy_status_running, c_deploy_status_fail), 'Application record exists; deploy_status must be one of: '||c_deploy_status_running||','||c_deploy_status_fail||'; found: '||rec_application.deploy_status);

         assert(    ip_major_version = rec_application.major_version 
               AND ip_minor_version = rec_application.minor_version 
               AND ip_patch_version = rec_application.patch_version 
               , 'Application record exists; version must match: '
               ||rec_application.major_version||'.'||rec_application.minor_version||'.'||rec_application.patch_version);

         assert(rec_application.deploy_type = c_deploy_type_initial, 'Application record exists; deploy_type must be c_deploy_type_initial');
      
         IF rec_application.deploy_status = c_deploy_status_fail THEN
            UPDATE application
               SET deploy_status = c_deploy_status_running
                 , deploy_commit_hash = ip_deploy_commit_hash
                 , deploy_begin = SYSDATE;
         END IF;
      END IF;
   ELSE --not initial deploy 
      get_application_rec_p( ip_application_name => ip_application_name
                           , op_rec_application  => rec_application );

      IF rec_application.deploy_status IN (c_deploy_status_running, c_deploy_status_fail) THEN
         assert(    ip_major_version = rec_application.major_version 
                AND ip_minor_version = rec_application.minor_version 
                AND ip_patch_version = rec_application.patch_version 
               , 'deployment already in-progress; version must equal in-flight deployment version: '
               ||rec_application.major_version||'.'||rec_application.minor_version||'.'||rec_application.patch_version);
         l_restart_failed_deploy := TRUE;
      ELSIF ip_major_version = rec_application.major_version 
        AND ip_minor_version = rec_application.minor_version 
        AND ip_patch_version = rec_application.patch_version 
      THEN
         l_redeploy_curr_ver := TRUE;
      END IF;

      CASE WHEN l_redeploy_curr_ver = TRUE
      THEN 
         NULL; --bypass the rest of the version checks
      WHEN ip_deployment_type = c_deploy_type_major THEN
         IF     l_restart_failed_deploy = FALSE THEN
            assert( ip_major_version > rec_application.major_version 
                  , 'major version must be greater than deployed major version; deployed version is: '
                  ||rec_application.major_version||'.'||rec_application.minor_version||'.'||rec_application.patch_version);
         END IF;
      WHEN ip_deployment_type = c_deploy_type_minor THEN
         IF     l_restart_failed_deploy = FALSE THEN
            assert(    ip_major_version = rec_application.major_version 
                  , 'Major version must match that already deployed; deployed version is: '
                  ||rec_application.major_version||'.'||rec_application.minor_version||'.'||rec_application.patch_version);

            assert( ip_minor_version > rec_application.minor_version 
                  , 'minor version must be greater than deployed minor version; deployed version is: '
                  ||rec_application.major_version||'.'||rec_application.minor_version||'.'||rec_application.patch_version);
         END IF;
      WHEN ip_deployment_type = c_deploy_type_patch THEN
         IF l_restart_failed_deploy = FALSE THEN
            assert(    ip_major_version = rec_application.major_version 
                   AND ip_minor_version = rec_application.minor_version
                  , 'Major and Minor version must match those already deployed; deployed version is: '
                  ||rec_application.major_version||'.'||rec_application.minor_version||'.'||rec_application.patch_version);

            assert( ip_patch_version > rec_application.patch_version 
                  , 'patch version must be greater than deployed patch version; deployed version is: '
                  ||rec_application.major_version||'.'||rec_application.minor_version||'.'||rec_application.patch_version);
         END IF;
      ELSE
         assert(FALSE, 'logic error: ip_deployment_type = '||ip_deployment_type);
      END CASE;
      
      UPDATE application
         SET major_version = ip_major_version
           , minor_version = ip_minor_version
           , patch_version = ip_patch_version
           , deploy_type = ip_deployment_type
           , deploy_status = c_deploy_status_running
           , deploy_commit_hash = ip_deploy_commit_hash
           , deploy_begin = SYSDATE
           , deploy_end = NULL
       WHERE application_name = ip_application_name;
   END CASE;

   IF ip_deployment_type != c_deploy_type_initial
      OR l_exists = TRUE
   THEN
      arch_application_rec_P( ip_rec_application => rec_application );
   END IF;

   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );

   consume_pending_deploy_provenance_p( ip_rec_application => rec_application );

   COMMIT;
   
   IF ip_notes IS NOT NULL THEN
      set_deploy_notes_p( ip_application_name => ip_application_name
                        , ip_notes => ip_notes );
   END IF;
END begin_deployment_p;



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
                           )
IS
BEGIN
   assert(ip_application_name = UPPER(ip_application_name));

   DELETE
     FROM app_deploy_provenance_pending
    WHERE application_name = ip_application_name
      AND major_version = ip_major_version
      AND minor_version = ip_minor_version
      AND patch_version = ip_patch_version
      AND deploy_type = ip_deployment_type
      AND deploy_commit_hash = ip_deploy_commit_hash;

   INSERT
     INTO app_deploy_provenance_pending
        ( application_name
        , major_version
        , minor_version
        , patch_version
        , deploy_type
        , deploy_commit_hash
        , artifact_uri
        , artifact_checksum
        , artifact_checksum_alg
        , artifact_file_name
        , artifact_repository_type
        , artifact_group_id
        , artifact_id
        , artifact_version
        , artifact_classifier
        , artifact_extension
        , package_coordinate
        , source_repository_url
        , source_commit_hash
        , source_path
        , build_id
        , build_url
        , build_time
        , build_metadata_json
        )
   VALUES
        ( ip_application_name
        , ip_major_version
        , ip_minor_version
        , ip_patch_version
        , ip_deployment_type
        , ip_deploy_commit_hash
        , ip_artifact_uri
        , ip_artifact_checksum
        , ip_artifact_checksum_alg
        , ip_artifact_file_name
        , ip_artifact_repository_type
        , ip_artifact_group_id
        , ip_artifact_id
        , ip_artifact_version
        , ip_artifact_classifier
        , ip_artifact_extension
        , ip_package_coordinate
        , ip_source_repository_url
        , NVL(ip_source_commit_hash, ip_deploy_commit_hash)
        , ip_source_path
        , ip_build_id
        , ip_build_url
        , ip_build_time
        , ip_build_metadata_json
        );

   COMMIT;
END stage_deployment_provenance_p;



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
                           )
IS
   rec_application application%ROWTYPE;
BEGIN
   begin_deployment_p
      ( ip_application_name   => ip_application_name
      , ip_major_version      => ip_major_version
      , ip_minor_version      => ip_minor_version
      , ip_patch_version      => ip_patch_version
      , ip_deployment_type    => ip_deployment_type
      , ip_deploy_commit_hash => ip_deploy_commit_hash
      , ip_redeploy_okay      => ip_redeploy_okay
      , ip_notes              => ip_notes
      );

   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );

   record_deploy_provenance_p
      ( ip_rec_application          => rec_application
      , ip_artifact_uri             => ip_artifact_uri
      , ip_artifact_checksum        => ip_artifact_checksum
      , ip_artifact_checksum_alg    => ip_artifact_checksum_alg
      , ip_artifact_file_name       => ip_artifact_file_name
      , ip_artifact_repository_type => ip_artifact_repository_type
      , ip_artifact_group_id        => ip_artifact_group_id
      , ip_artifact_id              => ip_artifact_id
      , ip_artifact_version         => ip_artifact_version
      , ip_artifact_classifier      => ip_artifact_classifier
      , ip_artifact_extension       => ip_artifact_extension
      , ip_package_coordinate       => ip_package_coordinate
      , ip_source_repository_url    => ip_source_repository_url
      , ip_source_commit_hash       => ip_source_commit_hash
      , ip_source_path              => ip_source_path
      , ip_build_id                 => ip_build_id
      , ip_build_url                => ip_build_url
      , ip_build_time               => ip_build_time
      , ip_build_metadata_json      => ip_build_metadata_json
      );

   COMMIT;
END begin_artifact_deployment_p;



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
                           )
IS
   rec_application application%ROWTYPE;
   l_deploy_count  NUMBER;
BEGIN
   assert(ip_application_name = UPPER(ip_application_name));

   SELECT COUNT(*)
     INTO l_deploy_count
     FROM
        (
          SELECT application_name
            FROM application
           WHERE application_name = ip_application_name
             AND major_version = ip_major_version
             AND minor_version = ip_minor_version
             AND patch_version = ip_patch_version
             AND deploy_type = ip_deployment_type
             AND deploy_commit_hash = ip_deploy_commit_hash
             AND deploy_status = c_deploy_status_complete
          UNION ALL
          SELECT application_name
            FROM app_deploy_hist
           WHERE application_name = ip_application_name
             AND major_version = ip_major_version
             AND minor_version = ip_minor_version
             AND patch_version = ip_patch_version
             AND deploy_type = ip_deployment_type
             AND deploy_commit_hash = ip_deploy_commit_hash
             AND deploy_status = c_deploy_status_complete
        );

   assert(l_deploy_count > 0, 'No completed deployment found for '
                              ||ip_application_name||' '
                              ||ip_major_version||'.'
                              ||ip_minor_version||'.'
                              ||ip_patch_version
                              ||' commit '||ip_deploy_commit_hash);

   assert(l_deploy_count = 1, 'Multiple completed deployments found for '
                              ||ip_application_name||' '
                              ||ip_major_version||'.'
                              ||ip_minor_version||'.'
                              ||ip_patch_version
                              ||' commit '||ip_deploy_commit_hash
                              ||'; provenance backfill is ambiguous');

   SELECT application_name
        , major_version
        , minor_version
        , patch_version
        , pre_release
        , build
        , deploy_type
        , deploy_status
        , deploy_commit_hash
        , deploy_begin
        , deploy_end
     INTO rec_application
     FROM
        (
          SELECT application_name
               , major_version
               , minor_version
               , patch_version
               , pre_release
               , build
               , deploy_type
               , deploy_status
               , deploy_commit_hash
               , deploy_begin
               , deploy_end
            FROM application
           WHERE application_name = ip_application_name
             AND major_version = ip_major_version
             AND minor_version = ip_minor_version
             AND patch_version = ip_patch_version
             AND deploy_type = ip_deployment_type
             AND deploy_commit_hash = ip_deploy_commit_hash
             AND deploy_status = c_deploy_status_complete
          UNION ALL
          SELECT application_name
               , major_version
               , minor_version
               , patch_version
               , pre_release
               , build
               , deploy_type
               , deploy_status
               , deploy_commit_hash
               , deploy_begin
               , deploy_end
            FROM app_deploy_hist
           WHERE application_name = ip_application_name
             AND major_version = ip_major_version
             AND minor_version = ip_minor_version
             AND patch_version = ip_patch_version
             AND deploy_type = ip_deployment_type
             AND deploy_commit_hash = ip_deploy_commit_hash
             AND deploy_status = c_deploy_status_complete
        );

   record_deploy_provenance_p
      ( ip_rec_application          => rec_application
      , ip_artifact_uri             => ip_artifact_uri
      , ip_artifact_checksum        => ip_artifact_checksum
      , ip_artifact_checksum_alg    => ip_artifact_checksum_alg
      , ip_artifact_file_name       => ip_artifact_file_name
      , ip_artifact_repository_type => ip_artifact_repository_type
      , ip_artifact_group_id        => ip_artifact_group_id
      , ip_artifact_id              => ip_artifact_id
      , ip_artifact_version         => ip_artifact_version
      , ip_artifact_classifier      => ip_artifact_classifier
      , ip_artifact_extension       => ip_artifact_extension
      , ip_package_coordinate       => ip_package_coordinate
      , ip_source_repository_url    => ip_source_repository_url
      , ip_source_commit_hash       => ip_source_commit_hash
      , ip_source_path              => ip_source_path
      , ip_build_id                 => ip_build_id
      , ip_build_url                => ip_build_url
      , ip_build_time               => ip_build_time
      , ip_build_metadata_json      => ip_build_metadata_json
      , ip_replace_existing         => FALSE
      );

   COMMIT;
END record_deployment_provenance_p;



PROCEDURE set_deploy_notes_p( ip_application_name IN application.application_name%TYPE
                            , ip_notes            IN app_deploy_notes.notes%TYPE)
IS
   rec_application   application%ROWTYPE;
BEGIN
   assert(ip_application_name = UPPER(ip_application_name));
   
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );

   assert(rec_application.deploy_status IN (c_deploy_status_running), 'Deploy status must be "'||c_deploy_status_running||'" in order to set deploy notes');

   DELETE 
     FROM app_deploy_notes
    WHERE application_name = ip_application_name
      AND major_version = rec_application.major_version
      AND minor_version = rec_application.minor_version
      AND patch_version = rec_application.patch_version
   ;
   INSERT 
     INTO app_deploy_notes
        ( application_name
        , major_version
        , minor_version
        , patch_version
        , note_ts
        , notes
        )
   VALUES
        ( ip_application_name
        , rec_application.major_version
        , rec_application.minor_version
        , rec_application.patch_version
        , SYSDATE
        , ip_notes
        )
   ;
   COMMIT;
END set_deploy_notes_p;



PROCEDURE end_deployment_p( ip_application_name IN application.application_name%TYPE
                          , ip_status           IN application.deploy_status%TYPE
                          )
IS
   rec_application   application%ROWTYPE;
BEGIN
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );

   assert(ip_status IN (c_deploy_status_complete, c_deploy_status_fail), 'Bad value for ip_status: '||ip_status);
   assert(rec_application.deploy_status != c_deploy_status_complete, 'Deploy status is already Complete');
   assert(rec_application.deploy_status IN (c_deploy_status_running, c_deploy_status_fail), 'Deploy status must be "'||c_deploy_status_running||'" or "'||c_deploy_status_fail||'"');
   
   UPDATE application
      SET deploy_status = ip_status
        , deploy_end = SYSDATE
    WHERE application_name = ip_application_name;
    
   COMMIT;
END end_deployment_p;



PROCEDURE set_deployment_complete_p( ip_application_name IN application.application_name%TYPE)
IS
BEGIN
   end_deployment_p( ip_application_name => ip_application_name
                   , ip_status           => c_deploy_status_complete );
END set_deployment_complete_p;



PROCEDURE set_deployment_fail_p( ip_application_name IN application.application_name%TYPE)
IS
BEGIN
   end_deployment_p( ip_application_name => ip_application_name
                   , ip_status           => c_deploy_status_fail );
END set_deployment_fail_p;



PROCEDURE add_dependency_p( ip_application_name IN application.application_name%TYPE
                          , ip_depends_on       IN app_dependency.depends_on%TYPE
                          , ip_version_min      IN app_dependency.version_min%TYPE DEFAULT c_version_min_any
                          , ip_version_max      IN app_dependency.version_max%TYPE DEFAULT c_version_max_any
                          )
IS
   rec_application application%ROWTYPE;
BEGIN
   assert(ip_depends_on = UPPER(ip_depends_on), 'ip_depends_on should be all upper case');
   
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );
   
   DELETE 
     FROM app_dependency 
    WHERE application_name = ip_application_name
      AND depends_on = ip_depends_on;
      
   INSERT
     INTO app_dependency
        ( application_name
        , depends_on
        , version_min
        , version_max )
   VALUES 
        ( ip_application_name
        , ip_depends_on
        , ip_version_min
        , ip_version_max );
     
   COMMIT;
END add_dependency_p;



PROCEDURE validate_dependencies_p( ip_application_name IN application.application_name%TYPE)
IS
   rec_application   application%ROWTYPE;
   l_not_valid_cnt   NUMBER;
   l_not_valid_lst   VARCHAR2(4000);
BEGIN
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );

   UPDATE app_dependency
      SET is_valid         = CASE ( SELECT COUNT(*) 
                                      FROM application 
                                     WHERE application.application_name = app_dependency.depends_on
                                       AND serialize_version_f(application.major_version||'.'||application.minor_version||'.'||application.patch_version) BETWEEN app_dependency.version_min
                                                                                                                                                             AND app_dependency.version_max
                                  ) WHEN 0 THEN c_valid_no ELSE c_valid_yes END
        , last_validated   = SYSDATE
    WHERE application_name = ip_application_name;
   
   COMMIT;

   SELECT COUNT(*)
        , LISTAGG(depends_on, ', ') WITHIN GROUP (ORDER BY depends_on)
     INTO l_not_valid_cnt
        , l_not_valid_lst
     FROM app_dependency
    WHERE application_name = ip_application_name
      AND is_valid != c_valid_yes;
   
   assert(l_not_valid_cnt = 0, 'Dependency check failed for the following: '||l_not_valid_lst);
END validate_dependencies_p;



PROCEDURE add_sys_priv_p( ip_application_name IN application.application_name%TYPE
                        , ip_privilege        IN app_sys_privs.privilege%TYPE)
IS
   rec_application application%ROWTYPE;
BEGIN
   assert(ip_privilege = UPPER(ip_privilege), 'ip_privilege should be all upper case');
   
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );
   
   DELETE 
     FROM app_sys_privs 
    WHERE application_name = ip_application_name
      AND privilege = ip_privilege;
      
   INSERT
     INTO app_sys_privs
        ( application_name
        , privilege )
   VALUES 
        ( ip_application_name
        , ip_privilege );
     
   COMMIT;

END add_sys_priv_p;



PROCEDURE validate_sys_privs_p( ip_application_name IN application.application_name%TYPE)
IS
   rec_application   application%ROWTYPE;
   l_not_valid_cnt   NUMBER;
   l_not_valid_lst   VARCHAR2(4000);
BEGIN
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );

   UPDATE app_sys_privs
      SET is_valid         = CASE ( SELECT COUNT(*) 
                                      FROM user_sys_privs 
                                     WHERE user_sys_privs.privilege = app_sys_privs.privilege
                                  ) WHEN 0 THEN c_valid_no ELSE c_valid_yes END
        , last_validated   = SYSDATE
    WHERE application_name = ip_application_name;
   
   COMMIT;

   SELECT COUNT(*)
        , LISTAGG(privilege, ', ') WITHIN GROUP (ORDER BY privilege)
     INTO l_not_valid_cnt
        , l_not_valid_lst
     FROM app_sys_privs
    WHERE application_name = ip_application_name
      AND is_valid != c_valid_yes;
   
   assert(l_not_valid_cnt = 0, 'System-Privilege check failed for the following: '||l_not_valid_lst);
END validate_sys_privs_p;



PROCEDURE add_obj_priv_p( ip_application_name IN application.application_name%TYPE
                        , ip_owner            IN app_obj_privs.owner%TYPE
                        , ip_type             IN app_obj_privs.type%TYPE
                        , ip_name             IN app_obj_privs.name%TYPE
                        , ip_privilege        IN app_obj_privs.privilege%TYPE)
IS
   rec_application application%ROWTYPE;
BEGIN
   assert(ip_owner = UPPER(ip_owner), 'ip_owner should be all upper case');
   assert(ip_type = UPPER(ip_type), 'ip_type should be all upper case');
   assert(ip_name = UPPER(ip_name), 'ip_name should be all upper case');
   assert(ip_privilege = UPPER(ip_privilege), 'ip_privilege should be all upper case');
   
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );
   
   DELETE 
     FROM app_obj_privs 
    WHERE application_name = ip_application_name
      AND owner = ip_owner
      AND type = ip_type
      AND name = ip_name
      AND privilege = ip_privilege;
      
   INSERT
     INTO app_obj_privs
        ( application_name
        , owner
        , type
        , name
        , privilege )
   VALUES 
        ( ip_application_name
        , ip_owner
        , ip_type
        , ip_name
        , ip_privilege );
     
   COMMIT;

END add_obj_priv_p;



PROCEDURE validate_obj_privs_p( ip_application_name IN application.application_name%TYPE)
IS
   rec_application   application%ROWTYPE;
   l_not_valid_cnt   NUMBER;
   l_not_valid_lst   VARCHAR2(4000);
BEGIN
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );

   UPDATE app_obj_privs
      SET is_valid         = CASE ( SELECT COUNT(*) 
                                      FROM user_tab_privs 
                                     WHERE user_tab_privs.owner = app_obj_privs.owner
                                       --AND user_tab_privs.type = app_obj_privs.type                 --everything here shares the same namespace
                                       AND user_tab_privs.table_name = app_obj_privs.name
                                       AND user_tab_privs.privilege = app_obj_privs.privilege
                                  ) WHEN 0 THEN c_valid_no ELSE c_valid_yes END
        , last_validated   = SYSDATE
    WHERE application_name = ip_application_name;
   
   COMMIT;

   SELECT COUNT(*)
        , LISTAGG(privilege||' on '||name, ', ') WITHIN GROUP (ORDER BY privilege, name)
     INTO l_not_valid_cnt
        , l_not_valid_lst
     FROM app_obj_privs
    WHERE application_name = ip_application_name
      AND is_valid != c_valid_yes;
   
   assert(l_not_valid_cnt = 0, 'Object-Privilege check failed for the following: '||l_not_valid_lst);
END validate_obj_privs_p;



PROCEDURE add_object_p( ip_application_name IN application.application_name%TYPE
                      , ip_object_name      IN app_objects.object_name%TYPE
                      , ip_object_type      IN app_object_type.object_type%TYPE DEFAULT c_object_type_table
                      )
IS
   rec_application      application%ROWTYPE;
   rec_app_object_type  app_object_type%ROWTYPE;
BEGIN
   assert(ip_object_name = UPPER(ip_object_name), 'ip_object_name should be all upper case');
   assert(ip_object_type = UPPER(ip_object_type), 'ip_object_type should be all upper case');

   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );

   assert(rec_application.deploy_status NOT IN (c_deploy_status_complete), 'Application deployment status is not in progress: '||ip_application_name);

   get_object_type_p( ip_object_type     => ip_object_type
                    , op_rec_object_type => rec_app_object_type );

   DELETE 
     FROM app_objects 
    WHERE application_name = ip_application_name
      AND object_name = ip_object_name
      AND object_type = ip_object_type;

   BEGIN
      INSERT
        INTO app_objects 
           ( application_name
           , object_type
           , object_namespace
           , object_name
           , major_version
           , minor_version
           )
      VALUES 
           ( ip_application_name
           , rec_app_object_type.object_type
           , rec_app_object_type.object_namespace
           , ip_object_name
           , rec_application.major_version
           , rec_application.minor_version
           );
   EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN 
         ROLLBACK;
         assert(FALSE, 'An object with the same name and object-namespace already exists in app_objects.');
   END;
        
   COMMIT;
END add_object_p;



PROCEDURE add_object_metadata_p( ip_application_name  IN application.application_name%TYPE
                               , ip_object_name       IN app_objects.object_name%TYPE
                               , ip_object_type       IN app_object_type.object_type%TYPE DEFAULT c_object_type_table
                               , ip_discriminator_col IN app_object_metadata.discriminator_col%TYPE DEFAULT 'NONE'
                               , ip_discriminator_val IN app_object_metadata.discriminator_val%TYPE DEFAULT 'NONE'
                               , ip_version           IN app_object_metadata.version%TYPE DEFAULT NULL
                               , ip_dml_override_proc IN app_object_metadata.dml_override_proc%TYPE DEFAULT NULL
                               )
IS
   rec_application         application%ROWTYPE;
   rec_app_object_type     app_object_type%ROWTYPE;
   rec_app_object          app_objects%ROWTYPE;
   rec_app_object_metadata app_object_metadata%ROWTYPE;
BEGIN
   assert(ip_object_name = UPPER(ip_object_name), 'ip_object_name should be all upper case');
   assert(ip_object_type = UPPER(ip_object_type), 'ip_object_type should be all upper case');
   assert(ip_discriminator_col = UPPER(ip_discriminator_col), 'ip_discriminator_col should be all upper case');
   assert(ip_object_type = 'TABLE', 'add_object_metadata_p is only supported for object_type "TABLE"');
   get_object_type_p( ip_object_type     => ip_object_type
                    , op_rec_object_type => rec_app_object_type )
   ;
   get_object_p( ip_object_name          => ip_object_name
               , ip_object_namespace     => rec_app_object_type.object_namespace
               , op_rec_object           => rec_app_object )
   ;
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application )
   ;
   rec_app_object_metadata := t_app_object_metadata
      ( object_name         => ip_object_name
      , object_namespace    => rec_app_object.object_namespace
      , object_type         => ip_object_type
      , application_name    => rec_application.application_name
      , discriminator_col   => ip_discriminator_col
      , discriminator_val   => ip_discriminator_val
      , last_update         => SYSDATE
      , version             => ip_version
      , dml_override_proc   => ip_dml_override_proc
      );
   
   MERGE INTO APP_OBJECT_METADATA t
      USING (SELECT NULL FROM dual)
        ON (    t.object_name              = rec_app_object_metadata.object_name
            AND t.object_namespace         = rec_app_object_metadata.object_namespace
            AND t.discriminator_col        = rec_app_object_metadata.discriminator_col
            AND t.discriminator_val        = rec_app_object_metadata.discriminator_val
           )
      WHEN MATCHED
      THEN
         UPDATE SET
           t.last_update                 = rec_app_object_metadata.last_update      
         , t.version                     = rec_app_object_metadata.version          
         , t.dml_override_proc           = rec_app_object_metadata.dml_override_proc
      WHEN NOT MATCHED
      THEN
         INSERT VALUES rec_app_object_metadata;

   COMMIT;
END add_object_metadata_p;



PROCEDURE delete_object_metadata_p( ip_application_name  IN application.application_name%TYPE
                                  , ip_object_name       IN app_objects.object_name%TYPE
                                  , ip_object_type       IN app_object_type.object_type%TYPE DEFAULT c_object_type_table
                                  , ip_discriminator_col IN app_object_metadata.discriminator_col%TYPE
                                  , ip_discriminator_val IN app_object_metadata.discriminator_val%TYPE
                                  )
IS
   rec_application         application%ROWTYPE;
   rec_app_object_type     app_object_type%ROWTYPE;
   rec_app_object          app_objects%ROWTYPE;
   rec_app_object_metadata app_object_metadata%ROWTYPE;
BEGIN
   assert(ip_object_name = UPPER(ip_object_name), 'ip_object_name should be all upper case');
   assert(ip_object_type = UPPER(ip_object_type), 'ip_object_type should be all upper case');
   assert(ip_discriminator_col = UPPER(ip_discriminator_col), 'ip_discriminator_col should be all upper case');

   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application )
   ;
   get_object_type_p( ip_object_type     => ip_object_type
                    , op_rec_object_type => rec_app_object_type );

   get_object_p( ip_object_name          => ip_object_name
               , ip_object_namespace     => rec_app_object_type.object_namespace
               , op_rec_object           => rec_app_object );
   SELECT *
     INTO rec_app_object_metadata
    FROM app_object_metadata
   WHERE object_name = ip_object_name
     AND object_namespace = rec_app_object.object_namespace
     AND discriminator_col = ip_discriminator_col
     AND discriminator_val = ip_discriminator_val
   ;
   assert(rec_application.application_name = rec_app_object_metadata.application_name, 'ip_application_name does not match application associated with metadata record')
   ;
   IF rec_app_object_metadata.dml_override_proc IS NULL THEN
      assert(rec_app_object_metadata.discriminator_col != 'NONE', 'Do not call this procedure for discriminator values of "NONE" unless dml_override_proc is populated')
      ;
      EXECUTE IMMEDIATE 'DELETE FROM '||ip_object_name
        ||' WHERE '||rec_app_object_metadata.discriminator_col||' = :discriminator_val' USING rec_app_object_metadata.discriminator_val;
   ELSE
      EXECUTE IMMEDIATE 'BEGIN '||rec_app_object_metadata.dml_override_proc||'; END;';
   END IF;

   DELETE 
     FROM app_object_metadata
   WHERE object_name       = rec_app_object_metadata.object_name
     AND object_type       = rec_app_object_metadata.object_type
     AND discriminator_col = rec_app_object_metadata.discriminator_col
     AND discriminator_val = rec_app_object_metadata.discriminator_val
   ;
   COMMIT;
END delete_object_metadata_p;



PROCEDURE validate_objects_p( ip_application_name IN application.application_name%TYPE)
IS
   rec_application   application%ROWTYPE;
   l_not_valid_cnt   NUMBER;
   l_not_valid_lst   VARCHAR2(4000);
BEGIN
   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application );

   UPDATE app_objects
      SET is_valid         = CASE ( SELECT COUNT(*) 
                                      FROM user_objects 
                                     WHERE object_name = app_objects.object_name
                                       AND object_type = app_objects.object_type
                                  ) WHEN 0 THEN c_valid_no ELSE c_valid_yes END
        , last_validated   = SYSDATE
    WHERE application_name = ip_application_name;
   
   COMMIT;

   SELECT COUNT(*)
        , LISTAGG(object_name, ', ') WITHIN GROUP (ORDER BY object_name)
     INTO l_not_valid_cnt
        , l_not_valid_lst
     FROM app_objects
    WHERE application_name = ip_application_name
      AND is_valid != c_valid_yes;
   
   assert(l_not_valid_cnt = 0, 'Object check failed for the following: '||l_not_valid_lst);
END validate_objects_p;



PROCEDURE drop_object_p( ip_object_type IN app_objects.object_type%TYPE
                       , ip_object_name IN app_objects.object_name%TYPE )
IS
   table_does_not_exist EXCEPTION;
   PRAGMA EXCEPTION_INIT(table_does_not_exist, -942);
   sequence_does_not_exist EXCEPTION;
   PRAGMA EXCEPTION_INIT(sequence_does_not_exist, -2289);
   object_does_not_exist EXCEPTION;
   PRAGMA EXCEPTION_INIT(object_does_not_exist, -4043);
   db_link_does_not_exist EXCEPTION;
   PRAGMA EXCEPTION_INIT(db_link_does_not_exist, -2024);
   synonym_does_not_exist EXCEPTION;
   PRAGMA EXCEPTION_INIT(synonym_does_not_exist, -1434);
   --
   l_stmt VARCHAR2(4000);
BEGIN
   CASE ip_object_type
   WHEN c_object_type_table        THEN
      l_stmt := 'DROP TABLE "'||ip_object_name||'" CASCADE CONSTRAINTS PURGE';
   WHEN c_object_type_sequence     THEN
         l_stmt := 'DROP SEQUENCE "'||ip_object_name||'"';
   WHEN c_object_type_type_body    THEN
         l_stmt := 'DROP TYPE BODY "'||ip_object_name||'"';
   WHEN c_object_type_type         THEN
         l_stmt := 'DROP TYPE "'||ip_object_name||'"';
   WHEN c_object_type_procedure     THEN
         l_stmt := 'DROP PROCEDURE "'||ip_object_name||'"';
   WHEN c_object_type_function     THEN
         l_stmt := 'DROP FUNCTION "'||ip_object_name||'"';
   WHEN c_object_type_package      THEN
         l_stmt := 'DROP PACKAGE "'||ip_object_name||'"';
   WHEN c_object_type_package_body THEN
         l_stmt := 'DROP PACKAGE BODY "'||ip_object_name||'"';
   WHEN c_object_type_view         THEN
         l_stmt := 'DROP VIEW "'||ip_object_name||'"';
   WHEN c_object_type_materialized_view         THEN
         l_stmt := 'DROP MATERIALIZED VIEW "'||ip_object_name||'"';
   WHEN c_object_type_db_link      THEN
         l_stmt := 'DROP DATABASE LINK "'||ip_object_name||'"';
   WHEN c_object_type_synonym      THEN
         l_stmt := 'DROP SYNONYM "'||ip_object_name||'"';
   ELSE
      assert(FALSE, ip_object_type||' not yet supported. ');
   END CASE;
   
   EXECUTE IMMEDIATE l_stmt;
   
EXCEPTION
   WHEN table_does_not_exist THEN
      NULL; --IGNORE IF THE TABLE HAS ALREADY BEEN DROPPED
   WHEN sequence_does_not_exist THEN
      NULL; --IGNORE IF THE SEQUENCE HAS ALREADY BEEN DROPPED
   WHEN object_does_not_exist THEN
      NULL; --IGNORE IF THE TYPE/TYPE BODY/FUNCTION HAS ALREADY BEEN DROPPED
   WHEN db_link_does_not_exist THEN
      NULL; --IGNORE IF THE DATABASE LINK HAS ALREADY BEEN DROPPED
   WHEN synonym_does_not_exist THEN
      NULL; --IGNORE IF THE SYNONYM HAS ALREADY BEEN DROPPED
   WHEN OTHERS THEN
      assert(FALSE,'***'||l_stmt||'*** failed with:'||SQLERRM);
END drop_object_p;



PROCEDURE forget_object_p( ip_object_type IN app_objects.object_type%TYPE
                         , ip_object_name IN app_objects.object_name%TYPE )
IS
   rec_app_object_type app_object_type%ROWTYPE;
BEGIN
   SELECT *
     INTO rec_app_object_type
     FROM app_object_type
    WHERE object_type = UPPER(ip_object_type);

   DELETE 
     FROM app_objects 
    WHERE object_name = ip_object_name
      AND object_namespace = rec_app_object_type.object_namespace;

   COMMIT;
END forget_object_p;



PROCEDURE drop_and_forget_object_p( ip_object_type IN app_objects.object_type%TYPE
                                  , ip_object_name IN app_objects.object_name%TYPE )
IS
   rec_app_object_type app_object_type%ROWTYPE;
BEGIN
   drop_object_p( ip_object_type, ip_object_name);
   forget_object_p( ip_object_type, ip_object_name);
END drop_and_forget_object_p;



PROCEDURE change_object_application_p( ip_object_name           IN app_objects.object_name%TYPE
                                     , ip_new_application_name  IN application.application_name%TYPE
                                     , ip_object_type           IN app_object_type.object_type%TYPE DEFAULT c_object_type_table
                                     , ip_old_application_name  IN application.application_name%TYPE DEFAULT NULL )
IS
   rec_app_object_type  app_object_type%ROWTYPE;
BEGIN
   get_object_type_p( ip_object_type     => ip_object_type
                    , op_rec_object_type => rec_app_object_type );

   UPDATE app_objects
      SET application_name = ip_new_application_name
    WHERE object_namespace = rec_app_object_type.object_namespace
      AND object_name = ip_object_name
      AND application_name = NVL(ip_old_application_name, application_name)
      AND application_name != ip_new_application_name
   ;
   assert(SQL%ROWCOUNT = 1, SQL%ROWCOUNT||' records modified. Expecting 1.')
   ;
END change_object_application_p;



PROCEDURE delete_application_p( ip_application_name  IN application.application_name%TYPE
                              , ip_fail_on_not_found IN VARCHAR2 DEFAULT 'Y' )
IS
   l_dependent_app_cnt  NUMBER;
   l_dependent_app_lst  VARCHAR2(4000);
   rec_application      application%ROWTYPE;
BEGIN
   assert(ip_fail_on_not_found IN ('Y','N'), 'ip_fail_on_not_found must be "Y" or "N"; found: '||ip_fail_on_not_found);

   get_application_rec_p( ip_application_name => ip_application_name
                        , op_rec_application  => rec_application
                        , ip_fail_on_not_found => ip_fail_on_not_found );

   IF rec_application.application_name IS NULL THEN
      GOTO end_now;
   END IF;
   
   assert(ip_application_name != 'CORE', 'All applications depend on CORE; drop everything in the schema and re-deploy. :)');

   SELECT COUNT(*)
        , LISTAGG(application_name, ', ') WITHIN GROUP (ORDER BY application_name)
     INTO l_dependent_app_cnt
        , l_dependent_app_lst
     FROM app_dependency
    WHERE depends_on = ip_application_name;
   
   assert(l_dependent_app_cnt = 0, 'Application cannot be deleted; the following applications depend on it: '||l_dependent_app_lst);
   
   --delete object metadata associated with the application
   FOR rec_app_object_metadata
    IN
    (
      SELECT *
        FROM app_object_metadata
       WHERE application_name = ip_application_name
       ORDER
          BY object_name
   )
   LOOP
      IF NOT (    rec_app_object_metadata.discriminator_col = 'NONE'
              AND rec_app_object_metadata.dml_override_proc IS NULL ) 
      THEN
         delete_object_metadata_p
           ( ip_application_name  => ip_application_name
           , ip_object_name       => rec_app_object_metadata.object_name
           , ip_object_type       => rec_app_object_metadata.object_type
           , ip_discriminator_col => rec_app_object_metadata.discriminator_col
           , ip_discriminator_val => rec_app_object_metadata.discriminator_val );
      END IF;
   END LOOP
   ;
   FOR rec_app_object
    IN 
    (
       SELECT *
         FROM app_objects
        WHERE application_name = ip_application_name
    )
   LOOP
      drop_object_p( ip_object_type => rec_app_object.object_type
                   , ip_object_name => rec_app_object.object_name );
         
      DELETE 
        FROM app_objects 
       WHERE object_name = rec_app_object.object_name 
         AND object_namespace = rec_app_object.object_namespace;
   END LOOP;
   
   DELETE FROM app_dictionary WHERE application_name = ip_application_name;
   DELETE FROM application WHERE application_name = ip_application_name;
   
   COMMIT;
   <<end_now>>
   NULL;
END delete_application_p;



PROCEDURE delete_system_p
IS
   l_notfound BOOLEAN := FALSE;
BEGIN
   LOOP
      EXIT WHEN l_notfound;
      
      l_notfound := TRUE;
      
      FOR rec_application
       IN 
       (
         SELECT *
           FROM APPLICATION
          WHERE APPLICATION_NAME != 'CORE'
            AND APPLICATION_NAME 
               NOT IN 
               ( SELECT DEPENDS_ON
                  FROM APP_DEPENDENCY
               )
       )
      LOOP
         delete_application_p( ip_application_name => rec_application.application_name);
         l_notfound := FALSE;
      END LOOP;
   END LOOP;

END delete_system_p;


END PKG_APPLICATION;
/
