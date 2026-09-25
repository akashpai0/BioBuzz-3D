class_name NetRole
extends RefCounted
##
## WHAT THIS PROCESS IS, AND THE NUMBERS EVERY SIDE MUST AGREE ON.
##
## There is one kind of process: the game. Any player's game can host a room
## (its world becomes the room's simulation) or join one. There is no server
## to rent or run.
##
## Command-line user arguments (after `--`), read once by boot.gd:
##   --host-test --port N [--owner NAME] [--invite-file P]   tests only
##   --net-sim ms,jitter,loss     simulate a bad connection at this end
##   --grace S                    reconnection allowance (tests use short ones)
##   --reconnect-window S         how long a guest keeps trying to get back
##   --load-report                the room prints its load every 5 s
##

## 2: player-hosted rooms (invite secret instead of broker tickets)
const PROTO := 2
## Shown to people; not used for the compatibility decision.
const GAME_VERSION := "2026.09.23-hosted-1"
const MAX_PARTICIPANTS := 8

static var mode := "client"
static var args: Dictionary = {}

## True in the headless test host (no sign-in prompt, no starter drills).
static var is_server := false

## The compatibility key. Two builds may only share a room when every one of
## these matches: the wire protocol, the rules revision the simulation scores
## by, the situation (snapshot) format the scenario travels in and the replay
## format the recording is streamed in.
static func compat() -> String:
	return "p%d-r%d-s%d-f%d-t%d" % [PROTO, BB.RULES_REV, Snapshot.VERSION,
		ReplayFormat.VERSION, int(ProjectSettings.get_setting(
			"physics/common/physics_ticks_per_second", 180))]

static func parse(user_args: PackedStringArray) -> void:
	args = {}
	var i := 0
	while i < user_args.size():
		var a := String(user_args[i])
		match a:
			"--host-test":
				mode = "host-test"
				is_server = true
			"--port", "--owner", "--invite-file", "--net-sim", "--log", "--grace", \
					"--reconnect-window", "--demo", "--code-file":
				if i + 1 < user_args.size():
					args[a.substr(2)] = String(user_args[i + 1])
					i += 1
			_:
				if a.begins_with("--"):
					args[a.substr(2)] = true
		i += 1

static func arg(key: String, fallback: Variant = "") -> Variant:
	return args.get(key, fallback)

## "host:port" -> [host, port]
static func split_address(s: String, default_port := 0) -> Array:
	var t := s.strip_edges()
	if t == "":
		return ["", default_port]
	var i := t.rfind(":")
	if i > 0 and t.substr(i + 1).is_valid_int():
		return [t.substr(0, i), clampi(int(t.substr(i + 1)), 1, 65535)]
	return [t, default_port]
