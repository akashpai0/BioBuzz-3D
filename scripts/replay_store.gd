class_name ReplayStore
extends RefCounted
##
## THE REPLAY COLLECTION ON DISK.
##
## Every recorded run is two files in ONE clearly identified folder:
##
##   r-20260922-140312-4821.bbreplay   the recording (ReplayFormat), append-only
##   r-20260922-140312-4821.json       the sidecar: title, favourite, tags and
##                                     the facts the library lists
##
## Filenames are unique ids and never change. Titles live INSIDE the sidecar,
## so two replays can share a title and renaming never touches, moves or
## overwrites a recording.
##
## THE COLLECTION HAS NO COUNT LIMIT. Nothing here deletes a recording except
## `delete()`, which only runs when the player confirms it. Disk space is the
## practical limit; running out stops the recording in progress (see
## ReplayRecorder) and never removes an older one to make room.
##
## `index.json` is a CACHE, nothing more: the library reads it so a folder of
## thousands of replays opens without touching each recording. Every entry is
## checked against the files' size and modification time and rebuilt from the
## sidecar — or, when the sidecar is gone, from the recording's own header and
## final chunk — whenever it does not match. Deleting index.json loses nothing.
##

const META_FORMAT := "biobuzz.replay.meta"
const META_VERSION := 1
const DEFAULT_DIR := "user://replays"
const CONFIG := "user://replay_settings.json"
const INDEX := "index.json"

## The id being written right now, so the library can say "recording" rather
## than "interrupted" for it.
static var active_id := ""

# =================================================================== folder ==

## The folder new recordings go to, as an absolute OS path. Read from the
## settings file once per process and then kept, so a second copy of the
## game (or a test) changing the setting cannot move this one's recordings
## mid-session.
static var _folder_cache := ""

static func folder() -> String:
	if _folder_cache != "":
		return _folder_cache
	var cfg := _config()
	var f := String(cfg.get("folder", ""))
	if f == "":
		f = ProjectSettings.globalize_path(DEFAULT_DIR)
	_folder_cache = f
	return f

## Forget the cached folder and read the setting again.
static func reload_folder() -> void:
	_folder_cache = ""

static func default_folder() -> String:
	return ProjectSettings.globalize_path(DEFAULT_DIR)

static func is_default_folder() -> bool:
	return folder() == default_folder()

## SWITCH to another folder. Nothing is moved: recordings in the old folder
## stay exactly where they are and appear again if you switch back.
static func set_folder(abs_path: String) -> String:
	var p := abs_path.strip_edges()
	if p == "":
		p = default_folder()
	if not DirAccess.dir_exists_absolute(p):
		var err := DirAccess.make_dir_recursive_absolute(p)
		if err != OK:
			return "That folder does not exist and could not be created."
	if not _writable(p):
		return "The game cannot write to that folder."
	var cfg := _config()
	cfg["folder"] = "" if p == default_folder() else p
	if not _write_json_atomic(CONFIG, cfg):
		return "The setting could not be saved."
	_folder_cache = p
	return ""

static func ensure_folder() -> bool:
	var f := folder()
	if not DirAccess.dir_exists_absolute(f):
		return DirAccess.make_dir_recursive_absolute(f) == OK
	return true

static func _writable(dir: String) -> bool:
	var probe := dir.path_join(".bb-write-test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.store_8(1)
	f.close()
	DirAccess.remove_absolute(probe)
	return true

static func _config() -> Dictionary:
	if not FileAccess.file_exists(CONFIG):
		return {}
	var v: Variant = parse_json(FileAccess.get_file_as_string(CONFIG))
	return v if v is Dictionary else {}

## A per-player convenience, not recorded data: which camera the viewer
## opened with last time.
static func camera_pref() -> String:
	return String(_config().get("camera", "overview"))

static func set_camera_pref(c: String) -> void:
	var cfg := _config()
	cfg["camera"] = c
	_write_json_atomic(CONFIG, cfg)

# ==================================================================== paths ==

## A private generator: the global one is re-seeded by every situation
## restore (so retries draw the same human placements), and taking numbers
## from it here would both repeat ids and change the game's randomness.
static var _rng: RandomNumberGenerator

static func new_id() -> String:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	var dt := Time.get_datetime_dict_from_system()
	var base := "r-%04d%02d%02d-%02d%02d%02d" % [dt["year"], dt["month"],
		dt["day"], dt["hour"], dt["minute"], dt["second"]]
	for _i in 50:
		var id := "%s-%04d" % [base, _rng.randi() % 10000]
		if not FileAccess.file_exists(recording_path(id)) \
				and not FileAccess.file_exists(meta_path(id)):
			return id
	return "%s-%d" % [base, Time.get_ticks_usec()]

static func recording_path(id: String, dir := "") -> String:
	return (folder() if dir == "" else dir).path_join(id + ReplayFormat.EXT)

static func meta_path(id: String, dir := "") -> String:
	return (folder() if dir == "" else dir).path_join(id + ".json")

# =================================================================== sidecar ==

## Parse without printing an engine error for a damaged file: a damaged
## sidecar is an expected state here, reported in the library, not a crash.
static func parse_json(text: String) -> Variant:
	var j := JSON.new()
	if j.parse(text) != OK:
		return null
	return j.data

static func read_meta(id: String, dir := "") -> Dictionary:
	var p := meta_path(id, dir)
	if not FileAccess.file_exists(p):
		# a rename that was interrupted between write and swap
		if FileAccess.file_exists(p + ".tmp"):
			var t: Variant = parse_json(FileAccess.get_file_as_string(p + ".tmp"))
			if t is Dictionary and String((t as Dictionary).get("format", "")) == META_FORMAT:
				return t
		return {}
	var v: Variant = parse_json(FileAccess.get_file_as_string(p))
	if not (v is Dictionary) or String((v as Dictionary).get("format", "")) != META_FORMAT:
		return {}
	return v

static func write_meta(id: String, meta: Dictionary, dir := "") -> bool:
	var m := meta.duplicate(true)
	m["format"] = META_FORMAT
	m["version"] = META_VERSION
	m["id"] = id
	return _write_json_atomic(meta_path(id, dir), m)

## Write to a temporary file, read it back, then swap it into place. A crash
## at any point leaves either the old file or the new one, never half of one.
static func _write_json_atomic(p: String, data: Dictionary) -> bool:
	var tmp := p + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	var ok := f.store_string(JSON.stringify(data, "\t"))
	f.close()
	if not ok:
		DirAccess.remove_absolute(tmp)
		return false
	var back: Variant = parse_json(FileAccess.get_file_as_string(tmp))
	if not (back is Dictionary):
		DirAccess.remove_absolute(tmp)
		return false
	if DirAccess.rename_absolute(tmp, p) == OK:
		return true
	# some platforms will not rename over an existing file
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	return DirAccess.rename_absolute(tmp, p) == OK

## Title, favourite, tags: the only things a player edits. Each is written on
## its own, atomically, and never touches the recording.
static func set_title(id: String, title: String) -> bool:
	var m := read_meta(id)
	if m.is_empty():
		m = _meta_from_recording(id)
		if m.is_empty():
			return false
	var t := title.strip_edges()
	if t == "":
		return false
	m["title"] = t.substr(0, 120)
	m["title_edited"] = true
	return write_meta(id, m)

static func set_favorite(id: String, on: bool) -> bool:
	var m := read_meta(id)
	if m.is_empty():
		m = _meta_from_recording(id)
		if m.is_empty():
			return false
	m["favorite"] = on
	return write_meta(id, m)

## Tags are short labels: trimmed, lower-cased, de-duplicated, at most 12.
static func clean_tags(raw: Variant) -> Array:
	var parts: Array = []
	if raw is String:
		parts = (raw as String).split(",", false)
	elif raw is Array:
		parts = raw
	var out: Array = []
	for p in parts:
		var t := String(p).strip_edges().to_lower().replace("#", "")
		t = t.substr(0, 24)
		if t != "" and not out.has(t):
			out.append(t)
		if out.size() >= 12:
			break
	return out

static func set_tags(id: String, tags: Variant) -> bool:
	var m := read_meta(id)
	if m.is_empty():
		m = _meta_from_recording(id)
		if m.is_empty():
			return false
	m["tags"] = clean_tags(tags)
	return write_meta(id, m)

# =================================================================== listing ==

## Every replay in the current folder, newest first, WITHOUT decoding any
## recording. Each entry is the sidecar's facts plus:
##   path, bytes (both files), health ("ok" | "recording" | "recovered" |
##   "damaged" | "missing" | "unsupported"), health_note, playable
static func list(dir := "") -> Array:
	var d := folder() if dir == "" else dir
	var out: Array = []
	if not DirAccess.dir_exists_absolute(d):
		return out
	var da := DirAccess.open(d)
	if da == null:
		return out
	var ids := {}
	for f in da.get_files():
		if f.ends_with(ReplayFormat.EXT):
			ids[f.trim_suffix(ReplayFormat.EXT)] = true
		elif f.ends_with(".json") and f != INDEX and f.begins_with("r-"):
			ids[f.trim_suffix(".json")] = true
	var cache := _read_index(d)
	var fresh := {}
	var dirty := false
	for id in ids.keys():
		var rp := recording_path(id, d)
		var mp := meta_path(id, d)
		var key := _stamp(rp) + "|" + _stamp(mp)
		var c: Variant = cache.get(id)
		var entry: Dictionary
		if c is Dictionary and String((c as Dictionary).get("_key", "")) == key \
				and id != active_id:
			entry = c
		else:
			entry = _build_entry(id, d)
			entry["_key"] = key
			dirty = true
		fresh[id] = entry
		out.append(entry)
	if dirty or fresh.size() != cache.size():
		_write_index(d, fresh)
	out.sort_custom(func(a, b) -> bool:
		return String(a.get("created", "")) > String(b.get("created", "")))
	return out

static func _stamp(p: String) -> String:
	if not FileAccess.file_exists(p):
		return "-"
	return "%d:%d" % [FileAccess.get_size(p), FileAccess.get_modified_time(p)]

## One library row from the files, reading only the sidecar — and, when the
## sidecar is missing or says the run never finished, the recording's chunk
## HEADERS (never its samples).
static func _build_entry(id: String, d: String) -> Dictionary:
	var rp := recording_path(id, d)
	var has_rec := FileAccess.file_exists(rp)
	var m := read_meta(id, d)
	var e := m.duplicate(true)
	e["id"] = id
	e["path"] = rp
	e["meta_path"] = meta_path(id, d)
	var rbytes := FileAccess.get_size(rp) if has_rec else 0
	var mbytes := FileAccess.get_size(meta_path(id, d)) \
		if FileAccess.file_exists(meta_path(id, d)) else 0
	e["bytes"] = rbytes + mbytes
	e["files"] = int(has_rec) + int(mbytes > 0)
	e["playable"] = false
	if not has_rec:
		e["health"] = "missing"
		e["health_note"] = "The recording file is missing; only its details remain."
		_defaults(e, id)
		return e
	if id == active_id:
		e["health"] = "recording"
		e["health_note"] = "Recording now."
		_defaults(e, id)
		return e
	var complete_by_meta := String(m.get("status", "")) == "complete" \
		and int(m.get("rec_bytes", -1)) == rbytes
	# The fast path trusts the sidecar about the CONTENTS, but still reads the
	# recording's 16-byte signature so a replaced or newer file is caught.
	var sig := ReplayFormat.peek_header(rp)
	if sig != "":
		e["health"] = "unsupported" if sig.contains("newer version") else "damaged"
		e["health_note"] = sig
		_defaults(e, id)
		return e
	if complete_by_meta:
		e["health"] = "ok"
		e["health_note"] = ""
		e["playable"] = true
		# an online recording that arrived with holes says so
		if String(m.get("coverage_note", "")) != "":
			e["health"] = "partial"
			e["health_note"] = "Partial: %s. The rest plays; the missing part shows as missing." % String(m["coverage_note"])
		_defaults(e, id)
		return e
	# The sidecar is missing, damaged, or says the run was still being
	# written. The recording itself is the authority: index its chunk headers.
	var s := ReplayFormat.scan(rp)
	if String(s["error"]) != "":
		e["health"] = "unsupported" if String(s["error"]).contains("newer version") else "damaged"
		e["health_note"] = String(s["error"])
		_defaults(e, id)
		return e
	if m.is_empty():
		e.merge(_meta_from_scan(id, s), true)
	var fin: Dictionary = s["final"]
	if bool(s["complete"]) and String(s["damaged"]) == "":
		e["health"] = "ok"
		e["health_note"] = ""
		for k in ["outcome", "outcome_label", "reason", "score", "duration"]:
			if fin.has(k):
				e[k] = fin[k]
	else:
		e["health"] = "recovered"
		var through := float(s["duration"])
		e["saved_through"] = through
		e["duration"] = through
		e["outcome"] = "incomplete"
		e["outcome_label"] = "Incomplete"
		var why := String(m.get("storage_note", ""))
		e["health_note"] = ("Recovered: the recording stopped before the run "
			+ "ended%s. Playable up to %s.") % [
			(" (" + why + ")") if why != "" else "", _clock(through)]
		if String(s["damaged"]) != "" and bool(s["complete"]):
			e["health_note"] = "%s Playable up to %s." % [String(s["damaged"]), _clock(through)]
	e["playable"] = _has_playable(s)
	_defaults(e, id)
	return e

static func _has_playable(s: Dictionary) -> bool:
	var samples := false
	var cp := false
	for c in s["chunks"]:
		if int(c["type"]) == ReplayFormat.Chunk.SAMPLES:
			samples = true
		elif int(c["type"]) == ReplayFormat.Chunk.CHECKPOINT:
			cp = true
	return samples and cp

static func _defaults(e: Dictionary, id: String) -> void:
	var d := {"title": id, "favorite": false, "tags": [], "created": "",
		"created_local": "", "mode_name": "—", "kind": "", "scenario_name": "",
		"outcome": "", "outcome_label": "—", "duration": 0.0, "score": {}}
	for k in d:
		if not e.has(k):
			e[k] = d[k]

## Rebuild a sidecar's facts from the recording alone.
static func _meta_from_scan(id: String, s: Dictionary) -> Dictionary:
	var h: Dictionary = s["header"]
	var m := {}
	for k in ["title", "created", "created_local", "mode", "mode_name", "kind",
			"scenario_id", "scenario_name", "our_alliance"]:
		if h.has(k):
			m[k] = h[k]
	m["duration"] = float(s["duration"])
	if not m.has("title"):
		m["title"] = id
	return m

static func _meta_from_recording(id: String) -> Dictionary:
	var s := ReplayFormat.scan(recording_path(id))
	if String(s["error"]) != "":
		return {}
	var m := _meta_from_scan(id, s)
	var fin: Dictionary = s["final"]
	for k in ["outcome", "outcome_label", "reason", "score", "duration"]:
		if fin.has(k):
			m[k] = fin[k]
	m["status"] = "complete" if bool(s["complete"]) else "incomplete"
	m["rec_bytes"] = int(s["bytes"])
	return m

static func _read_index(d: String) -> Dictionary:
	var p := d.path_join(INDEX)
	if not FileAccess.file_exists(p):
		return {}
	var v: Variant = parse_json(FileAccess.get_file_as_string(p))
	if not (v is Dictionary) or int((v as Dictionary).get("version", 0)) != 1:
		return {}
	var entries: Variant = (v as Dictionary).get("entries", {})
	return entries if entries is Dictionary else {}

static func _write_index(d: String, entries: Dictionary) -> void:
	_write_json_atomic(d.path_join(INDEX), {"version": 1,
		"note": "Cache only. Safe to delete: it is rebuilt from the replay files.",
		"entries": entries})

## Throw the cache away and read every sidecar again.
static func rebuild_index(dir := "") -> Array:
	var d := folder() if dir == "" else dir
	var p := d.path_join(INDEX)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	return list(d)

# ==================================================================== totals ==

static func usage(entries: Array) -> Dictionary:
	var b := 0
	var files := 0
	for e in entries:
		b += int(e.get("bytes", 0))
		files += int(e.get("files", 0))
	return {"bytes": b, "files": files, "replays": entries.size()}

static func latest(entries: Array = []) -> Dictionary:
	var list_ := entries if not entries.is_empty() else list()
	for e in list_:
		if bool(e.get("playable", false)):
			return e
	return {}

# =================================================================== delete ==

## Remove replays the player chose, both files each. Returns
## {deleted, files, bytes, failed: [ids]}. Situations saved from a replay are
## separate files in the situation library and are never touched.
static func delete(ids: Array, dir := "") -> Dictionary:
	var d := folder() if dir == "" else dir
	var out := {"deleted": 0, "files": 0, "bytes": 0, "failed": []}
	for id in ids:
		var sid := String(id)
		if sid == active_id:
			(out["failed"] as Array).append(sid)
			continue
		var gone := true
		for p in [recording_path(sid, d), meta_path(sid, d), meta_path(sid, d) + ".tmp"]:
			if FileAccess.file_exists(p):
				var sz := FileAccess.get_size(p)
				if DirAccess.remove_absolute(p) == OK:
					out["files"] = int(out["files"]) + 1
					out["bytes"] = int(out["bytes"]) + sz
				else:
					gone = false
		if gone:
			out["deleted"] = int(out["deleted"]) + 1
		else:
			(out["failed"] as Array).append(sid)
	list(d)            # refresh the cache
	return out

# ===================================================================== move ==

## MOVE every replay from the current folder into `dest`, then switch to it.
## Copy, verify the size, and only then remove the original — a replay that
## fails to copy stays where it was, and the result says so.
static func move_all(dest: String) -> Dictionary:
	var src := folder()
	var out := {"moved": 0, "failed": [], "error": ""}
	if dest.strip_edges() == "" or dest == src:
		out["error"] = "That is already the replay folder."
		return out
	if active_id != "":
		out["error"] = "A run is being recorded. Finish it before moving replays."
		return out
	if not DirAccess.dir_exists_absolute(dest) \
			and DirAccess.make_dir_recursive_absolute(dest) != OK:
		out["error"] = "That folder could not be created."
		return out
	if not _writable(dest):
		out["error"] = "The game cannot write to that folder."
		return out
	for e in list(src):
		var id := String(e["id"])
		var ok := true
		var copied: Array = []
		for pair in [[recording_path(id, src), recording_path(id, dest)],
				[meta_path(id, src), meta_path(id, dest)]]:
			if not FileAccess.file_exists(pair[0]):
				continue
			if FileAccess.file_exists(pair[1]):
				ok = false               # never overwrite something already there
				break
			if DirAccess.copy_absolute(pair[0], pair[1]) != OK \
					or FileAccess.get_size(pair[1]) != FileAccess.get_size(pair[0]):
				ok = false
				break
			copied.append(pair)
		if ok:
			for pair2 in copied:
				DirAccess.remove_absolute(pair2[0])
			out["moved"] = int(out["moved"]) + 1
		else:
			for pair3 in copied:
				DirAccess.remove_absolute(pair3[1])   # undo the partial copy
			(out["failed"] as Array).append(id)
	var src_index := src.path_join(INDEX)
	if (out["failed"] as Array).is_empty() and FileAccess.file_exists(src_index):
		DirAccess.remove_absolute(src_index)
	out["error"] = set_folder(dest)
	return out

# =================================================================== format ==

static func _clock(t: float) -> String:
	return "%d:%02d" % [int(t) / 60, int(t) % 60]

static func size_text(b: int) -> String:
	if b < 1024:
		return "%d B" % b
	if b < 1024 * 1024:
		return "%.0f KB" % (float(b) / 1024.0)
	if b < 1024 * 1024 * 1024:
		return "%.1f MB" % (float(b) / 1048576.0)
	return "%.2f GB" % (float(b) / 1073741824.0)
