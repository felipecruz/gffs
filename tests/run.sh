#!/usr/bin/env bash
# Builds gffs and runs its tests:
#   1. the glob unit tests (glob_test.goose);
#   2. ffs's tests/compat.sh, 97 command lines diffed against rg, if an ffs
#      checkout is at $FFS_DIR (default ../ffs);
#   3. tests/rg_diff.sh over a Redis checkout at $REDIS, if set.
# Needs goose ($GOOSE, default goose/build/goose, from scripts/setup-goose.sh)
# and rg.
set -eu
cd "$(dirname "$0")/.."
GOOSE=${GOOSE:-goose/build/goose}
FFS_DIR=${FFS_DIR:-../ffs}
"$GOOSE" build gffs.goose 2>&1 | tail -1
"$GOOSE" run glob_test.goose 2>&1 | grep -v "^parsed\|^typechecked\|^bce"
if [ -f "$FFS_DIR/tests/compat.sh" ]; then bash "$FFS_DIR/tests/compat.sh" ./gffs; fi
if [ -n "${REDIS:-}" ]; then bash tests/rg_diff.sh ./gffs "$REDIS"; fi
