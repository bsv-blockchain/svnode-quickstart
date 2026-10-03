#!/bin/bash
# Runs the snapshot sync tests in a throwaway Ubuntu 24.04 container.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm -v "$here:/w:ro" ubuntu:24.04 bash -c '
  apt-get -qq update >/dev/null && apt-get -qq install -y curl python3 pigz >/dev/null
  bash /w/tests/snapshot_sync.test.sh'
