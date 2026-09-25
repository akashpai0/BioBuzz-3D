#!/usr/bin/env bash
# Builds the BROWSER version of BIOBUZZ 3D into build/web/ (index.html + files).
#
# A browser cannot load the Epic Online Services plugin (it is a native
# library), so this exports from a temporary copy of the project with the
# plugin, its autoloads and the credentials file taken out. The game itself
# notices it is running in a browser and says online rooms and CAD import need
# the downloadable version.
#
# Needs: Godot 4.5 on PATH as `godot` (or GODOT=/path/to/godot) with the 4.5
# export templates installed.
set -euo pipefail
GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/build/web}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "copying project (without the Epic plugin) to $TMP"
tar -C "$ROOT" -cf - --exclude=./.godot --exclude=./build --exclude=./_shots \
    --exclude=addons/epic-online-services-godot --exclude=eos_credentials.cfg \
    --exclude=./.git . | tar -C "$TMP" -xf -

python3 - "$TMP/project.godot" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# drop the EOSG autoloads and the enabled plugin
s = "\n".join(l for l in s.split("\n")
              if "addons/epic-online-services-godot" not in l)
s = re.sub(r"\n\[editor_plugins\]\n+(?=\[|\Z)", "\n", s)
open(p, "w", encoding="utf-8").write(s)
PY

echo "importing"
"$GODOT" --headless --editor --quit --path "$TMP" >/dev/null 2>&1 || true
mkdir -p "$OUT"
# keep Godot from importing build output as project assets
[ -d "$ROOT/build" ] && touch "$ROOT/build/.gdignore"
echo "exporting to $OUT"
"$GODOT" --headless --path "$TMP" --export-release "Web" "$OUT/index.html"
echo "done: $(du -sh "$OUT" | cut -f1) in $OUT"
