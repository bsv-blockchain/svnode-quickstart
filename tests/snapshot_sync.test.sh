#!/bin/bash
# Tests for lib/snapshot_sync.sh against a local HTTP server that stands in for
# the public bucket: <network>/latest.json, <network>/<height>/snapshot_date.txt,
# the .tar.gz and its .sha256.
set -uo pipefail
fail=0
T=$(mktemp -d)
expect() { if [[ "$2" =~ $3 ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want /$3/"; fail=1; fi; }

# publish NETWORK HEIGHT [bad-sha]: build a snapshot archive into the fake bucket
publish() {
  local n=$1 h=$2 src="$T/src-$1" d="$T/bucket/$1/$2" f="svnode-$1-$2.tar.gz"
  rm -rf "$src" "$T/bucket/$n"; mkdir -p "$src"/{blocks,chainstate,frozentxos,merkle} "$d"
  echo "blk-$h" > "$src/blocks/blk00000.dat"; echo "cs-$h" > "$src/chainstate/000001.ldb"
  echo ft > "$src/frozentxos/a"; echo mk > "$src/merkle/b"
  tar -czf "$d/$f" -C "$src" blocks chainstate frozentxos merkle
  local sha; sha=$(sha256sum "$d/$f" | cut -c1-64)
  [ "${3:-}" = bad-sha ] && sha=$(printf '0%.0s' {1..64})
  echo "$sha  $f" > "$d/$f.sha256"
  echo "2026-10-02T19:57:39Z" > "$d/snapshot_date.txt"
  printf '{"network":"%s","height":%s,"hash":"-","created":"2026-10-02T19:57:39Z","path":"%s/%s/","file":"%s","bytes":%s,"sha256":"%s"}\n' \
    "$n" "$h" "$n" "$h" "$f" "$(stat -c %s "$d/$f")" "$sha" > "$T/bucket/$n/latest.json"
}

mkdir -p "$T/bucket"
python3 /w/tests/range_server.py "$T/bucket" 8765 >/dev/null 2>&1 &
SERVER=$!; sleep 1
export SNAPSHOT_BASE_URL=http://127.0.0.1:8765
# shellcheck disable=SC1091 # sourced for its functions; main does not run when sourced
source /w/lib/snapshot_sync.sh x /tmp >/dev/null
set +e   # the script sets -e for itself; the tests check return codes

# 1. latest.json is parsed into the snapshot fields
publish mainnet 969357
fetch_latest_info mainnet >/dev/null 2>&1
expect "1 parse" "${SNAP_HEIGHT:-} ${SNAP_FILE:-} ${SNAP_BYTES:-}" '^969357 svnode-mainnet-969357\.tar\.gz [0-9]+$'
expect "1 sha" "${SNAP_SHA256:-}" '^[0-9a-f]{64}$'

# 2. mainnet extracts into the data dir and leaves no staging behind
D="$T/data-main"; mkdir -p "$D"
sync_snapshot mainnet "$D" >/dev/null 2>&1; rc=$?
expect "2 rc" "$rc" '^0$'
expect "2 folders" "$(ls "$D" | tr '\n' ' ')" '^blocks chainstate frozentxos merkle $'
expect "2 content" "$(cat "$D/blocks/blk00000.dat")" '^blk-969357$'
expect "2 no staging" "$(find "$D" -maxdepth 1 -name .snapshot-staging | wc -l | tr -d ' ')" '^0$'

# 3. testnet extracts into testnet3/
publish testnet 1706687
D="$T/data-test"; mkdir -p "$D"
sync_snapshot testnet "$D" >/dev/null 2>&1; rc=$?
expect "3 rc" "$rc" '^0$'
expect "3 testnet3" "$(ls "$D/testnet3" | tr '\n' ' ')" '^blocks chainstate frozentxos merkle $'

# 4. existing data is replaced, not merged: files only in the old data are gone
publish mainnet 969500
D="$T/data-main"; echo stale > "$D/blocks/blk99999.dat"
sync_snapshot mainnet "$D" >/dev/null 2>&1; rc=$?
expect "4 rc" "$rc" '^0$'
expect "4 new" "$(cat "$D/blocks/blk00000.dat")" '^blk-969500$'
expect "4 stale gone" "$(ls "$D/blocks" | tr '\n' ' ')" '^blk00000\.dat $'

# 5. a checksum mismatch fails and touches nothing
publish mainnet 969600 bad-sha
D="$T/data-bad"; mkdir -p "$D/blocks"; echo keep > "$D/blocks/blk00000.dat"
sync_snapshot mainnet "$D" >/dev/null 2>&1; rc=$?
expect "5 rc" "$rc" '^1$'
expect "5 untouched" "$(cat "$D/blocks/blk00000.dat")" '^keep$'
expect "5 no staging" "$(find "$D" -maxdepth 1 -name .snapshot-staging | wc -l | tr -d ' ')" '^0$'
expect "5 no chainstate" "$( [ -d "$D/chainstate" ] && echo present || echo absent)" '^absent$'

# 6. a snapshot without its completion marker is refused
publish mainnet 969700; rm "$T/bucket/mainnet/969700/snapshot_date.txt"
D="$T/data-nomarker"; mkdir -p "$D"
sync_snapshot mainnet "$D" >/dev/null 2>&1; rc=$?
expect "6 rc" "$rc" '^1$'
expect "6 empty" "$(ls -A "$D" | wc -l | tr -d ' ')" '^0$'

# 7. no snapshot published for the network
D="$T/data-none"; mkdir -p "$D"
sync_snapshot teratestnet "$D" >/dev/null 2>&1; rc=$?
expect "7 rc" "$rc" '^1$'

# 8. a connection dropped mid-download resumes with a Range request and the
#    result still verifies (the archive here is padded so the cut is mid-stream)
kill "$SERVER"; wait "$SERVER" 2>/dev/null
src="$T/src-big"; rm -rf "$src"; mkdir -p "$src"/{blocks,chainstate}
head -c 300000 /dev/urandom > "$src/blocks/blk00000.dat"; echo cs > "$src/chainstate/a"
d="$T/bucket/mainnet/970000"; rm -rf "$T/bucket/mainnet"; mkdir -p "$d"
tar -czf "$d/svnode-mainnet-970000.tar.gz" -C "$src" blocks chainstate
sha=$(sha256sum "$d/svnode-mainnet-970000.tar.gz" | cut -c1-64); echo x > "$d/snapshot_date.txt"
printf '{"network":"mainnet","height":970000,"hash":"-","created":"x","path":"mainnet/970000/","file":"svnode-mainnet-970000.tar.gz","bytes":%s,"sha256":"%s"}\n' \
  "$(stat -c %s "$d/svnode-mainnet-970000.tar.gz")" "$sha" > "$T/bucket/mainnet/latest.json"
DROP_AFTER=100000 DROP_TIMES=2 python3 /w/tests/range_server.py "$T/bucket" 8765 >/dev/null 2>&1 &
SERVER=$!; sleep 1
D="$T/data-resume"; mkdir -p "$D"
out=$(sync_snapshot mainnet "$D" 2>&1); rc=$?
expect "8 rc" "$rc" '^0$'
expect "8 resumed" "$out" 'Resuming at byte 100000'
expect "8 content" "$(cmp -s "$src/blocks/blk00000.dat" "$D/blocks/blk00000.dat" && echo same)" '^same$'

kill "$SERVER"; rm -rf "$T"; exit $fail
