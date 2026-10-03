#!/bin/bash
# Runs the snapshot sync tests in a throwaway Ubuntu 24.04 container, once with
# pigz and once without it (the gzip fallback).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm -v "$here:/w:ro" ubuntu:24.04 bash -c '
  apt-get -qq update >/dev/null && apt-get -qq install -y curl python3 pigz >/dev/null
  echo "== with pigz"; timeout 900 bash /w/tests/snapshot_sync.test.sh; a=$?
  apt-get -qq remove -y pigz >/dev/null 2>&1
  echo "== without pigz"; timeout 900 bash /w/tests/snapshot_sync.test.sh; b=$?
  exit $((a | b))'
