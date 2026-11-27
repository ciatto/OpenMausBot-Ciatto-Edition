-- CIATTO HA foundation v1. Apply only to a dedicated database as migration owner.
-- This is a prototype, not wired into OpenMausBot's runtime.
BEGIN;
CREATE SCHEMA IF NOT EXISTS omb_ha;
REVOKE ALL ON SCHEMA omb_ha FROM PUBLIC;
CREATE TABLE IF NOT EXISTS omb_ha.executor_lease (
  scope text PRIMARY KEY CHECK (length(scope) BETWEEN 1 AND 200),
  holder uuid NOT NULL,
  epoch bigint NOT NULL CHECK (epoch > 0),
  expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS omb_ha.execution_receipt (
  scope text NOT NULL REFERENCES omb_ha.executor_lease(scope),
  operation_id text NOT NULL CHECK (length(operation_id) BETWEEN 1 AND 256),
  holder uuid NOT NULL,
  epoch bigint NOT NULL CHECK (epoch > 0),
  state text NOT NULL CHECK (state IN ('claimed','completed','rejected')),
  claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  finished_at timestamptz,
  evidence_ref text,
  PRIMARY KEY (scope,operation_id),
  CHECK ((state='claimed' AND finished_at IS NULL AND evidence_ref IS NULL)
      OR (state IN ('completed','rejected') AND finished_at IS NOT NULL AND evidence_ref IS NOT NULL AND length(evidence_ref) BETWEEN 1 AND 1024))
);
-- New lease or renewal by the same process incarnation; takeover increments epoch.
-- Do not share holder IDs between processes. Database clock is authoritative.
CREATE OR REPLACE FUNCTION omb_ha.acquire(p_scope text,p_holder uuid,p_ttl_seconds integer)
RETURNS TABLE(fence bigint,valid_until timestamptz)
LANGUAGE plpgsql SET search_path=pg_catalog,omb_ha AS $$
BEGIN
 IF p_scope IS NULL OR length(p_scope) NOT BETWEEN 1 AND 200 OR p_holder IS NULL
    OR p_ttl_seconds IS NULL OR p_ttl_seconds NOT BETWEEN 1 AND 300 THEN
    RAISE EXCEPTION 'invalid lease request' USING ERRCODE='22023';
 END IF;
 RETURN QUERY INSERT INTO omb_ha.executor_lease AS l(scope,holder,epoch,expires_at)
 VALUES(p_scope,p_holder,1,clock_timestamp()+make_interval(secs=>p_ttl_seconds))
 ON CONFLICT(scope) DO UPDATE SET
   holder=EXCLUDED.holder,
   epoch=CASE WHEN l.holder=p_holder AND l.expires_at>clock_timestamp() THEN l.epoch ELSE l.epoch+1 END,
   expires_at=clock_timestamp()+make_interval(secs=>p_ttl_seconds)
 WHERE l.holder=p_holder OR l.expires_at<=clock_timestamp()
 RETURNING l.epoch,l.expires_at;
END $$;
-- Serializes lease validation with claim/takeover. Stable operation IDs deduplicate retries.
CREATE OR REPLACE FUNCTION omb_ha.claim(p_scope text,p_holder uuid,p_epoch bigint,p_operation text)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,omb_ha AS $$
DECLARE l omb_ha.executor_lease%ROWTYPE; n integer;
BEGIN
 SELECT * INTO l FROM omb_ha.executor_lease WHERE scope=p_scope FOR UPDATE;
 IF NOT FOUND OR l.holder IS DISTINCT FROM p_holder OR l.epoch IS DISTINCT FROM p_epoch OR l.expires_at<=clock_timestamp() THEN RETURN false; END IF;
 INSERT INTO omb_ha.execution_receipt(scope,operation_id,holder,epoch,state)
 VALUES(p_scope,p_operation,p_holder,p_epoch,'claimed') ON CONFLICT DO NOTHING;
 GET DIAGNOSTICS n=ROW_COUNT;
 RETURN n=1;
END $$;
-- Only the current fenced holder may record a terminal receipt for its own claim.
-- Ambiguous/abandoned claims remain claimed, requiring independent reconciliation.
CREATE OR REPLACE FUNCTION omb_ha.finish(p_scope text,p_holder uuid,p_epoch bigint,p_operation text,p_state text,p_evidence text)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,omb_ha AS $$
DECLARE l omb_ha.executor_lease%ROWTYPE; n integer;
BEGIN
 IF p_state IS NULL OR p_state NOT IN ('completed','rejected') OR p_evidence IS NULL OR length(p_evidence) NOT BETWEEN 1 AND 1024 THEN
   RAISE EXCEPTION 'terminal state requires evidence' USING ERRCODE='22023';
 END IF;
 SELECT * INTO l FROM omb_ha.executor_lease WHERE scope=p_scope FOR UPDATE;
 IF NOT FOUND OR l.holder IS DISTINCT FROM p_holder OR l.epoch IS DISTINCT FROM p_epoch OR l.expires_at<=clock_timestamp() THEN RETURN false; END IF;
 UPDATE omb_ha.execution_receipt SET state=p_state,finished_at=clock_timestamp(),evidence_ref=p_evidence
 WHERE scope=p_scope AND operation_id=p_operation AND holder=p_holder AND epoch=p_epoch AND state='claimed';
 GET DIAGNOSTICS n=ROW_COUNT; RETURN n=1;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA omb_ha FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA omb_ha FROM PUBLIC;
COMMIT;
