CREATE OR REPLACE PACKAGE BODY PKG_CORE_OPERATION
AS

  -- =========================================================================
  -- Private Procedures and Functions
  -- =========================================================================

   FUNCTION format_guid_f(ip_raw IN RAW)
      RETURN VARCHAR2
   IS
      l_hex VARCHAR2(32) := LOWER(RAWTOHEX(ip_raw));
   BEGIN
      RETURN SUBSTR(l_hex,1,8)||'-'||SUBSTR(l_hex,9,4)||'-'||SUBSTR(l_hex,13,4)
             ||'-'||SUBSTR(l_hex,17,4)||'-'||SUBSTR(l_hex,21,12);
   END format_guid_f;



   FUNCTION new_fencing_token_f
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN LOWER(RAWTOHEX(SYS_GUID()));
   END new_fencing_token_f;

  -- =========================================================================
  -- Public Procedures
  -- =========================================================================

   FUNCTION application_scope_f(ip_application_name IN VARCHAR2)
      RETURN VARCHAR2
   IS
   BEGIN
      assert(ip_application_name IS NOT NULL, 'ip_application_name is required');
      RETURN c_scope_application_prefix || UPPER(ip_application_name);
   END application_scope_f;



   PROCEDURE begin_and_acquire_operation_p
   (
      ip_primary_scope      IN  VARCHAR2
    , ip_participant_scopes IN  VARCHAR_TAB DEFAULT NULL
    , ip_actor              IN  VARCHAR2 DEFAULT NULL
    , ip_lease_seconds      IN  NUMBER DEFAULT 300
    , op_operation_id       OUT VARCHAR2
    , op_attempt_number     OUT NUMBER
    , op_fencing_token      OUT VARCHAR2
    , op_lease_expires_at   OUT TIMESTAMP WITH TIME ZONE
    , op_busy               OUT VARCHAR2
    , op_busy_until         OUT TIMESTAMP WITH TIME ZONE
   )
   IS
      l_dummy          core_operation_lock.lock_id%TYPE;
      l_operation_id   core_operation.operation_id%TYPE;
      l_attempt_number core_operation.attempt_number%TYPE;
      l_expires_at     core_operation.lease_expires_at%TYPE;
      l_fencing_token  core_operation.fencing_token%TYPE;
      l_scopes         VARCHAR_TAB := VARCHAR_TAB();
      l_conflict_op    core_operation.operation_id%TYPE;
      l_conflict_until core_operation.lease_expires_at%TYPE;
      l_found          BOOLEAN;
   BEGIN
      assert(ip_primary_scope IS NOT NULL, 'ip_primary_scope is required');
      assert(
          ip_lease_seconds BETWEEN c_lease_seconds_min AND c_lease_seconds_max
        , 'ip_lease_seconds must be between '||c_lease_seconds_min||' and '||c_lease_seconds_max
      );

      op_busy := 'N';

      SELECT lock_id
        INTO l_dummy
        FROM core_operation_lock
       WHERE lock_id = 'X'
         FOR UPDATE;

      -- Build the deduplicated set of scopes this operation must hold.
      l_scopes.EXTEND;
      l_scopes(l_scopes.LAST) := ip_primary_scope;
      IF ip_participant_scopes IS NOT NULL THEN
         FOR i IN 1 .. ip_participant_scopes.COUNT LOOP
            l_found := FALSE;
            FOR j IN 1 .. l_scopes.COUNT LOOP
               IF l_scopes(j) = ip_participant_scopes(i) THEN
                  l_found := TRUE;
               END IF;
            END LOOP;
            IF NOT l_found THEN
               l_scopes.EXTEND;
               l_scopes(l_scopes.LAST) := ip_participant_scopes(i);
            END IF;
         END LOOP;
      END IF;

      -- Resume the existing operation for this primary scope, or create one.
      BEGIN
         SELECT operation_id, attempt_number, lease_expires_at
           INTO l_operation_id, l_attempt_number, l_expires_at
           FROM core_operation
          WHERE primary_scope = ip_primary_scope
            FOR UPDATE;

         IF l_expires_at > SYSTIMESTAMP THEN
            op_busy := 'Y';
            op_busy_until := l_expires_at;
            ROLLBACK;
            RETURN;
         END IF;

         l_attempt_number := l_attempt_number + 1;

         DELETE
           FROM core_operation_scope
          WHERE operation_id = l_operation_id;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            l_operation_id := format_guid_f(SYS_GUID());
            l_attempt_number := 1;
      END;

      -- SCHEMA_LIFECYCLE conflicts with, and is conflicted by, every scope.
      IF ip_primary_scope = c_scope_schema_lifecycle THEN
         BEGIN
            SELECT o.operation_id, o.lease_expires_at
              INTO l_conflict_op, l_conflict_until
              FROM core_operation_scope os
              JOIN core_operation o
                ON o.operation_id = os.operation_id
             WHERE os.operation_id != l_operation_id
               AND o.lease_expires_at > SYSTIMESTAMP
               AND ROWNUM = 1;

            op_busy := 'Y';
            op_busy_until := l_conflict_until;
            ROLLBACK;
            RETURN;
         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               NULL;
         END;
      ELSE
         BEGIN
            SELECT o.operation_id, o.lease_expires_at
              INTO l_conflict_op, l_conflict_until
              FROM core_operation_scope os
              JOIN core_operation o
                ON o.operation_id = os.operation_id
             WHERE os.scope_key = c_scope_schema_lifecycle
               AND os.operation_id != l_operation_id
               AND o.lease_expires_at > SYSTIMESTAMP;

            op_busy := 'Y';
            op_busy_until := l_conflict_until;
            ROLLBACK;
            RETURN;
         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               NULL;
         END;
      END IF;

      -- Validate every requested scope is free or reclaimable from an expired lease.
      FOR i IN 1 .. l_scopes.COUNT LOOP
         BEGIN
            SELECT o.operation_id, o.lease_expires_at
              INTO l_conflict_op, l_conflict_until
              FROM core_operation_scope os
              JOIN core_operation o
                ON o.operation_id = os.operation_id
             WHERE os.scope_key = l_scopes(i);

            IF l_conflict_until > SYSTIMESTAMP THEN
               op_busy := 'Y';
               op_busy_until := l_conflict_until;
               ROLLBACK;
               RETURN;
            ELSE
               DELETE
                 FROM core_operation_scope
                WHERE scope_key = l_scopes(i);

               UPDATE core_operation
                  SET operation_status = c_operation_status_expired
                WHERE operation_id = l_conflict_op
                  AND lease_expires_at <= SYSTIMESTAMP;
            END IF;
         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               NULL;
         END;
      END LOOP;

      l_fencing_token := new_fencing_token_f;
      l_expires_at := SYSTIMESTAMP + NUMTODSINTERVAL(ip_lease_seconds, 'SECOND');

      MERGE INTO core_operation o
      USING (SELECT l_operation_id AS operation_id FROM dual) s
         ON (o.operation_id = s.operation_id)
      WHEN MATCHED THEN
         UPDATE SET operation_status  = c_operation_status_active
                  , attempt_number    = l_attempt_number
                  , fencing_token     = l_fencing_token
                  , lease_expires_at  = l_expires_at
                  , actor             = ip_actor
                  , updated_at        = SYSTIMESTAMP
                  , released_at       = NULL
      WHEN NOT MATCHED THEN
         INSERT
         (
             operation_id
           , primary_scope
           , operation_status
           , attempt_number
           , fencing_token
           , lease_expires_at
           , actor
           , created_at
           , updated_at
         )
         VALUES
         (
             l_operation_id
           , ip_primary_scope
           , c_operation_status_active
           , l_attempt_number
           , l_fencing_token
           , l_expires_at
           , ip_actor
           , SYSTIMESTAMP
           , SYSTIMESTAMP
         );

      FOR i IN 1 .. l_scopes.COUNT LOOP
         INSERT INTO core_operation_scope
         (
             scope_key
           , operation_id
           , is_primary
         )
         VALUES
         (
             l_scopes(i)
           , l_operation_id
           , CASE WHEN l_scopes(i) = ip_primary_scope THEN 'Y' ELSE 'N' END
         );
      END LOOP;

      COMMIT;

      op_operation_id     := l_operation_id;
      op_attempt_number   := l_attempt_number;
      op_fencing_token    := l_fencing_token;
      op_lease_expires_at := l_expires_at;
   END begin_and_acquire_operation_p;



   PROCEDURE get_current_operation_p
   (
      ip_primary_scope     IN  VARCHAR2
    , op_operation_id      OUT VARCHAR2
    , op_attempt_number    OUT NUMBER
    , op_operation_status  OUT VARCHAR2
    , op_lease_expires_at  OUT TIMESTAMP WITH TIME ZONE
    , op_last_step_name    OUT VARCHAR2
    , op_last_step_status  OUT VARCHAR2
   )
   IS
   BEGIN
      SELECT operation_id, attempt_number, operation_status, lease_expires_at
           , last_step_name, last_step_status
        INTO op_operation_id, op_attempt_number, op_operation_status, op_lease_expires_at
           , op_last_step_name, op_last_step_status
        FROM core_operation
       WHERE primary_scope = ip_primary_scope;
   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         NULL;
   END get_current_operation_p;



   PROCEDURE verify_fence_p
   (
      ip_operation_id   IN VARCHAR2
    , ip_attempt_number IN NUMBER
    , ip_fencing_token  IN VARCHAR2
   )
   IS
      l_status  core_operation.operation_status%TYPE;
      l_attempt core_operation.attempt_number%TYPE;
      l_token   core_operation.fencing_token%TYPE;
      l_expires core_operation.lease_expires_at%TYPE;
   BEGIN
      BEGIN
         SELECT operation_status, attempt_number, fencing_token, lease_expires_at
           INTO l_status, l_attempt, l_token, l_expires
           FROM core_operation
          WHERE operation_id = ip_operation_id;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            assert(FALSE, 'Unknown operation_id');
      END;

      assert(l_status = c_operation_status_active, 'Operation is not active');
      assert(l_attempt = ip_attempt_number, 'Operation attempt has been superseded');
      assert(l_token = ip_fencing_token, 'Operation fencing token is stale');
      assert(l_expires > SYSTIMESTAMP, 'Operation lease has expired');
   END verify_fence_p;



   PROCEDURE renew_operation_lease_p
   (
      ip_operation_id     IN  VARCHAR2
    , ip_attempt_number   IN  NUMBER
    , ip_fencing_token    IN  VARCHAR2
    , ip_lease_seconds    IN  NUMBER DEFAULT 300
    , op_lease_expires_at OUT TIMESTAMP WITH TIME ZONE
   )
   IS
   BEGIN
      assert(
          ip_lease_seconds BETWEEN c_lease_seconds_min AND c_lease_seconds_max
        , 'ip_lease_seconds must be between '||c_lease_seconds_min||' and '||c_lease_seconds_max
      );

      verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);

      UPDATE core_operation
         SET lease_expires_at = SYSTIMESTAMP + NUMTODSINTERVAL(ip_lease_seconds, 'SECOND')
           , updated_at       = SYSTIMESTAMP
       WHERE operation_id = ip_operation_id
         AND fencing_token = ip_fencing_token
      RETURNING lease_expires_at INTO op_lease_expires_at;

      COMMIT;
   END renew_operation_lease_p;



   PROCEDURE record_operation_step_p
   (
      ip_operation_id   IN VARCHAR2
    , ip_attempt_number IN NUMBER
    , ip_fencing_token  IN VARCHAR2
    , ip_step_name      IN VARCHAR2
    , ip_step_status    IN VARCHAR2
    , ip_detail         IN VARCHAR2 DEFAULT NULL
   )
   IS
   BEGIN
      assert(ip_step_name IS NOT NULL, 'ip_step_name is required');
      assert(ip_step_status IS NOT NULL, 'ip_step_status is required');

      verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);

      UPDATE core_operation
         SET last_step_name   = ip_step_name
           , last_step_status = ip_step_status
           , updated_at       = SYSTIMESTAMP
       WHERE operation_id = ip_operation_id;

      MERGE INTO core_operation_step t
      USING (SELECT ip_operation_id AS operation_id, ip_attempt_number AS attempt_number, ip_step_name AS step_name FROM dual) s
         ON (t.operation_id = s.operation_id AND t.attempt_number = s.attempt_number AND t.step_name = s.step_name)
      WHEN MATCHED THEN
         UPDATE SET step_status = ip_step_status
                  , detail      = ip_detail
                  , recorded_at = SYSTIMESTAMP
      WHEN NOT MATCHED THEN
         INSERT
         (
             operation_id
           , attempt_number
           , step_name
           , step_status
           , detail
           , recorded_at
         )
         VALUES
         (
             ip_operation_id
           , ip_attempt_number
           , ip_step_name
           , ip_step_status
           , ip_detail
           , SYSTIMESTAMP
         );

      COMMIT;
   END record_operation_step_p;



   PROCEDURE release_operation_lease_p
   (
      ip_operation_id   IN VARCHAR2
    , ip_attempt_number IN NUMBER
    , ip_fencing_token  IN VARCHAR2
   )
   IS
   BEGIN
      verify_fence_p(ip_operation_id, ip_attempt_number, ip_fencing_token);

      DELETE
        FROM core_operation_scope
       WHERE operation_id = ip_operation_id;

      UPDATE core_operation
         SET operation_status  = c_operation_status_released
           , lease_expires_at  = SYSTIMESTAMP
           , released_at       = SYSTIMESTAMP
           , updated_at        = SYSTIMESTAMP
       WHERE operation_id = ip_operation_id;

      COMMIT;
   END release_operation_lease_p;

END PKG_CORE_OPERATION;
/
