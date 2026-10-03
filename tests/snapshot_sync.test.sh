#!/bin/bash
# Tests for lib/snapshot_sync.sh against a local HTTP server (tests/range_server.py)
# that stands in for the public bucket: <network>/latest.json,
# <network>/<height>/snapshot_date.txt, the .tar.gz and its .sha256.
# Runs as root in a container (tests/run.sh).
set -uo pipefail
fail=0
T=$(mktemp -d)
PORT=8765
SERVER=""
expect() { if [[ "$2" =~ $3 ]]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want /$3/"; fail=1; fi; }

# start_server [VAR=value...]: (re)start the bucket server with failure modes
start_server() {
  [ -n "$SERVER" ] && { kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
  env "$@" python3 /w/tests/range_server.py "$T/bucket" "$PORT" >"$T/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return 0; sleep 0.1; done
  echo "server did not start:"; cat "$T/server.log"; exit 1
}

# place NETWORK HEIGHT ARCHIVE [bad-sha]: publish a prepared .tar.gz
place() {
  local n=$1 h=$2 src=$3 d="$T/bucket/$1/$2" f="svnode-$1-$2.tar.gz" sha
  rm -rf "$T/bucket/$n"; mkdir -p "$d"; cp "$src" "$d/$f"
  sha=$(sha256sum "$d/$f" | cut -c1-64)
  [ "${4:-}" = bad-sha ] && sha=$(printf 'a%.0s' {1..64})
  echo "$sha  $f" > "$d/$f.sha256"
  echo "2026-10-02T19:57:39Z" > "$d/snapshot_date.txt"
  printf '{"network":"%s","height":%s,"hash":"-","created":"2026-10-02T19:57:39Z","path":"%s/%s/","file":"%s","bytes":%s,"sha256":"%s"}\n' \
    "$n" "$h" "$n" "$h" "$f" "$(stat -c %s "$d/$f")" "$sha" > "$T/bucket/$n/latest.json"
}

# publish NETWORK HEIGHT [bad-sha|""] [DIRS...]: build a snapshot from the given folders
publish() {
  local n=$1 h=$2 bad=${3:-}
  local dirs=("${@:4}"); [ ${#dirs[@]} -eq 0 ] && dirs=(blocks chainstate frozentxos merkle)
  local src="$T/src-$n-$h"; rm -rf "$src"; mkdir -p "$src"
  for x in "${dirs[@]}"; do mkdir -p "$src/$x"; echo "$x-$h" > "$src/$x/data"; done
  tar -czf "$T/a.tar.gz" -C "$src" "${dirs[@]}"
  place "$n" "$h" "$T/a.tar.gz" "$bad"
}

# evil KIND: a crafted archive (python tarfile) with blocks/ and chainstate/ plus one bad entry
evil() {
  python3 - "$1" "$T/evil.tar.gz" <<'PY'
import io, sys, tarfile
kind, out = sys.argv[1], sys.argv[2]
def add(t, name, data=b"x", **kw):
    i = tarfile.TarInfo(name)
    for k, v in kw.items(): setattr(i, k, v)
    if i.type == tarfile.REGTYPE:
        i.size = len(data); t.addfile(i, io.BytesIO(data))
    else:
        t.addfile(i)
with tarfile.open(out, "w:gz") as t:
    add(t, "blocks", type=tarfile.DIRTYPE, mode=0o755)
    add(t, "blocks/data", b"evil-blocks")
    if kind == "symlink":
        add(t, "chainstate", type=tarfile.SYMTYPE, linkname="/tmp/outside")
    else:
        add(t, "chainstate", type=tarfile.DIRTYPE, mode=0o755)
        add(t, "chainstate/data", b"evil-cs")
    if kind == "sha":
        add(t, ".sha256", b"a" * 64 + b"\n")
    if kind == "device":
        add(t, "blocks/disk", type=tarfile.BLKTYPE, devmajor=8, devminor=0, mode=0o666)
    if kind == "extra":
        add(t, "evil", type=tarfile.DIRTYPE, mode=0o755)
        add(t, "evil/x", b"x")
    if kind == "setuid":
        add(t, "blocks/run", b"#!/bin/sh\n", mode=0o4755)
    if kind == "owner":
        add(t, "blocks/owned", b"x", uid=4242, gid=4242, mode=0o644)
PY
}

existing() {  # existing DIR: a data dir holding an older snapshot
  rm -rf "$1"; mkdir -p "$1"/{blocks,chainstate,frozentxos,merkle}
  for x in blocks chainstate frozentxos merkle; do echo "old" > "$1/$x/data"; done
}
listing() { (cd "$1" && find . -mindepth 1 -maxdepth 1 | sort | tr '\n' ' '); }
no_staging() { find "$1" -maxdepth 1 -name '.snapshot-*' | wc -l | tr -d ' '; }

mkdir -p "$T/bucket"
export SNAPSHOT_BASE_URL=http://127.0.0.1:$PORT RESUME_DELAY=0
# shellcheck disable=SC1091 # sourced for its functions; main does not run when sourced
source /w/lib/snapshot_sync.sh x /tmp >/dev/null
set +e   # the script sets -e for itself; the tests check return codes
start_server

# 1. latest.json is parsed into the snapshot fields
publish mainnet 969357
fetch_latest_info mainnet >/dev/null 2>&1
expect "1 parse" "${SNAP_HEIGHT:-} ${SNAP_FILE:-} ${SNAP_BYTES:-}" '^969357 svnode-mainnet-969357\.tar\.gz [0-9]+$'
expect "1 sha" "${SNAP_SHA256:-}" '^[0-9a-f]{64}$'

# 2. mainnet extracts into the data dir and leaves nothing behind
D="$T/d2"; mkdir -p "$D"
sync_snapshot mainnet "$D" >/dev/null 2>&1; rc=$?
expect "2 rc" "$rc" '^0$'
expect "2 folders" "$(listing "$D")" '^\./blocks \./chainstate \./frozentxos \./merkle $'
expect "2 content" "$(cat "$D/blocks/data")" '^blocks-969357$'

# 3. testnet extracts into testnet3/ only, also over existing testnet data
publish testnet 1706687
D="$T/d3"; existing "$D/testnet3"
sync_snapshot testnet "$D" >/dev/null 2>&1; rc=$?
expect "3 rc" "$rc" '^0$'
expect "3 root" "$(listing "$D")" '^\./testnet3 $'
expect "3 content" "$(cat "$D/testnet3/chainstate/data")" '^chainstate-1706687$'

# 4. replace, not merge: all four old folders go, even ones the snapshot lacks
publish mainnet 969500 "" blocks chainstate
D="$T/d4"; existing "$D"; echo stale > "$D/blocks/stale"
sync_snapshot mainnet "$D" >/dev/null 2>&1; rc=$?
expect "4 rc" "$rc" '^0$'
expect "4 folders" "$(listing "$D")" '^\./blocks \./chainstate $'
expect "4 stale gone" "$(ls "$D/blocks" | tr '\n' ' ')" '^data $'

# 5. a checksum mismatch fails and touches nothing
publish mainnet 969600 bad-sha
D="$T/d5"; existing "$D"
out=$(sync_snapshot mainnet "$D" 2>&1); rc=$?
expect "5 rc" "$rc" '^1$'
expect "5 message" "$out" 'Checksum mismatch'
expect "5 untouched" "$(cat "$D/chainstate/data")" '^old$'
expect "5 no staging" "$(no_staging "$D")" '^0$'

# 6. a snapshot without its completion marker is refused
publish mainnet 969700; rm "$T/bucket/mainnet/969700/snapshot_date.txt"
D="$T/d6"; mkdir -p "$D"
out=$(sync_snapshot mainnet "$D" 2>&1); rc=$?
expect "6 rc" "$rc" '^1$'
expect "6 message" "$out" 'not complete yet'
expect "6 empty" "$(listing "$D")" '^$'

# 7. no snapshot published for the network
out=$(sync_snapshot teratestnet "$T/d7" 2>&1); rc=$?
expect "7 rc" "$rc" '^1$'
expect "7 message" "$out" 'No snapshot is published for teratestnet'

# 8. connections dropped mid-download resume with Range requests
src="$T/src-big"; rm -rf "$src"; mkdir -p "$src"/{blocks,chainstate}
head -c 300000 /dev/urandom > "$src/blocks/blk00000.dat"; echo cs > "$src/chainstate/a"
tar -czf "$T/big.tar.gz" -C "$src" blocks chainstate
place mainnet 970000 "$T/big.tar.gz"
start_server DROP_AFTER=100000 DROP_TIMES=2
D="$T/d8"; mkdir -p "$D"
out=$(sync_snapshot mainnet "$D" 2>&1); rc=$?
expect "8 rc" "$rc" '^0$'
expect "8 first resume" "$out" 'Resuming at byte 100000 '
expect "8 second resume" "$out" 'Resuming at byte 200000 '
expect "8 content" "$(cmp -s "$src/blocks/blk00000.dat" "$D/blocks/blk00000.dat" && echo same)" '^same$'

# 9. an archive carrying its own .sha256 cannot fake the checksum
start_server
evil sha; place mainnet 970100 "$T/evil.tar.gz" bad-sha
D="$T/d9"; existing "$D"
out=$(sync_snapshot mainnet "$D" 2>&1); rc=$?
expect "9 rc" "$rc" '^1$'
expect "9 message" "$out" 'Checksum mismatch'
expect "9 untouched" "$(cat "$D/blocks/data")" '^old$'

# 10. disallowed archive contents are refused after verification
for kind in symlink device extra; do
  evil "$kind"; place mainnet 970200 "$T/evil.tar.gz"
  D="$T/d-$kind"; existing "$D"
  out=$(sync_snapshot mainnet "$D" 2>&1); rc=$?
  expect "10 $kind rc" "$rc" '^1$'
  expect "10 $kind message" "$out" 'unexpected content'
  expect "10 $kind untouched" "$(cat "$D/blocks/data")" '^old$'
  expect "10 $kind no staging" "$(no_staging "$D")" '^0$'
done
expect "10 symlink not followed" "$( [ -e /tmp/outside ] && echo exists || echo absent)" '^absent$'

# 11. setuid bits from the archive are not kept
evil setuid; place mainnet 970300 "$T/evil.tar.gz"
D="$T/d11"; mkdir -p "$D"
sync_snapshot mainnet "$D" >/dev/null 2>&1; rc=$?
expect "11 rc" "$rc" '^0$'
expect "11 no setuid" "$(find "$D" -perm /6000 | wc -l | tr -d ' ')" '^0$'

# 12. archive ownership is not kept: files belong to the user running the sync
evil owner; place mainnet 970400 "$T/evil.tar.gz"
D="$T/d12"; mkdir -p "$D"
sync_snapshot mainnet "$D" >/dev/null 2>&1; rc=$?
expect "12 rc" "$rc" '^0$'
expect "12 owner" "$(stat -c %u "$D/blocks/owned" 2>/dev/null)" "^$(id -u)$"

# 13. a failure while swapping the folders in rolls back to the old data
publish mainnet 970500
D="$T/d13"; existing "$D"
mv() { if [[ "${*: -1}" == "$D/chainstate" && "$1" == *snapshot-staging* ]]; then return 1; fi; command mv "$@"; }
out=$(sync_snapshot mainnet "$D" 2>&1); rc=$?
unset -f mv
expect "13 rc" "$rc" '^1$'
expect "13 rolled back" "$(cat "$D/blocks/data" "$D/chainstate/data" 2>/dev/null | tr '\n' ' ')" '^old old $'
expect "13 folders" "$(listing "$D")" '^\./blocks \./chainstate \./frozentxos \./merkle $'
expect "13 no leftovers" "$(no_staging "$D")" '^0$'

# 14. many drops are fine while each attempt makes progress
place mainnet 970000 "$T/big.tar.gz"
start_server DROP_AFTER=20000 DROP_TIMES=12
D="$T/d14"; mkdir -p "$D"
sync_snapshot mainnet "$D" >/dev/null 2>&1; rc=$?
expect "14 rc" "$rc" '^0$'

# 15. a full disk (tar dies) fails at once, without retrying the download
start_server
D="$T/d15"; existing "$D"
s=$(date +%s); out=$( (ulimit -f 100; sync_snapshot mainnet "$D") 2>&1); rc=$?
expect "15 rc" "$rc" '^1$'
expect "15 no retries" "$(grep -c 'Resuming' <<<"$out")" '^0$'
expect "15 fast" "$(( $(date +%s) - s ))" '^[0-4]$'
expect "15 untouched" "$(cat "$D/blocks/data")" '^old$'
expect "15 no staging" "$(no_staging "$D")" '^0$'

# 16. the archive disappearing (404) fails at once
rm "$T/bucket/mainnet/970000/svnode-mainnet-970000.tar.gz"
D="$T/d16"; mkdir -p "$D"
out=$(sync_snapshot mainnet "$D" 2>&1); rc=$?
expect "16 rc" "$rc" '^1$'
expect "16 no retries" "$(grep -c 'Resuming' <<<"$out")" '^0$'

# 17. a server that ignores Range on resume is refused, not re-streamed
place mainnet 970000 "$T/big.tar.gz"
start_server DROP_AFTER=100000 DROP_TIMES=1 IGNORE_RANGE=1
D="$T/d17"; existing "$D"
out=$(sync_snapshot mainnet "$D" 2>&1); rc=$?
expect "17 rc" "$rc" '^1$'
expect "17 message" "$out" 'did not resume at byte 100000'
expect "17 untouched" "$(cat "$D/blocks/data")" '^old$'

# 18. a stalled connection times out and resumes
start_server STALL_AFTER=50000
D="$T/d18"; mkdir -p "$D"
out=$(STALL_SECONDS=2 timeout 60 bash -c 'source /w/lib/snapshot_sync.sh x /tmp >/dev/null; sync_snapshot mainnet "$1"' _ "$D" 2>&1); rc=$?
expect "18 rc" "$rc" '^0$'
expect "18 resumed" "$out" 'Resuming at byte'

# 19. an interrupted sync (SIGTERM) cleans up after itself
start_server SLOW=20000
D="$T/d19"; existing "$D"
bash -c 'source /w/lib/snapshot_sync.sh x /tmp >/dev/null; sync_snapshot mainnet "$1"' _ "$D" >/dev/null 2>&1 &
pid=$!; sleep 2; kill -TERM "$pid"; wait "$pid"; rc=$?; sleep 1
expect "19 rc" "$rc" '^(130|143)$'
expect "19 no staging" "$(no_staging "$D")" '^0$'
expect "19 untouched" "$(cat "$D/blocks/data")" '^old$'
expect "19 no helpers" "$(pgrep -fc 'sha256sum' || true)" '^0$'

# 20. leftovers from an earlier interrupted run are cleared or restored first
D="$T/d20"; existing "$D"; mkdir -p "$D/.snapshot-staging/blocks"; echo junk > "$D/.snapshot-staging/blocks/x"
mkdir -p "$D/.snapshot-previous"; command mv "$D/chainstate" "$D/.snapshot-previous/chainstate"
prepare_data_dir "$D" mainnet >/dev/null 2>&1
expect "20 restored" "$(cat "$D/chainstate/data" 2>/dev/null)" '^old$'
expect "20 cleared" "$(no_staging "$D")" '^0$'

kill "$SERVER" 2>/dev/null; rm -rf "$T"; exit $fail
