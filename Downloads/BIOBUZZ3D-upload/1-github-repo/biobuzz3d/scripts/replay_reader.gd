class_name ReplayReader
extends RefCounted
##
## READS A RECORDING WITHOUT LOADING IT.
##
## Opening indexes chunk headers (ReplayFormat.scan) and reads the small
## EVENTS chunks. Sample blocks are decoded only when the playhead needs them
## and kept in a small most-recently-used cache, so seeking anywhere in an
## hour-long free practice costs one block decode — about a second of data —
## not the whole file. Checkpoints are decoded only when "Practise from here"
## asks for one.
##
## Everything here is READ-ONLY. Nothing writes to the recording, its sidecar
## or anything the game scores.
##

const CACHE_BLOCKS := 12

var path := ""
var id := ""
var error := ""
var header: Dictionary = {}
var final: Dictionary = {}
var complete := false
var damaged := ""
var duration := 0.0
var bytes := 0
var rate := 30.0
var stride := 0
var head := 8
var per_robot := 12
var per_hive := 7
var per_element := 8
var n_robots := 0
var n_hives := 0
var n_elements := 0
var blocks: Array = []
var checkpoints: Array = []
var events: Array = []
## Blocks that failed to decode, by index into `blocks`.
var bad_blocks := {}

var _f: FileAccess
var _cache := {}
var _lru: Array = []

func open(p: String) -> String:
	path = p
	id = p.get_file().get_basename()
	var s := ReplayFormat.scan(p)
	bytes = int(s["bytes"])
	if String(s["error"]) != "":
		error = String(s["error"])
		return error
	header = s["header"]
	final = s["final"]
	complete = bool(s["complete"])
	damaged = String(s["damaged"])
	rate = float(header.get("rate_hz", 30))
	var lay: Dictionary = header.get("layout", {})
	head = int(lay.get("head", 8))
	per_robot = int(lay.get("robot", 12))
	per_hive = int(lay.get("hive", 7))
	per_element = int(lay.get("element", 8))
	stride = int(lay.get("stride", 0))
	n_robots = (header.get("robots", []) as Array).size()
	n_hives = (header.get("hives", []) as Array).size()
	n_elements = (header.get("elements", []) as Array).size()
	if stride != head + per_robot * n_robots + per_hive * n_hives \
			+ per_element * n_elements or stride <= 0:
		error = "The recording's layout does not match its header."
		return error
	_f = FileAccess.open(p, FileAccess.READ)
	if _f == null:
		error = "The recording file could not be opened."
		return error
	for c in s["chunks"]:
		match int(c["type"]):
			ReplayFormat.Chunk.SAMPLES:
				blocks.append(c)
			ReplayFormat.Chunk.CHECKPOINT:
				checkpoints.append(c)
			ReplayFormat.Chunk.EVENTS:
				var evs: Variant = ReplayFormat.read_json(_f, c)
				if evs is Array:
					for ev in evs:
						if ev is Dictionary:
							events.append(ev)
	blocks.sort_custom(func(a, b) -> bool: return float(a["t0"]) < float(b["t0"]))
	checkpoints.sort_custom(func(a, b) -> bool: return float(a["t0"]) < float(b["t0"]))
	var seen := {}
	var uniq: Array = []
	for ev2 in events:
		var eid := String(ev2.get("id", ""))
		if seen.has(eid):
			continue
		seen[eid] = true
		uniq.append(ev2)
	uniq.sort_custom(func(a, b) -> bool:
		if float(a["t"]) == float(b["t"]):
			return String(a["id"]) < String(b["id"])
		return float(a["t"]) < float(b["t"]))
	events = uniq
	if blocks.is_empty():
		error = "The recording has no playable footage."
		return error
	if checkpoints.is_empty():
		error = "The recording has no restorable checkpoint."
		return error
	duration = float(blocks[-1]["t1"])
	return ""

func close() -> void:
	if _f != null:
		_f.close()
		_f = null
	_cache.clear()
	_lru.clear()

func sample_count() -> int:
	return int(round(duration * rate)) + 1

func title() -> String:
	return String(header.get("title", id))

# ================================================================ samples ===

## Which block holds sample `s`, or -1.
func _block_of(s: int) -> int:
	var t := float(s) / rate
	var lo := 0
	var hi := blocks.size() - 1
	while lo <= hi:
		var mid := (lo + hi) / 2
		var b: Dictionary = blocks[mid]
		if t < float(b["t0"]) - 0.0001:
			hi = mid - 1
		elif t > float(b["t1"]) + 0.0001:
			lo = mid + 1
		else:
			return mid
	return -1

func _decoded(bi: int) -> Array:
	if _cache.has(bi):
		_lru.erase(bi)
		_lru.append(bi)
		return _cache[bi]
	if bad_blocks.has(bi) or _f == null:
		return []
	var d := ReplayFormat.read_samples(_f, blocks[bi])
	if d.is_empty() or int((d[0] as Dictionary).get("stride", -1)) != stride:
		bad_blocks[bi] = true
		return []
	_cache[bi] = d
	_lru.append(bi)
	while _lru.size() > CACHE_BLOCKS:
		_cache.erase(_lru.pop_front())
	return d

## The floats of sample `s` as [PackedFloat32Array, offset], or [] when that
## part of the recording is missing or damaged.
func sample(s: int) -> Array:
	var bi := _block_of(s)
	if bi < 0:
		return []
	var d := _decoded(bi)
	if d.is_empty():
		return []
	var meta: Dictionary = d[0]
	var local := s - int(meta.get("i0", 0))
	if local < 0 or local >= int(meta.get("n", 0)):
		return []
	return [d[1], local * stride]

## An opponent's status line as it was at sample `s`.
func status_at(s: int, robot: int) -> String:
	var bi := _block_of(s)
	if bi < 0:
		return ""
	var d := _decoded(bi)
	if d.is_empty():
		return ""
	var meta: Dictionary = d[0]
	var local := s - int(meta.get("i0", 0))
	var st: Dictionary = meta.get("status0", {})
	var out := String(st.get(robot, ""))
	for ch in meta.get("status", []):
		if int(ch[0]) <= local and int(ch[1]) == robot:
			out = String(ch[2])
	return out

# ============================================================ checkpoints ===

func checkpoint_times() -> Array:
	var out: Array = []
	for c in checkpoints:
		out.append(float(c["t0"]))
	return out

## The checkpoint nearest `t`; ties go to the EARLIER one, so the player is
## never moved past the moment they picked.
func nearest_checkpoint(t: float) -> int:
	var best := 0
	var bd := INF
	for i in checkpoints.size():
		var d := absf(float(checkpoints[i]["t0"]) - t)
		if d < bd - 0.0001:
			bd = d
			best = i
	return best

## The complete snapshot stored at checkpoint `i`, or {} if it is damaged.
func checkpoint(i: int) -> Dictionary:
	if i < 0 or i >= checkpoints.size() or _f == null:
		return {}
	var v: Variant = ReplayFormat.read_json(_f, checkpoints[i])
	if not (v is Dictionary) or Snapshot.validate(v) != "":
		return {}
	return v
