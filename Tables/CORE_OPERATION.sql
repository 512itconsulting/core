CREATE TABLE CORE_OPERATION
(
  OPERATION_ID       VARCHAR2(36)  NOT NULL
, PRIMARY_SCOPE      VARCHAR2(60)  NOT NULL
, OPERATION_STATUS   VARCHAR2(10)  DEFAULT 'ACTIVE' NOT NULL
, ATTEMPT_NUMBER     INTEGER       DEFAULT 1 NOT NULL
, FENCING_TOKEN      VARCHAR2(32)  NOT NULL
, LEASE_EXPIRES_AT   TIMESTAMP WITH TIME ZONE NOT NULL
, ACTOR              VARCHAR2(128)
, LAST_STEP_NAME     VARCHAR2(60)
, LAST_STEP_STATUS   VARCHAR2(30)
, CREATED_AT         TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL
, UPDATED_AT         TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL
, RELEASED_AT        TIMESTAMP WITH TIME ZONE
, CONSTRAINT CORE_OPERATION_PK  PRIMARY KEY (OPERATION_ID)
, CONSTRAINT CORE_OPERATION_UK1 UNIQUE (PRIMARY_SCOPE)
, CONSTRAINT CORE_OPERATION_CK1 CHECK (OPERATION_STATUS IN ('ACTIVE','RELEASED','EXPIRED') )
, CONSTRAINT CORE_OPERATION_CK2 CHECK (ATTEMPT_NUMBER >= 1)
)
;

COMMENT ON TABLE  CORE_OPERATION                   IS 'Fenced, leased operations claiming one primary scope (e.g. SCHEMA_LIFECYCLE, SCHEMA_RUNTIME, APPLICATION:<name>). One row per primary scope, reused and re-fenced across resumed attempts.';
--
COMMENT ON COLUMN CORE_OPERATION.OPERATION_ID      IS 'PK. Core-generated immutable identifier, stable across resumed attempts for the same primary scope.';
COMMENT ON COLUMN CORE_OPERATION.PRIMARY_SCOPE     IS 'UK. The scope this operation exists to protect; see PKG_CORE_OPERATION scope constants.';
COMMENT ON COLUMN CORE_OPERATION.OPERATION_STATUS  IS 'ACTIVE, RELEASED, or EXPIRED. Expiry is authoritatively judged by LEASE_EXPIRES_AT, not this column; this column reflects the last-known/voluntary state.';
COMMENT ON COLUMN CORE_OPERATION.ATTEMPT_NUMBER    IS 'Increments each time the operation is (re)acquired after its previous lease expired.';
COMMENT ON COLUMN CORE_OPERATION.FENCING_TOKEN     IS 'Regenerated on every acquisition. Not a secret; a collision/staleness-avoidance value.';
COMMENT ON COLUMN CORE_OPERATION.LEASE_EXPIRES_AT  IS 'Current lease expiry. A lease past this time is stale and reclaimable regardless of OPERATION_STATUS.';
COMMENT ON COLUMN CORE_OPERATION.ACTOR             IS 'Caller-supplied actor identity for auditing.';
COMMENT ON COLUMN CORE_OPERATION.LAST_STEP_NAME    IS 'Most recent step name recorded via PKG_CORE_OPERATION.record_operation_step_p.';
COMMENT ON COLUMN CORE_OPERATION.LAST_STEP_STATUS  IS 'Most recent step status recorded via PKG_CORE_OPERATION.record_operation_step_p.';
COMMENT ON COLUMN CORE_OPERATION.RELEASED_AT       IS 'Timestamp of the most recent explicit release_operation_lease_p call.';
