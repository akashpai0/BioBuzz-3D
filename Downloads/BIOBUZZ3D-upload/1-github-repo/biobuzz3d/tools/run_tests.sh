#!/usr/bin/env bash
# Runs the BIOBUZZ 3D test harnesses headless and prints one line per test.
#
#   tools/run_tests.sh            quick set (about 10 minutes)
#   tools/run_tests.sh full       everything (about 45 minutes)
#
# Every test runs with its OWN throwaway profile folder (the tests create and
# delete replays, scenarios and settings), so your real saves are never
# touched. Needs Godot 4.5 on PATH as `godot` (or GODOT=/path/to/godot).
# Linux / macOS / Git Bash. Tests that render (UI, CAD) need a display; on a
# headless Linux box they run under xvfb-run if it is installed.
set -uo pipefail
GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
LOGS="$ROOT/build/test-logs"
mkdir -p "$LOGS"; touch "$ROOT/build/.gdignore"
PASS=0; FAIL=0

run() {   # run <name> [args...]   headless
  local name="$1"; shift
  local prof="$TMP/$name$*"; mkdir -p "$prof"
  local log="$LOGS/${name}${*// /_}.log"
  XDG_DATA_HOME="$prof" APPDATA="$prof" timeout 900 "$GODOT" --headless --path "$ROOT" \
    "tools/$name.tscn" "$@" > "$log" 2>&1
  report $? "$name $*"
}
run_shared() {   # write/read pairs share one profile
  local name="$1" phase="$2"
  local prof="$TMP/$name"; mkdir -p "$prof"
  XDG_DATA_HOME="$prof" APPDATA="$prof" timeout 900 "$GODOT" --headless --path "$ROOT" \
    "tools/$name.tscn" -- "$phase" > "$LOGS/${name}_$phase.log" 2>&1
  report $? "$name $phase"
}
run_render() {   # run_render <name> <w> <h> [args...]   needs a display
  local name="$1" w="$2" h="$3"; shift 3
  local prof="$TMP/r$name$w"; mkdir -p "$prof"
  local wrap=()
  if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null; then
    wrap=(xvfb-run -a -s "-screen 0 $((w + 64))x$((h + 64))x24")
  fi
  XDG_DATA_HOME="$prof" APPDATA="$prof" timeout 1500 "${wrap[@]}" "$GODOT" --path "$ROOT" \
    --resolution "${w}x${h}" "tools/$name.tscn" "$@" > "$LOGS/${name}_${w}.log" 2>&1
  report $? "$name ${w}x${h}"
}
report() {
  if [ "$1" = 0 ]; then PASS=$((PASS + 1)); echo "  ok    $2"
  else FAIL=$((FAIL + 1)); echo "  FAIL  $2   (exit $1, see build/test-logs)"; fi
}

echo "compile check"; run _chk
echo "menus and practice";  run debug_menus; run debug_editor; run debug_pause
run debug_workflow -- walk; run_shared debug_replay write; run_shared debug_replay read
echo "online (local + simulated Epic)"; run debug_net_link; run debug_net_smoke
run debug_net_2proc; run debug_net_eos_sim
echo "gameplay"; run smoke_match; run debug_drive; run debug_rules
echo "screens"; run_render debug_ui_repairs 1920 1080 -- 1920 1080; run_render shot_all 1280 720

if [ "${1:-}" = "full" ]; then
  echo "full set"
  run debug_net_client; run_shared debug_net write; run_shared debug_net read
  for t in objectives situations input opponents; do
    run_shared "debug_$t" write; run_shared "debug_$t" read
  done
  for t in debug_roster debug_coop debug_human debug_report debug_leaderboard debug_solid \
      debug_audio debug_power debug_yaw debug_opponent debug_calibrate tip_time \
      debug_flower_retrieve debug_flower_stick debug_intake_bounds debug_shooting \
      debug_moving_shot debug_turret debug_blue debug_ride; do run "$t"; done
  run_render debug_ui_repairs 1280 720 -- 1280 720
  run_render debug_ui_repairs 2560 1440 -- 2560 1440
  run_render shot_all 2560 1440
fi
rm -rf "$TMP"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
