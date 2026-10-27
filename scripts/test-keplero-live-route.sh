#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
node_modules/.bin/tsc --target ES2022 --module commonjs --moduleResolution node \
  --esModuleInterop --skipLibCheck --strict --rewriteRelativeImportExtensions \
  --outDir "$test_dir" scripts/keplero-live-route.test.ts
NODE_PATH="$PWD/node_modules" node --test "$test_dir/scripts/keplero-live-route.test.js"
