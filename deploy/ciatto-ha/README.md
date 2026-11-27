# CIATTO HA foundation v1 (experimental)

Dedicated PostgreSQL schema, no production deployment. The upstream runtime still uses local SQLite/JSON and its own local lease. These SQL functions are not connected to agent dispatch, task scheduling, authentication or external tools. A stable operation ID must be derived from the underlying tenant, task and occurrence, not a retry attempt. One UUID per process incarnation; no UUID reuse. Workers must stop dispatch immediately on lease loss. Fencing prevents stale database claims; it does not cancel an external request already in progress. External API idempotency keys and verifiable receipts are required. An ambiguous claim stays blocked until a dedicated independently authorized reconciliation path is implemented.

The schema has no PUBLIC grants. Integrate via a dedicated service role with only the required access after review. Test in a disposable isolated database. Never apply to shared production before migration, concurrency tests, secret custody, runtime integration, independent review and rollback. Redis may accelerate queues/cache but cannot be the sole authority for execution ownership.

Run in isolated PostgreSQL: `psql -v ON_ERROR_STOP=1 -f 001_fencing.sql -f test_fencing.sql`. The test is synthetic and should never run against production.

Further gates: runtime storage adapter (all message, runtime, routine, file and attachment semantics), DB migration/reconciliation, authenticated UI, OAuth registrations/refresh per destination, idempotent dispatch and independent reconciliation, actual multi-node failover, metrics/backup/restore, reviewed Kubernetes manifests, no duplicate schedulers.

## Reproducible concurrency qualification

Run `./qualify-local.sh postgres:17-alpine` (or `postgres:18.7-alpine`) with an already installed local image. The disposable database is network-isolated; readiness uses an actual TCP query, not the temporary initialization socket. Both concurrent lease acquisition and duplicate operation claims must have exactly one winner.
