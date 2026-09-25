class_name Leaderboard
extends RefCounted
##
## Local high scores, kept in `user://` so they survive between sessions.
##
## Scores are held per ROBOT VARIANT, because a one-intake and a two-intake run
## are not really the same contest — the board shows them as two separate tables.
## Only a player's BEST run per variant is kept.
##
## SHARING: there is no server behind this, so scores do not sync by themselves.
## What it does instead is export the whole board as a share code — one line of
## text you can send to anyone else who has the game — and import one back,
## merging their runs into yours. See `to_code()` / `merge_code()`.
##

const PROFILE_PATH := "user://profile.cfg"
const BOARD_PATH := "user://leaderboard.json"
const MAX_ROWS := 12

# ------------------------------------------------------------------ profile

static func player_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PROFILE_PATH) != OK:
		return ""
	return str(cfg.get_value("player", "name", ""))

static func set_player_name(n: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PROFILE_PATH)
	cfg.set_value("player", "name", n.strip_edges().substr(0, 18))
	cfg.save(PROFILE_PATH)

static func signed_in() -> bool:
	return player_name() != ""

# --------------------------------------------------------------- the board

static func load_all() -> Array:
	if not FileAccess.file_exists(BOARD_PATH):
		return []
	var f := FileAccess.open(BOARD_PATH, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Array else []

static func save_all(rows: Array) -> void:
	var f := FileAccess.open(BOARD_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rows))

## Record a run. Keeps only the player's best per variant.
static func submit(name: String, points: int, intakes: int, mode: String) -> void:
	if name == "":
		return
	var rows := load_all()
	var found := false
	for r in rows:
		if str(r.get("name", "")) == name and int(r.get("intakes", 1)) == intakes:
			found = true
			if points > int(r.get("points", 0)):
				r["points"] = points
				r["mode"] = mode
				r["when"] = Time.get_datetime_string_from_system(true, true)
			break
	if not found:
		rows.append({
			"name": name, "points": points, "intakes": intakes, "mode": mode,
			"when": Time.get_datetime_string_from_system(true, true),
		})
	save_all(rows)

## Rows for one variant, best first.
static func table(intakes: int) -> Array:
	var out: Array = []
	for r in load_all():
		if int(r.get("intakes", 1)) == intakes:
			out.append(r)
	out.sort_custom(func(a, b): return int(a.get("points", 0)) > int(b.get("points", 0)))
	return out.slice(0, MAX_ROWS)

# --------------------------------------------------------------- sharing

## The whole board as one line of text, safe to paste into a message.
static func to_code() -> String:
	return Marshalls.utf8_to_base64(JSON.stringify(load_all()))

## Merge someone else's share code in. Their runs are added; where you both
## have a run for the same name and variant, the higher score wins. Returns how
## many rows were added or improved, or -1 if the code could not be read.
static func merge_code(code: String) -> int:
	var raw := Marshalls.base64_to_utf8(code.strip_edges())
	if raw == "":
		return -1
	var incoming: Variant = JSON.parse_string(raw)
	if not (incoming is Array):
		return -1
	var rows := load_all()
	var changed := 0
	for inc in incoming:
		if not (inc is Dictionary) or not inc.has("name"):
			continue
		var hit := false
		for r in rows:
			if str(r.get("name", "")) == str(inc.get("name", "")) \
					and int(r.get("intakes", 1)) == int(inc.get("intakes", 1)):
				hit = true
				if int(inc.get("points", 0)) > int(r.get("points", 0)):
					r["points"] = int(inc.get("points", 0))
					r["mode"] = str(inc.get("mode", ""))
					r["when"] = str(inc.get("when", ""))
					changed += 1
				break
		if not hit:
			rows.append(inc)
			changed += 1
	save_all(rows)
	return changed
