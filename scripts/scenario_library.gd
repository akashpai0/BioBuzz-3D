class_name ScenarioLibrary
extends RefCounted
##
## WHERE SAVED SITUATIONS LIVE.
##
## One JSON file per situation under `user://situations/`, each carrying its
## own metadata, so the library is just the folder listing — there is no index
## file to fall out of step with what is actually on disk.
##
## WRITES ARE SAFE. Every save goes to a temporary file, is read back and
## parsed, and only then replaces the real one. A save interrupted halfway
## leaves the previous situation intact rather than a truncated file where a
## situation used to be.
##
## READS NEVER CRASH. A file that is not JSON, not a situation, or from a newer
## version comes back as an error string the library shows, and the rest of the
## shelf still lists.
##

const DIR := "user://situations"

static func ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		DirAccess.make_dir_recursive_absolute(DIR)

static func path_for(id: String) -> String:
	return "%s/%s.json" % [DIR, id]

## A fresh id. Time-ordered so the folder sorts the way the shelf reads, with a
## random tail so two saves in the same second cannot collide.
static func new_id() -> String:
	return "sit-%s-%04d" % [
		Time.get_datetime_string_from_system(true).replace(":", "").replace("-", ""),
		randi() % 10000]

# -------------------------------------------------------------------- read --

## Every situation on the shelf, newest first. Unreadable files are listed with
## their problem rather than hidden, so a corrupt file is something you can see
## and delete instead of a situation that silently vanished.
static func list_all() -> Array:
	ensure_dir()
	var out: Array = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var id := f.trim_suffix(".json")
		var entry := load_one(id)
		out.append(entry)
	out.sort_custom(func(a, b) -> bool:
		return String(a.get("updated", "")) > String(b.get("updated", "")))
	return out

## One situation, as {id, name, note, created, updated, data, error}.
## `data` is empty and `error` is set when the file cannot be used.
static func load_one(id: String) -> Dictionary:
	var p := path_for(id)
	var base := {"id": id, "name": id, "note": "", "created": "", "updated": "",
		"data": {}, "error": ""}
	if not FileAccess.file_exists(p):
		base["error"] = "That situation file is gone."
		return base
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		base["error"] = "That situation file could not be opened."
		return base
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		base["error"] = "That situation file is damaged."
		return base
	var err := Snapshot.validate(parsed)
	if err != "":
		base["error"] = err
		return base
	var data: Dictionary = parsed
	var meta: Dictionary = data.get("meta", {})
	base["name"] = String(meta.get("name", id))
	base["note"] = String(meta.get("note", ""))
	base["created"] = String(meta.get("created", ""))
	base["updated"] = String(meta.get("updated", base["created"]))
	base["data"] = data
	return base

# ------------------------------------------------------------------- write --

## Save a snapshot. With no `id` this makes a NEW situation; with one it
## overwrites that situation in place, keeping its created date.
## Returns the id, or "" if the write failed.
static func save(snapshot: Dictionary, name: String, note: String,
		id := "") -> String:
	ensure_dir()
	var now := Time.get_datetime_string_from_system(true)
	var created := now
	if id != "":
		var existing := load_one(id)
		if existing["error"] == "":
			created = String(existing["created"])
	else:
		id = new_id()
	var data := snapshot.duplicate(true)
	data["meta"] = {
		"id": id, "name": name.strip_edges(), "note": note.strip_edges(),
		"created": created, "updated": now,
	}
	return id if _write_atomic(path_for(id), data) else ""

## Write, read back, then swap. The real file is only replaced once a complete
## and parseable one exists beside it.
static func _write_atomic(p: String, data: Dictionary) -> bool:
	var tmp := p + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	var check := FileAccess.open(tmp, FileAccess.READ)
	if check == null:
		return false
	var round_trip: Variant = JSON.parse_string(check.get_as_text())
	check.close()
	if not (round_trip is Dictionary) or Snapshot.validate(round_trip) != "":
		DirAccess.remove_absolute(tmp)
		return false
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	return DirAccess.rename_absolute(tmp, p) == OK

static func rename_to(id: String, name: String) -> bool:
	var entry := load_one(id)
	if entry["error"] != "":
		return false
	var data: Dictionary = entry["data"]
	var meta: Dictionary = data.get("meta", {})
	meta["name"] = name.strip_edges()
	meta["updated"] = Time.get_datetime_string_from_system(true)
	data["meta"] = meta
	return _write_atomic(path_for(id), data)

static func set_note(id: String, note: String) -> bool:
	var entry := load_one(id)
	if entry["error"] != "":
		return false
	var data: Dictionary = entry["data"]
	var meta: Dictionary = data.get("meta", {})
	meta["note"] = note.strip_edges()
	meta["updated"] = Time.get_datetime_string_from_system(true)
	data["meta"] = meta
	return _write_atomic(path_for(id), data)

## A copy to experiment on, so the original run stays as it was.
static func duplicate_one(id: String) -> String:
	var entry := load_one(id)
	if entry["error"] != "":
		return ""
	return save(entry["data"], _copy_name(String(entry["name"])),
		String(entry["note"]))

static func _copy_name(n: String) -> String:
	return n if n.ends_with(" copy") else n + " copy"

static func delete_one(id: String) -> bool:
	var p := path_for(id)
	if not FileAccess.file_exists(p):
		return false
	return DirAccess.remove_absolute(p) == OK

static func count() -> int:
	ensure_dir()
	var dir := DirAccess.open(DIR)
	if dir == null:
		return 0
	var n := 0
	for f in dir.get_files():
		if f.ends_with(".json"):
			n += 1
	return n
