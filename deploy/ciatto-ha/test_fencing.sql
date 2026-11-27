\set ON_ERROR_STOP on
DO $$
DECLARE a uuid:='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; b uuid:='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; e bigint; e2 bigint; n integer;
BEGIN
 SELECT fence INTO e FROM omb_ha.acquire('synthetic-test',a,30);
 IF e IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'initial fence'; END IF;
 SELECT count(*) INTO n FROM omb_ha.acquire('synthetic-test',b,30);
 IF n<>0 THEN RAISE EXCEPTION 'split brain'; END IF;
 SELECT fence INTO e2 FROM omb_ha.acquire('synthetic-test',a,30);
 IF e2 IS DISTINCT FROM e THEN RAISE EXCEPTION 'renewal changed fence'; END IF;
 IF NOT omb_ha.claim('synthetic-test',a,e,'operation-1') THEN RAISE EXCEPTION 'claim failed'; END IF;
 IF omb_ha.claim('synthetic-test',a,e,'operation-1') THEN RAISE EXCEPTION 'duplicate claim'; END IF;
 IF omb_ha.claim('synthetic-test',b,e,'operation-2') THEN RAISE EXCEPTION 'wrong holder'; END IF;
 IF NOT omb_ha.finish('synthetic-test',a,e,'operation-1','completed','synthetic-receipt') THEN RAISE EXCEPTION 'finish failed'; END IF;
 IF omb_ha.finish('synthetic-test',a,e,'operation-1','completed','duplicate') THEN RAISE EXCEPTION 'duplicate terminal'; END IF;
 IF NOT omb_ha.claim('synthetic-test',a,e,'uncertain-operation') THEN RAISE EXCEPTION 'uncertain claim'; END IF;
 -- Test fixture simulates expiry; no production mutation.
 UPDATE omb_ha.executor_lease SET expires_at=clock_timestamp()-interval '1 second' WHERE scope='synthetic-test';
 IF omb_ha.claim('synthetic-test',a,e,'stale-before-takeover') THEN RAISE EXCEPTION 'expired lease accepted'; END IF;
 SELECT fence INTO e2 FROM omb_ha.acquire('synthetic-test',b,30);
 IF e2 IS DISTINCT FROM e+1 THEN RAISE EXCEPTION 'takeover fence'; END IF;
 IF omb_ha.claim('synthetic-test',a,e,'stale-operation') THEN RAISE EXCEPTION 'stale fence accepted'; END IF;
 IF omb_ha.finish('synthetic-test',a,e,'uncertain-operation','completed','stale') THEN RAISE EXCEPTION 'stale completion accepted'; END IF;
 IF omb_ha.claim('synthetic-test',b,e2,'uncertain-operation') THEN RAISE EXCEPTION 'ambiguous operation replayed'; END IF;
 IF omb_ha.finish('synthetic-test',b,e2,'uncertain-operation','completed','invented') THEN RAISE EXCEPTION 'foreign receipt overwritten'; END IF;
 IF NOT omb_ha.claim('synthetic-test',b,e2,'new-operation') THEN RAISE EXCEPTION 'new holder rejected'; END IF;
 IF NOT omb_ha.finish('synthetic-test',b,e2,'new-operation','completed','synthetic-new-receipt') THEN RAISE EXCEPTION 'new holder finish'; END IF;
 RAISE NOTICE 'PASS initial lease, exclusivity, renewal, deduplication, expiry, monotonic fencing, stale rejection, ambiguous claim hold, new owner completion';
END $$;
