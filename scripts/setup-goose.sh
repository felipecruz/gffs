#!/usr/bin/env bash
# Clones the Goose compiler (github.com/aardappel/goose) into ./goose and
# builds it, so that ./goose/build/goose can build gffs:
#
#   scripts/setup-goose.sh
#   goose/build/goose build gffs.goose
#
# It is pinned to the commit gffs was written against, since the language is
# still changing; GOOSE_REF=main (or another ref) builds a different one.
# Needs git, CMake 3.27 or later and a C++20 compiler.
set -euo pipefail
cd "$(dirname "$0")/.."
REF=${GOOSE_REF:-af8a2fe132855a28fdc73777f676afe36152d2f3}
if [ ! -d goose/.git ]; then
  git clone https://github.com/aardappel/goose goose
fi
git -C goose fetch --quiet origin
git -C goose checkout --quiet "$REF"
cmake -S goose -B goose/build -DCMAKE_BUILD_TYPE=Release
cmake --build goose/build --config Release -j
echo "built $(pwd)/goose/build/goose"
