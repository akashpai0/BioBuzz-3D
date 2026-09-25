class_name ReplayRecorder
extends Node
##
## RECORDS EVERY RUN, AS IT HAPPENS, STRAIGHT TO DISK.
##
## WHAT IS RECORDED — authoritative state, never inputs:
##
##   SAMPLES at 30 Hz (every 6th tick of the 180 Hz physics). Each sample is
##   one flat row of float32:
##     head     t, match time_left, phase, red score, blue score,
##              fouls against red, fouls against blue, flags
##     robot×R  position, rotation quaternion, turret yaw, hood angle,
##              hopper count, enabled, battery volts
##     hive×H   swing position, rotation quaternion
##     elem×E   position, rotation quaternion, holder
##              (-1 loose, -2 with a human / out of play, r = robot r's hopper)
##   Thirty samples make a BLOCK (one second), written as one chunk. Opponent
##   status lines ride along with each block as "changed at sample i" entries.
##
##   CHECKPOINTS every second, on the same tick as a sample: a complete
##   Snapshot.capture() — the exact data a saved situation holds, AI runtime
##   state included. "Practise from here" restores one of these; nothing is
##   ever simulated forward to fill a gap between them.
##
##   EVENTS as they fire: shot launched, successful shot, HIVE tipped, foul,
##   phase change, objective completed/failed. Each carries a stable id.
##
## TIME. Recording time is the count of recorded physics ticks / 180, so it
## is exact to the tick and skips pauses entirely. Samples land on every 6th
## tick (33.3 ms); checkpoints on every 180th (1 s).
##
## MEMORY IS BOUNDED BY ONE BLOCK: at most 30 samples, this second's events
## and nothing else. Everything older is already on disk. A two-hour free
## practice holds the same amount in memory as a two-minute match.
##
## THE FILE IS CREATED ON THE FIRST LIVE TICK, never before, so opening a
## menu, loading a situation or entering the editor cannot produce an empty
## recording, and a new run can never overwrite an old one: every run gets
## its own id.
##
## WHEN THE DISK FAILS the recorder stops, keeps everything already written,
## reports the time it is playable up to, and leaves the run alone. It never
## deletes anything to make room.
##

## The recording stopped, or may be about to (low disk). Say it to the player.
signal problem(text: String)
## A recording was finished and is in the collection.
signal saved(id: String)

const TICK_HZ := 180
const SAMPLE_EVERY := 6
const RATE_HZ := 30
const BLOCK := 30
const CHECKPOINT_EVERY := 180
## Ticks after the capture that a checkpoint is encoded and written.
const CHECKPOINT_WRITE_LAG := 3
const HEAD := 8
const PER_ROBOT := 12
const PER_HIVE := 7
const PER_ELEMENT := 8
## Warn when the replay folder's disk has less than this left.
const LOW_DISK := 200 * 1024 * 1024

enum State { IDLE, ARMED, RECORDING, FAILED }

var main: Node3D
var state := State.IDLE
## When set, every encoded chunk is handed to this (bytes, type) instead of
## being written here: the online room streams its recording to every player,
## who each keep it in their own local replay collection.
var sink: Callable
var ctx: Dictionary = {}
var id := ""
## The most recent recording that was finished (or stopped by a failure).
var last_id := ""
## One line about it, for the results screens: "" when it saved normally.
var last_note := ""

var _f: FileAccess
var _path := ""
var _ticks := 0
var _robots: Array = []
var _brains: Array = []
var _elements: Array = []
var _hives: Array = []
var _stride := 0
var _block := PackedFloat32Array()
var _block_n := 0
var _block_i := 0
var _events: Array = []
var _ev_seq := 0
var _status_last := {}
var _status0 := {}
var _status_changes: Array = []
var _rng := RandomNumberGenerator.new()
var _saved_through := -1.0
var _last_sample_t := 0.0
var _last_score := {"red": 0, "blue": 0}
var _attempt_rec: Dictionary = {}
var _finishing := false
var _connections: Array = []
var _pending_cp: Dictionary = {}
var _next_disk_check := 0

## Measurements, read by tools/perf_replay.gd.
var cost_usec_total := 0
var cost_usec_max := 0
var cost_ticks := 0
var bytes_written := 0
var max_buffered_samples := 0
## Creating the file, header and sidecar on the first live tick.
var cost_open_usec := 0
## perf_replay only: keep every tick's cost (unbounded, so off by default).
var debug_keep_costs := false
var debug_costs := PackedInt32Array()
## Test hook: pretend the disk fails once this many blocks have been written.
var debug_fail_after_blocks := -1

func _ready() -> void:
	_rng.randomize()

# ============================================================== lifecycle ===

## Arm a recording for the run that is about to start. Nothing is written
## until the first tick the world is actually being played.
func begin(context: Dictionary) -> void:
	if state == State.RECORDING or state == State.FAILED:
		finish("abandoned", "replaced by a new run")
	ctx = context.duplicate(true)
	state = State.ARMED
	_attempt_rec = {}

func is_recording() -> bool:
	return state == State.RECORDING

## The attempt this run was measured against ended. Its outcome becomes the
## recording's, and the recording ends with it.
func note_attempt(rec: Dictionary) -> void:
	if state != State.RECORDING and state != State.FAILED:
		return
	_attempt_rec = rec.duplicate(true)
	var st := String(rec.get("state", ""))
	if st == "succeeded":
		_event("objective", "Objective completed", {})
	elif st == "failed":
		_event("objective", "Objective failed (%s)" % _reason_text(String(rec.get("reason", ""))), {})
	finish(st if st in ["succeeded", "failed"] else "abandoned",
		String(rec.get("reason", "")))

static func _reason_text(r: String) -> String:
	match r:
		"timeout": return "out of time"
		"foul": return "a foul"
		"match_ended": return "the match ended"
	return r if r != "" else "not met"

## FINISH THE RECORDING. Idempotent: the first call wins.
##   outcome   finished | succeeded | failed | abandoned | ended
## Returns the id that was saved, or "" if nothing had been recorded.
func finish(outcome: String, reason := "") -> String:
	if state == State.ARMED:
		state = State.IDLE           # nothing was ever played: nothing to keep
		return ""
	if state == State.IDLE:
		return ""
	var free_run := int(ctx.get("mode", -1)) == BB.Mode.FREE_PRACTICE
	if outcome == "abandoned" and free_run and _attempt_rec.is_empty():
		outcome = "ended"            # free practice has no finish line to miss
	var saved_id := id
	if sink.is_valid():
		if state == State.RECORDING:
			_write_checkpoint()
			_flush_block()
			_write(ReplayFormat.Chunk.FINAL, _last_sample_t, _last_sample_t,
				ReplayFormat.json_bytes(_final_dict(outcome, reason)))
		_disconnect_all()
		last_id = saved_id
		last_note = ""
		state = State.IDLE
		id = ""
		saved.emit(saved_id)
		return saved_id
	if state == State.RECORDING:
		_write_checkpoint()
		_flush_block()
	if state == State.RECORDING:
		var fin := _final_dict(outcome, reason)
		if not _write(ReplayFormat.Chunk.FINAL, _last_sample_t, _last_sample_t,
				ReplayFormat.json_bytes(fin)):
			pass                       # _write already reported and failed over
		else:
			_f.flush()
	var complete := state == State.RECORDING
	_close_file()
	var m := ReplayStore.read_meta(saved_id)
	var fin2 := _final_dict(outcome, reason)
	for k in fin2:
		m[k] = fin2[k]
	if complete:
		m["status"] = "complete"
		m["rec_bytes"] = FileAccess.get_size(_path) if FileAccess.file_exists(_path) else 0
	else:
		m["status"] = "incomplete"
		m["outcome"] = "incomplete"
		m["outcome_label"] = "Incomplete"
		m["saved_through"] = maxf(_saved_through, 0.0)
		m["duration"] = maxf(_saved_through, 0.0)
	ReplayStore.write_meta(saved_id, m)
	_disconnect_all()
	ReplayStore.active_id = ""
	last_id = saved_id
	if not complete:
		last_note = ("This replay is incomplete: recording stopped at %s."
			% _clock(maxf(_saved_through, 0.0)))
	else:
		last_note = ""
	state = State.IDLE
	id = ""
	saved.emit(saved_id)
	return saved_id

func _final_dict(outcome: String, reason: String) -> Dictionary:
	var labels := {"finished": "Finished", "succeeded": "Objective completed",
		"failed": "Objective failed", "abandoned": "Abandoned", "ended": "Ended"}
	var score := _last_score.duplicate()
	var final_score := false
	if outcome == "finished" and main and main.mm and not main.mm.last_result.is_empty():
		var b: Dictionary = main.mm.last_result.get("breakdown", {})
		score = {"red": int(b.get(BB.Alliance.RED, {}).get("total", 0)),
			"blue": int(b.get(BB.Alliance.BLUE, {}).get("total", 0))}
		final_score = true
	var ours := int(ctx.get("our_alliance", BB.Alliance.RED))
	score["ours"] = int(score.get("red" if ours == BB.Alliance.RED else "blue", 0))
	score["final"] = final_score
	var out := {
		"outcome": outcome,
		"outcome_label": String(labels.get(outcome, outcome.capitalize())),
		"reason": reason,
		"duration": _last_sample_t,
		"score": score,
		"ended": Time.get_datetime_string_from_system(true),
	}
	if not _attempt_rec.is_empty():
		out["attempt"] = {
			"state": _attempt_rec.get("state", ""),
			"reason": _attempt_rec.get("reason", ""),
			"progress": _attempt_rec.get("progress", 0),
			"goal": _attempt_rec.get("goal", 0),
			"elapsed": _attempt_rec.get("elapsed", 0.0),
			"attempt_no": _attempt_rec.get("attempt_no", 1),
		}
	return out

func _notification(what: int) -> void:
	# Closing the window mid-run keeps the run, marked abandoned.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		finish("abandoned", "game closed")
	elif what == NOTIFICATION_PREDELETE:
		if _f != null:
			_f.flush()
			_f.close()
			_f = null

# ================================================================ the tick ==

func _physics_process(_delta: float) -> void:
	if state != State.ARMED and state != State.RECORDING:
		return
	if BB.frozen() or BB.halted or main == null or main.mm == null:
		return
	if not main.mm.in_progress() or main.mm.paused:
		return
	var c0 := Time.get_ticks_usec()
	if state == State.ARMED:
		if not _open():
			return
		cost_open_usec = Time.get_ticks_usec() - c0
		c0 = Time.get_ticks_usec()
	if _ticks % SAMPLE_EVERY == 0:
		if _block_n >= BLOCK:
			_flush_block()
		if state != State.RECORDING:
			return
		_sample()
		if _ticks % CHECKPOINT_EVERY == 0:
			_checkpoint()
	elif _ticks % CHECKPOINT_EVERY == CHECKPOINT_WRITE_LAG and not _pending_cp.is_empty():
		_write_checkpoint()
	_ticks += 1
	var cost := Time.get_ticks_usec() - c0
	cost_usec_total += cost
	cost_usec_max = maxi(cost_usec_max, cost)
	cost_ticks += 1
	if debug_keep_costs:
		debug_costs.append(cost)

func _t() -> float:
	return float(_ticks) / float(TICK_HZ)

# ================================================================= opening ==

func _open() -> bool:
	var streaming := sink.is_valid()
	if not streaming and not ReplayStore.ensure_folder():
		_fail_before_start("the replay folder %s could not be created" % ReplayStore.folder())
		return false
	id = ReplayStore.new_id()
	if not streaming:
		_path = ReplayStore.recording_path(id)
		_f = FileAccess.open(_path, FileAccess.WRITE)
		if _f == null:
			_fail_before_start("the replay folder is not writable")
			return false
	_ticks = 0
	_block_i = 0
	_block_n = 0
	_events.clear()
	_ev_seq = 0
	_status_last.clear()
	_status_changes.clear()
	_saved_through = -1.0
	_last_sample_t = 0.0
	_next_disk_check = 0
	_pending_cp = {}
	bytes_written = 0

	_robots = []
	_brains = []
	for r in main.robots:
		if is_instance_valid(r):
			_robots.append(r)
			var br: Variant = null
			for b in main.ais:
				if is_instance_valid(b) and b.robot == r:
					br = b
			_brains.append(br)
	# THE SAME ORDER Snapshot.capture() uses, taken on the same tick as the
	# first checkpoint, so sample element k is checkpoint 0's element e(k+1).
	_elements = []
	for n in main.get_tree().get_nodes_in_group("element"):
		if is_instance_valid(n):
			_elements.append(n)
	_hives = []
	var hive_alliances: Array = []
	for a in main.field.hives:
		_hives.append(main.field.hives[a])
		hive_alliances.append(int(a))
	_stride = HEAD + PER_ROBOT * _robots.size() + PER_HIVE * _hives.size() \
		+ PER_ELEMENT * _elements.size()
	_block = PackedFloat32Array()
	_block.resize(_stride * BLOCK)

	var robots_meta: Array = []
	for i in _robots.size():
		var r: Robot = _robots[i]
		var br2: Variant = _brains[i]
		robots_meta.append({
			"label": r.driver_label, "alliance": r.alliance, "ai": r.ai_driver,
			"intakes": r.intakes,
			"behavior": OpponentConfig.describe(br2.config) if br2 != null else "",
		})
	var elements_meta: Array = []
	for e in _elements:
		elements_meta.append({"kind": (e as GameElement).kind,
			"alliance": (e as GameElement).alliance})
	var now_local := Time.get_datetime_dict_from_system()
	var header := {
		"format": "biobuzz.replay",
		"version": ReplayFormat.VERSION,
		"id": id,
		"title": String(ctx.get("title", "Replay")),
		"created": Time.get_datetime_string_from_system(true),
		"created_local": "%04d-%02d-%02d %02d:%02d" % [now_local["year"],
			now_local["month"], now_local["day"], now_local["hour"], now_local["minute"]],
		"mode": int(ctx.get("mode", main.mm.mode)),
		"mode_name": String(ctx.get("mode_name", "")),
		"kind": String(ctx.get("kind", "match")),
		"scenario_id": String(ctx.get("scenario_id", "")),
		"scenario_name": String(ctx.get("scenario_name", "")),
		"our_alliance": int(ctx.get("our_alliance", BB.Alliance.RED)),
		"robot_profile": RobotShop.robot_name,
		"tick_hz": TICK_HZ, "rate_hz": RATE_HZ, "block": BLOCK,
		"checkpoint_every_s": float(CHECKPOINT_EVERY) / float(TICK_HZ),
		"layout": {"head": HEAD, "robot": PER_ROBOT, "hive": PER_HIVE,
			"element": PER_ELEMENT, "stride": _stride},
		"robots": robots_meta,
		"elements": elements_meta,
		"hives": hive_alliances,
		"game_version": NetRole.GAME_VERSION,
	}
	header.merge(ctx.get("header_extra", {}), true)
	if streaming:
		state = State.RECORDING
		if not _write(ReplayFormat.Chunk.HEADER, 0.0, 0.0, ReplayFormat.json_bytes(header)):
			return false
		_connect_all()
		_event("start", "Recording starts — %s%s" % [_phase_name(main.mm.phase),
			"" if main.mm.free_practice() else ", %s left" % BB.clock_text(main.mm.time_left)], {})
		return true
	if not ReplayFormat.write_file_header(_f):
		_fail("the disk refused the first write")
		return false
	bytes_written = ReplayFormat.FILE_HEADER_BYTES
	state = State.RECORDING
	ReplayStore.active_id = id
	if not _write(ReplayFormat.Chunk.HEADER, 0.0, 0.0, ReplayFormat.json_bytes(header)):
		return false
	var meta := {
		"title": header["title"], "title_edited": false, "favorite": false,
		"tags": [], "created": header["created"],
		"created_local": header["created_local"], "mode": header["mode"],
		"mode_name": header["mode_name"], "kind": header["kind"],
		"scenario_id": header["scenario_id"],
		"scenario_name": header["scenario_name"],
		"our_alliance": header["our_alliance"],
		"status": "recording", "outcome": "", "outcome_label": "Recording",
		"duration": 0.0, "score": {},
	}
	ReplayStore.write_meta(id, meta)
	_connect_all()
	_event("start", "Recording starts — %s%s" % [_phase_name(main.mm.phase),
		"" if main.mm.free_practice() else ", %s left" % BB.clock_text(main.mm.time_left)], {})
	_check_disk()
	return true

func _fail_before_start(why: String) -> void:
	state = State.FAILED
	var msg := "Replay recording could not start: %s. The run continues without a replay." % why
	last_note = msg
	last_id = ""
	problem.emit(msg)
	state = State.IDLE

# ================================================================ sampling ==

func _sample() -> void:
	var t := _t()
	_last_sample_t = t
	_last_score = fill_row(_block, _block_n * _stride, t, main.mm, main.field,
		_robots, _hives, _elements)
	if _block_n == 0:
		_status0 = _status_last.duplicate()
	for i in _robots.size():
		var br: Variant = _brains[i]
		if br != null and is_instance_valid(br):
			var st := String(br.status)
			if String(_status_last.get(i, "\u0000")) != st:
				_status_last[i] = st
				_status_changes.append([_block_n, i, st])
	_block_n += 1
	max_buffered_samples = maxi(max_buffered_samples, _block_n)

## ONE ROW OF AUTHORITATIVE STATE, written into `row` at offset `o`.
##
## Shared by the replay recorder and the online room, so a replay sample and a
## network snapshot are the same numbers in the same order:
##   head     t, match time_left, phase, red score, blue score,
##            fouls against red, fouls against blue, flags
##   robot×R  position, rotation quaternion, turret yaw, hood angle,
##            hopper count, enabled, battery volts
##   hive×H   swing position, rotation quaternion
##   elem×E   position, rotation quaternion, holder
## Returns the scoreboard it wrote, {red, blue}.
static func fill_row(row: PackedFloat32Array, o: int, t: float, mm: Node, field: Node,
		robots: Array, hives: Array, elements: Array) -> Dictionary:
	var fin: bool = mm.phase == BB.Phase.SETTLE or mm.phase == BB.Phase.DONE
	var b: Dictionary = mm.scoring.breakdown(field, fin)
	var red := int(b.get(BB.Alliance.RED, {}).get("total", 0))
	var blue := int(b.get(BB.Alliance.BLUE, {}).get("total", 0))
	row[o] = t
	row[o + 1] = mm.time_left
	row[o + 2] = mm.phase
	row[o + 3] = red
	row[o + 4] = blue
	row[o + 5] = int(mm.scoring.fouls_against[BB.Alliance.RED])
	row[o + 6] = int(mm.scoring.fouls_against[BB.Alliance.BLUE])
	row[o + 7] = (1.0 if fin else 0.0) + (2.0 if mm.free_practice() else 0.0) \
		+ (4.0 if mm.paused else 0.0)
	o += HEAD
	for r in robots:
		if not is_instance_valid(r):
			for k in PER_ROBOT:
				row[o + k] = 0.0
			o += PER_ROBOT
			continue
		var rob: Robot = r
		var gt := rob.global_transform
		var q := gt.basis.get_rotation_quaternion()
		row[o] = gt.origin.x
		row[o + 1] = gt.origin.y
		row[o + 2] = gt.origin.z
		row[o + 3] = q.x
		row[o + 4] = q.y
		row[o + 5] = q.z
		row[o + 6] = q.w
		row[o + 7] = rob.turret.rotation.y if rob.turret else 0.0
		row[o + 8] = rob.hood_deg
		row[o + 9] = rob.hopper.size()
		row[o + 10] = 1.0 if rob.enabled else 0.0
		row[o + 11] = rob.battery_v
		o += PER_ROBOT
	for h in hives:
		var sw: RigidBody3D = (h as Hive).swing
		var ht := sw.global_transform
		var hq := ht.basis.get_rotation_quaternion()
		row[o] = ht.origin.x
		row[o + 1] = ht.origin.y
		row[o + 2] = ht.origin.z
		row[o + 3] = hq.x
		row[o + 4] = hq.y
		row[o + 5] = hq.z
		row[o + 6] = hq.w
		o += PER_HIVE
	for e in elements:
		if not is_instance_valid(e):
			for k in PER_ELEMENT:
				row[o + k] = 0.0
			row[o + 7] = -3.0
			o += PER_ELEMENT
			continue
		var el: GameElement = e
		var et := el.global_transform
		var eq := et.basis.get_rotation_quaternion()
		row[o] = et.origin.x
		row[o + 1] = et.origin.y
		row[o + 2] = et.origin.z
		row[o + 3] = eq.x
		row[o + 4] = eq.y
		row[o + 5] = eq.z
		row[o + 6] = eq.w
		var hb: Variant = el.held_by
		var holder := -1.0
		if hb != null and is_instance_valid(hb):
			if hb == el or hb == mm:
				holder = -2.0
			else:
				var ri := robots.find(hb)
				holder = float(ri) if ri >= 0 else -1.0
		row[o + 7] = holder
		o += PER_ELEMENT
	return {"red": red, "blue": blue}

func _flush_block() -> void:
	if _block_n == 0 or state != State.RECORDING:
		return
	var i0 := _block_i * BLOCK
	var t0 := float(i0) / float(RATE_HZ)
	var t1 := float(i0 + _block_n - 1) / float(RATE_HZ)
	var meta := {"n": _block_n, "stride": _stride, "i0": i0,
		"status0": _status0, "status": _status_changes.duplicate()}
	var raw := var_to_bytes([meta, _block.slice(0, _block_n * _stride)])
	if debug_fail_after_blocks >= 0 and _block_i >= debug_fail_after_blocks:
		_fail("the disk refused to write (simulated)")
		return
	if not _write(ReplayFormat.Chunk.SAMPLES, t0, t1, raw):
		return
	if not _events.is_empty():
		if not _write(ReplayFormat.Chunk.EVENTS, float(_events[0]["t"]),
				float(_events[-1]["t"]), ReplayFormat.json_bytes(_events)):
			return
	if not sink.is_valid():
		_f.flush()
		if _f.get_error() != OK:
			_fail("the disk refused to write")
			return
	_saved_through = t1
	_block_i += 1
	_block_n = 0
	_events.clear()
	_status_changes.clear()
	if _block_i >= _next_disk_check:
		_check_disk()

## CAPTURE on the sample tick, so the checkpoint and the sample describe the
## same instant; SERIALISE AND WRITE a few ticks later, so the capture, the
## block flush and the JSON encoding never all land on one tick.
func _checkpoint() -> void:
	if state != State.RECORDING:
		return
	_pending_cp = Snapshot.capture(main, _rng.randi())
	_pending_cp["replay_t"] = _t()

func _write_checkpoint() -> void:
	if _pending_cp.is_empty() or state != State.RECORDING:
		return
	var t := float(_pending_cp["replay_t"])
	var snap := _pending_cp
	_pending_cp = {}
	_write(ReplayFormat.Chunk.CHECKPOINT, t, t, ReplayFormat.json_bytes(snap))

## Write one chunk; on failure stop recording and say so. With a `sink` (the
## online room), chunks go to the sink instead of a local file.
func _write(type: int, t0: float, t1: float, raw: PackedByteArray) -> bool:
	if sink.is_valid():
		var enc := ReplayFormat.encode_chunk(type, t0, t1, raw)
		bytes_written += enc.size()
		sink.call(enc, type)
		return true
	if _f == null:
		return false
	var n := ReplayFormat.write_chunk(_f, type, t0, t1, raw)
	if n < 0:
		_fail("the disk refused to write")
		return false
	bytes_written += n
	return true

## STOP, KEEP WHAT IS ON DISK, SAY SO. The run carries on regardless.
func _fail(why: String) -> void:
	if state != State.RECORDING:
		return
	state = State.FAILED
	_close_file()
	var through := maxf(_saved_through, 0.0)
	var m := ReplayStore.read_meta(id)
	m["status"] = "incomplete"
	m["outcome"] = "incomplete"
	m["outcome_label"] = "Incomplete"
	m["saved_through"] = through
	m["duration"] = through
	m["storage_note"] = why
	ReplayStore.write_meta(id, m)
	ReplayStore.active_id = ""
	var msg := ("REPLAY RECORDING STOPPED — %s. The replay is saved up to %s; "
		% [why, _clock(through)]) + "the rest of this run is not being recorded."
	if _saved_through < 0.0:
		msg = ("REPLAY RECORDING STOPPED — %s. Nothing of this run could be "
			% why) + "saved; the run itself carries on."
	last_note = msg
	problem.emit(msg)

func _check_disk() -> void:
	_next_disk_check = _block_i + 60
	if sink.is_valid():
		return
	var da := DirAccess.open(ReplayStore.folder())
	if da == null:
		return
	var left := da.get_space_left()
	if left > 0 and left < LOW_DISK:
		problem.emit(("Low disk space: %s left in the replay folder. Recording "
			% ReplayStore.size_text(left)) + "continues; if the disk fills, the "
			+ "replay stops at that point and the run carries on.")

func _close_file() -> void:
	if _f != null:
		_f.flush()
		_f.close()
		_f = null

# ================================================================== events ==

func _event(type: String, label: String, extra: Dictionary) -> void:
	if state != State.RECORDING:
		return
	_ev_seq += 1
	var ev := {"id": "ev%05d" % _ev_seq, "t": _t(), "type": type, "label": label}
	ev.merge(extra)
	_events.append(ev)

func _connect_all() -> void:
	_disconnect_all()
	var mm = main.mm
	_link(mm.foul, _on_foul)
	_link(mm.phase_changed, _on_phase)
	_link(mm.finished, _on_finished)
	_link(mm.aborted, _on_aborted)
	_link(main.stats.shot_made, _on_made)
	for i in _robots.size():
		_link((_robots[i] as Robot).launched, _on_launched.bind(i))
	for h in _hives:
		_link((h as Hive).tipped, _on_tipped)

func _link(sig: Signal, c: Callable) -> void:
	if not sig.is_connected(c):
		sig.connect(c)
	_connections.append([sig, c])

func _disconnect_all() -> void:
	for pair in _connections:
		var sig: Signal = pair[0]
		var c: Callable = pair[1]
		if sig.get_object() != null and is_instance_valid(sig.get_object()) \
				and sig.is_connected(c):
			sig.disconnect(c)
	_connections.clear()

func _label_of(i: int) -> String:
	if i >= 0 and i < _robots.size() and is_instance_valid(_robots[i]):
		return (_robots[i] as Robot).driver_label
	return "robot %d" % (i + 1)

func _on_launched(_e: GameElement, i: int) -> void:
	_event("shot", "Shot launched — %s" % _label_of(i), {"robot": i})

func _on_made(r: Robot, _e: GameElement) -> void:
	var i := _robots.find(r)
	_event("made", "Successful shot — %s" % _label_of(i), {"robot": i})

func _on_tipped(alliance: int, _h: Hive) -> void:
	if BB.frozen():
		return
	_event("tip", "HIVE tipped — %s HIVE" % BB.alliance_name(alliance), {"alliance": alliance})

func _on_foul(text: String, by: int, points: int) -> void:
	if points <= 0:
		_event("foul", "Warning — %s: %s" % [BB.alliance_name(by), text], {"alliance": by})
	else:
		_event("foul", "Foul — %s: %s (%d points to the other alliance)" % [
			BB.alliance_name(by), text, points], {"alliance": by, "points": points})

func _on_phase(phase: int) -> void:
	if phase == BB.Phase.PRE:
		return
	_event("phase", "Phase — %s" % _phase_name(phase), {"phase": phase})

func _on_finished(_result: Dictionary) -> void:
	# Deferred so an objective that is decided by the final score (Attempt
	# listens to the same signal) can hand its outcome over first.
	call_deferred("_finish_if_open", "finished", "match ended")

func _finish_if_open(outcome: String, reason: String) -> void:
	if state == State.RECORDING or state == State.FAILED:
		finish(outcome, reason)

func _on_aborted() -> void:
	finish("abandoned", "ended before the finish")

static func _phase_name(p: int) -> String:
	return ["Pre-match", "Autonomous", "Transition", "Teleop", "Settling",
		"Finished"][clampi(p, 0, 5)]

static func _clock(t: float) -> String:
	return "%d:%04.1f" % [int(t) / 60, fmod(t, 60.0)]
