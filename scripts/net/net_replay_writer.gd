class_name NetReplayWriter
extends RefCounted
##
## KEEPS AN ONLINE RUN IN THIS PLAYER'S OWN REPLAY COLLECTION.
##
## The room records its authoritative state with the ordinary recorder and
## streams each finished chunk to every player (reliably, in order). This
## writes those chunks, byte for byte, into a normal .bbreplay file here —
## so an online replay plays, lists, renames and branches exactly like an
## offline one, and "Practise from here" works later with no network at all.
##
## Every chunk is checked before it is written (NetReplayFormat check_chunk):
## a chunk that does not verify is not written and counts as a gap.
##
## COVERAGE IS TOLD, NEVER ASSUMED. A recording that missed its beginning,
## skipped chunks, or never received its final chunk is labelled so in the
## library ("Online · missing 3 blocks", "Incomplete"), and branching only
## ever uses checkpoints that arrived whole.
##
## A disk failure here stops this player's copy and says so; the online
## session carries on.
##

var run := -1
var next := 0
var id := ""
var path := ""
var gaps := 0
var bad := 0
var complete := false
var failed := false
var header: Dictionary = {}
var note := ""
var _f: FileAccess
## Tests: behave as if the disk refused the next write.
var debug_fail := false

## Returns a sentence for the player when something went wrong, else "".
func on_chunk(run_id: int, index: int, bytes: PackedByteArray) -> String:
	if run_id != run:
		finish("A new run started before this one's end arrived.")
		run = run_id
		next = 0
		gaps = 0
		bad = 0
		complete = false
		failed = false
		header = {}
		note = ""
	if failed or complete:
		return ""
	if index < next:
		return ""                             # a resend we already have
	var why := ReplayFormat.check_chunk(bytes)
	if why != "":
		bad += 1
		return ""
	var type := bytes.decode_u8(4)
	if _f == null:
		if type != ReplayFormat.Chunk.HEADER:
			return ""                         # nothing to write until the header
		var raw := bytes.slice(ReplayFormat.CHUNK_HEADER_BYTES).decompress(
			bytes.decode_u32(24), FileAccess.COMPRESSION_ZSTD)
		var h: Variant = ReplayStore.parse_json(raw.get_string_from_utf8())
		if not (h is Dictionary):
			bad += 1
			return ""
		header = h
		if not ReplayStore.ensure_folder():
			failed = true
			return "Could not save this online run locally: the replay folder cannot be created."
		id = ReplayStore.new_id()
		path = ReplayStore.recording_path(id)
		_f = FileAccess.open(path, FileAccess.WRITE)
		if _f == null or not ReplayFormat.write_file_header(_f):
			failed = true
			_f = null
			return "Could not save this online run locally: the replay folder is not writable. The session carries on."
		ReplayStore.active_id = id
		if index > 0:
			gaps += index
		_write_meta("recording")
	elif index > next:
		gaps += index - next
	if debug_fail or ReplayFormat.write_encoded(_f, bytes) < 0:
		return _fail("the disk refused to write" + (" (simulated)" if debug_fail else ""))
	_f.flush()
	next = index + 1
	if type == ReplayFormat.Chunk.FINAL:
		complete = true
		var raw2 := bytes.slice(ReplayFormat.CHUNK_HEADER_BYTES).decompress(
			bytes.decode_u32(24), FileAccess.COMPRESSION_ZSTD)
		var fin: Variant = ReplayStore.parse_json(raw2.get_string_from_utf8())
		_close()
		_write_meta("complete", fin if fin is Dictionary else {})
	return ""

func _fail(why: String) -> String:
	failed = true
	_close()
	var through := _saved_through()
	_write_meta("incomplete", {}, why)
	return ("Your local copy of this online run stopped (%s); it is saved up to "
		% why) + "%d:%02d. The session carries on." % [int(through) / 60, int(through) % 60]

## The run ended without its final chunk reaching us (left, disconnected,
## room closed). Keep what arrived, labelled incomplete.
func finish(why: String) -> void:
	if _f == null:
		return
	_close()
	_write_meta("incomplete", {}, why)

func _close() -> void:
	if _f != null:
		_f.flush()
		_f.close()
		_f = null
	if ReplayStore.active_id == id:
		ReplayStore.active_id = ""

func _saved_through() -> float:
	if path == "" or not FileAccess.file_exists(path):
		return 0.0
	return float(ReplayFormat.scan(path).get("duration", 0.0))

func _write_meta(status: String, fin: Dictionary = {}, why := "") -> void:
	if id == "":
		return
	var online: Dictionary = header.get("online", {}) if header.get("online") is Dictionary else {}
	var m := ReplayStore.read_meta(id)
	if m.is_empty():
		var now := Time.get_datetime_dict_from_system()
		m = {"title": String(header.get("title", "Online practice")), "title_edited": false,
			"favorite": false, "tags": ["online"],
			"created": Time.get_datetime_string_from_system(true),
			"created_local": "%04d-%02d-%02d %02d:%02d" % [now["year"], now["month"],
				now["day"], now["hour"], now["minute"]],
			"mode": int(header.get("mode", 0)), "mode_name": "Online practice",
			"kind": "online", "scenario_id": "",
			"scenario_name": String(header.get("scenario_name", "")),
			"our_alliance": int(header.get("our_alliance", 0)),
			"online": online}
	m["status"] = status
	if status == "complete":
		for k in fin:
			m[k] = fin[k]
		m["rec_bytes"] = FileAccess.get_size(path) if FileAccess.file_exists(path) else 0
	elif status == "incomplete":
		var through := _saved_through()
		m["outcome"] = "incomplete"
		m["outcome_label"] = "Incomplete"
		m["saved_through"] = through
		m["duration"] = through
		m["storage_note"] = why
	var cov := ""
	if gaps > 0 or bad > 0:
		cov = "%d block%s of this online run never arrived here" % [gaps + bad,
			"" if gaps + bad == 1 else "s"]
	m["coverage_note"] = cov
	ReplayStore.write_meta(id, m)
