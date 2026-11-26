#!/usr/bin/env bash
# Copies the openGym files the oracles run verbatim (progression.js, rep-range.js, workout-model.js, plates.js, bar.js,
# dumbbells.js, recovery.js, onerm.js, effort.js, structuralBalance.js, structuralBalanceTemplates.js)
# from a checkout of openGym into ./lib/, next to the stubs. They are NOT committed here: they are
# Duarte Santos's code (MIT authorization to Gabriel Bolatoglu, see ATTRIBUTION.md) and only their output is.
# Usage: fetch.sh /path/to/opengym   (read from git, so no working-tree media is touched)
set -euo pipefail
src="${1:?path to an openGym git checkout}"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$here/lib"
for f in progression rep-range workout-model plates bar dumbbells recovery onerm effort structuralBalance structuralBalanceTemplates; do
  git -C "$src" show "HEAD:frontend/src/lib/$f.js" > "$here/lib/$f.js"
done
cp "$here"/stubs/*.js "$here/lib/"
