#!/bin/sh
# Synthetic fencing qualification; never contacts a shared database.
set -eu
cd "$(dirname "$0")"
image="${1:-postgres:17-alpine}"
case "$image" in postgres:17-alpine|postgres:18.7-alpine) ;; *) echo "Use a qualified local test image" >&2; exit 2;; esac
docker image inspect "$image" >/dev/null
umask 077
tmp=$(mktemp -d)
cid=""
cleanup() {
  if [ -n "$cid" ]; then docker stop -t 2 "$cid" >/dev/null 2>&1 || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cid=$(docker run --pull never -d --rm --network none --memory 512m --cpus 1 -e POSTGRES_PASSWORD="$(openssl rand -hex 32)" -e POSTGRES_DB=omb_ha_qa "$image")
ready=0
for i in $(seq 1 50); do
  if docker exec "$cid" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -X -At -U postgres -d omb_ha_qa -c "SELECT 1"' >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 0.4
done
test "$ready" = 1
sql() { docker exec -i "$cid" psql -X -At -v ON_ERROR_STOP=1 -U postgres -d omb_ha_qa "$@"; }
sql < 001_fencing.sql
sql < test_fencing.sql
sql -c "SELECT count(*) FROM omb_ha.acquire('race-acquire','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',60)" > "$tmp/a" & p1=$!
sql -c "SELECT count(*) FROM omb_ha.acquire('race-acquire','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',60)" > "$tmp/b" & p2=$!
wait "$p1"; wait "$p2"
x=$(cat "$tmp/a"); y=$(cat "$tmp/b")
test "$x$y" = 10 || test "$x$y" = 01
echo "PASS concurrent acquisition: $x/$y"
test "$(sql -c "SELECT fence FROM omb_ha.acquire('race-claim','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',60)")" = 1
sql -c "SELECT omb_ha.claim('race-claim','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,'same-operation')" > "$tmp/a" & p1=$!
sql -c "SELECT omb_ha.claim('race-claim','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,'same-operation')" > "$tmp/b" & p2=$!
wait "$p1"; wait "$p2"
x=$(cat "$tmp/a"); y=$(cat "$tmp/b")
test "$x$y" = tf || test "$x$y" = ft
echo "PASS concurrent claim: $x/$y"
sql -c 'SELECT version()'
