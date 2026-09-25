class_name NetProto
extends RefCounted
##
## EVERY MESSAGE ON THE WIRE, AND HOW EACH ONE IS CHECKED.
##
## Control and bulk messages are `var_to_bytes([type, payload])` with objects
## NEVER allowed back through `bytes_to_var`, then checked field by field
## before anything reads them. Inputs and snapshots are packed binary, because
## they are sent up to sixty times a second.
##
## Nothing received is trusted. A malformed packet is dropped and counted; it
## never reaches the simulation.
##

# ---- client <-> room
const ENTER := 40          # invite secret or reconnect token, name, compat
const WELCOME := 41
const ROOM_STATE := 42     # the whole lobby / session state, on every change
const SEAT := 43           # request {robot, role} or release {robot:-1}
const READY := 44
const SCENARIO_ACK := 45
const SET_SCENARIO := 46   # owner
const SET_AI := 47         # owner
const LOCK := 48           # owner
const KICK := 49           # owner
const START := 50          # owner
const PAUSE := 51          # owner: pause; others: request
const RESUME := 52         # owner
const RETRY := 53          # owner: retry; others: request
const END := 54            # owner: end the session
const LOBBY := 55          # owner: back to the lobby
const REASSIGN := 56       # owner: give a disconnected seat to someone else
const RESTORE_ACK := 57
const MENU := 58           # "my menu is open" — display only
const LEAVE := 59
const PING := 60
const PONG := 61
const SCENARIO := 62       # bulk: the scenario itself
const SLOW := 63           # statuses, event log, objective text
const RESULT := 64
const REPLAY_CHUNK := 65   # bulk
const REJECT := 66         # a request that was refused, and why
const CLOSED := 67         # the room is gone / you were removed
const DENY := 68           # could not enter
const SET_RATE := 69       # host: {low: bool} fewer snapshots, for a slow home upload

const INPUT := 100         # binary
const SNAP := 101          # binary

const MAX_CONTROL := 64 * 1024
const MAX_BULK := 1024 * 1024
const MAX_SCENARIO_RAW := 2 * 1024 * 1024

# ============================================================== control ===

static func pack(type: int, payload: Dictionary = {}) -> PackedByteArray:
	return var_to_bytes([type, payload])

## [type, payload] or [] if it is not a well-formed control message.
static func unpack(bytes: PackedByteArray, max_size := MAX_CONTROL) -> Array:
	if bytes.is_empty() or bytes.size() > max_size:
		return []
	if bytes[0] == INPUT or bytes[0] == SNAP:
		return []
	var v: Variant = bytes_to_var(bytes)
	if not (v is Array) or (v as Array).size() != 2:
		return []
	var a: Array = v
	if typeof(a[0]) != TYPE_INT or not (a[1] is Dictionary):
		return []
	return a

# ------------------------------------------------------------- validators

static func s(d: Dictionary, key: String, max_len := 64, fallback := "") -> String:
	var v: Variant = d.get(key)
	if typeof(v) != TYPE_STRING:
		return fallback
	var t := (v as String).strip_edges()
	if t.length() > max_len:
		t = t.substr(0, max_len)
	return t

static func i(d: Dictionary, key: String, lo: int, hi: int, fallback := 0) -> int:
	var v: Variant = d.get(key)
	if typeof(v) == TYPE_INT:
		return clampi(v, lo, hi)
	if typeof(v) == TYPE_FLOAT and is_finite(v):
		return clampi(int(v), lo, hi)
	return fallback

static func b(d: Dictionary, key: String, fallback := false) -> bool:
	var v: Variant = d.get(key)
	return v if typeof(v) == TYPE_BOOL else fallback

## Printable display names only: no control characters, no BBCode brackets,
## 1-24 characters.
static func clean_name(t: String) -> String:
	var out := ""
	for ch in t:
		var c := ch.unicode_at(0)
		if c < 32 or c == 127 or ch in ["[", "]", "\\"]:
			continue
		out += ch
	out = out.strip_edges().substr(0, 24)
	return out if out != "" else "Player"

# ================================================================= input ===
#
#  0 u8  INPUT          11 i16 strafe      18 u16 held bits
#  1 u16 run id         13 i16 forward     20 u8  presses: field-centric
#  3 u32 sequence       15 i16 turn        21 u8  presses: outtake
#  7 u32 acked tick     17 u8  precision   22 u8  presses: aim assist
#                                          23 u8  presses: recalibrate
#                                          24 u8  flags (1 menu open)

const INPUT_SIZE := 25
const HELD := ["slow", "intake_off", "turret_left", "turret_right", "hood_up",
	"hood_down", "power_up", "power_down", "fire"]
## Discrete actions, sent as running totals so a lost packet loses nothing.
const PRESSES := ["field_centric", "outtake", "aim_assist", "recalibrate"]

## Which part of a robot each role controls. Camera and menus are never here:
## they are local to each player's computer.
const DRIVER_HELD := ["slow"]
const DRIVER_PRESSES := ["field_centric"]
const OPERATOR_HELD := ["intake_off", "turret_left", "turret_right", "hood_up",
	"hood_down", "power_up", "power_down", "fire"]
const OPERATOR_PRESSES := ["outtake", "aim_assist", "recalibrate"]

static func pack_input(run: int, seq: int, ack: int, v: Dictionary) -> PackedByteArray:
	var p := PackedByteArray()
	p.resize(INPUT_SIZE)
	p.encode_u8(0, INPUT)
	p.encode_u16(1, run & 0xFFFF)
	p.encode_u32(3, seq)
	p.encode_u32(7, ack)
	var mv: Vector2 = v.get("move", Vector2.ZERO)
	p.encode_s16(11, int(round(clampf(mv.x, -1.0, 1.0) * 32767.0)))
	p.encode_s16(13, int(round(clampf(mv.y, -1.0, 1.0) * 32767.0)))
	p.encode_s16(15, int(round(clampf(float(v.get("turn", 0.0)), -1.0, 1.0) * 32767.0)))
	p.encode_u8(17, clampi(int(round(float(v.get("precision", 1.0)) * 100.0)), 0, 100))
	var bits := 0
	var held: Dictionary = v.get("held", {})
	for k in HELD.size():
		if bool(held.get(HELD[k], false)):
			bits |= 1 << k
	p.encode_u16(18, bits)
	var pr: Dictionary = v.get("presses", {})
	for k2 in PRESSES.size():
		p.encode_u8(20 + k2, int(pr.get(PRESSES[k2], 0)) & 0xFF)
	p.encode_u8(24, 1 if bool(v.get("menu", false)) else 0)
	return p

## Decoded input, or {} if the packet is malformed. Values are range-checked
## here; WHO may use them is decided by the room.
static func unpack_input(p: PackedByteArray) -> Dictionary:
	if p.size() != INPUT_SIZE or p[0] != INPUT:
		return {}
	var mv := Vector2(float(p.decode_s16(11)) / 32767.0, float(p.decode_s16(13)) / 32767.0)
	if mv.length() > 1.0001:
		mv = mv.normalized()
	var held := {}
	var bits := p.decode_u16(18)
	if bits >> HELD.size() != 0:
		return {}                       # bits nobody defined
	for k in HELD.size():
		held[HELD[k]] = (bits >> k) & 1 == 1
	var pr := {}
	for k2 in PRESSES.size():
		pr[PRESSES[k2]] = p.decode_u8(20 + k2)
	var prec := float(p.decode_u8(17)) / 100.0
	return {
		"run": p.decode_u16(1), "seq": p.decode_u32(3), "ack": p.decode_u32(7),
		"move": mv, "turn": clampf(float(p.decode_s16(15)) / 32767.0, -1.0, 1.0),
		"precision": clampf(prec, 0.1, 1.0), "held": held, "presses": pr,
		"menu": p.decode_u8(24) & 1 == 1,
	}

static func neutral_input() -> Dictionary:
	var held := {}
	for h in HELD:
		held[h] = false
	return {"move": Vector2.ZERO, "turn": 0.0, "precision": 1.0, "held": held,
		"presses": {}, "menu": false}

static func is_neutral(v: Dictionary) -> bool:
	if (v.get("move", Vector2.ZERO) as Vector2).length() > 0.05:
		return false
	if absf(float(v.get("turn", 0.0))) > 0.05:
		return false
	for h in (v.get("held", {}) as Dictionary).values():
		if bool(h):
			return false
	return true

# ============================================================== snapshot ===
#
# The world, quantised, in the SAME row layout the replay samples use, so the
# client poses it with the viewer's own code. Positions are 0.1 mm steps
# (±3.2 m), rotations are unit quaternions to 1/32767, the turret to 0.1 mrad.
#
#   packet: u8 SNAP, u16 run, u32 tick, u8 n acks, n × [u8 pid, u32 seq],
#           u32 raw length, zstd(body)
#   body:   f32 time left, u8 phase, u8 flags, i16 red, i16 blue,
#           i16 fouls against red, i16 fouls against blue,
#           u8 R, u8 H, u16 E,
#           R × [i16×3 pos, i16×4 quat, i16 yaw, i16 hood×100, u8 hopper,
#                u8 enabled, u8 volts×10]
#           H × [i16×3, i16×4]
#           E × [i16×3, i16×4, i8 holder]

const POS_SCALE := 10000.0

static func pack_snapshot(run: int, tick: int, acks: Array, row: PackedFloat32Array,
		layout: Dictionary) -> PackedByteArray:
	var R: int = layout["robots"]
	var H: int = layout["hives"]
	var E: int = layout["elements"]
	var body := PackedByteArray()
	body.resize(20 + R * 21 + H * 14 + E * 15)
	body.encode_float(0, row[1])
	body.encode_u8(4, clampi(int(row[2]), 0, 255))
	body.encode_u8(5, clampi(int(row[7]), 0, 255))
	body.encode_s16(6, clampi(int(row[3]), -32768, 32767))
	body.encode_s16(8, clampi(int(row[4]), -32768, 32767))
	body.encode_s16(10, clampi(int(row[5]), -32768, 32767))
	body.encode_s16(12, clampi(int(row[6]), -32768, 32767))
	body.encode_u8(14, R)
	body.encode_u8(15, H)
	body.encode_u16(16, E)
	var o := 20
	var r := 8
	for _k in R:
		_pos(body, o, row, r)
		_quat(body, o + 6, row, r + 3)
		body.encode_s16(o + 14, clampi(int(round(wrapf(row[r + 7], -PI, PI) * 10000.0)), -32768, 32767))
		body.encode_s16(o + 16, clampi(int(round(row[r + 8] * 100.0)), -32768, 32767))
		body.encode_u8(o + 18, clampi(int(row[r + 9]), 0, 255))
		body.encode_u8(o + 19, 1 if row[r + 10] > 0.5 else 0)
		body.encode_u8(o + 20, clampi(int(round(row[r + 11] * 10.0)), 0, 255))
		o += 21
		r += 12
	for _h in H:
		_pos(body, o, row, r)
		_quat(body, o + 6, row, r + 3)
		o += 14
		r += 7
	for _e in E:
		_pos(body, o, row, r)
		_quat(body, o + 6, row, r + 3)
		body.encode_s8(o + 14, clampi(int(row[r + 7]), -128, 127))
		o += 15
		r += 8
	var comp := body.compress(FileAccess.COMPRESSION_ZSTD)
	var head := PackedByteArray()
	head.resize(8 + acks.size() * 5 + 4)
	head.encode_u8(0, SNAP)
	head.encode_u16(1, run & 0xFFFF)
	head.encode_u32(3, tick)
	head.encode_u8(7, acks.size())
	var a := 8
	for ack in acks:
		head.encode_u8(a, int(ack[0]) & 0xFF)
		head.encode_u32(a + 1, int(ack[1]))
		a += 5
	head.encode_u32(a, body.size())
	return head + comp

static func _pos(p: PackedByteArray, o: int, row: PackedFloat32Array, r: int) -> void:
	for k in 3:
		p.encode_s16(o + k * 2, clampi(int(round(row[r + k] * POS_SCALE)), -32768, 32767))

static func _quat(p: PackedByteArray, o: int, row: PackedFloat32Array, r: int) -> void:
	for k in 4:
		p.encode_s16(o + k * 2, clampi(int(round(clampf(row[r + k], -1.0, 1.0) * 32767.0)), -32767, 32767))

## {run, tick, acks: {pid: seq}, row: PackedFloat32Array, layout} or {} when
## the packet is malformed or does not match the expected world.
static func unpack_snapshot(p: PackedByteArray, want: Dictionary) -> Dictionary:
	if p.size() < 12 or p[0] != SNAP:
		return {}
	var run := p.decode_u16(1)
	var tick := p.decode_u32(3)
	var n := p.decode_u8(7)
	var a := 8
	if p.size() < a + n * 5 + 4:
		return {}
	var acks := {}
	for _k in n:
		acks[p.decode_u8(a)] = p.decode_u32(a + 1)
		a += 5
	var raw_len := p.decode_u32(a)
	if raw_len > 65536:
		return {}
	var body := p.slice(a + 4).decompress(raw_len, FileAccess.COMPRESSION_ZSTD)
	if body.size() != raw_len or raw_len < 20:
		return {}
	var R := body.decode_u8(14)
	var H := body.decode_u8(15)
	var E := body.decode_u16(16)
	if not want.is_empty() and (R != int(want["robots"]) or H != int(want["hives"])
			or E != int(want["elements"])):
		return {}
	if raw_len != 20 + R * 21 + H * 14 + E * 15:
		return {}
	var row := PackedFloat32Array()
	row.resize(8 + R * 12 + H * 7 + E * 8)
	row[0] = float(tick)
	row[1] = body.decode_float(0)
	if not is_finite(row[1]):
		return {}
	row[2] = body.decode_u8(4)
	row[7] = body.decode_u8(5)
	row[3] = body.decode_s16(6)
	row[4] = body.decode_s16(8)
	row[5] = body.decode_s16(10)
	row[6] = body.decode_s16(12)
	var o := 20
	var r := 8
	for _r in R:
		_upos(body, o, row, r)
		_uquat(body, o + 6, row, r + 3)
		row[r + 7] = float(body.decode_s16(o + 14)) / 10000.0
		row[r + 8] = float(body.decode_s16(o + 16)) / 100.0
		row[r + 9] = body.decode_u8(o + 18)
		row[r + 10] = body.decode_u8(o + 19)
		row[r + 11] = float(body.decode_u8(o + 20)) / 10.0
		o += 21
		r += 12
	for _h in H:
		_upos(body, o, row, r)
		_uquat(body, o + 6, row, r + 3)
		o += 14
		r += 7
	for _e in E:
		_upos(body, o, row, r)
		_uquat(body, o + 6, row, r + 3)
		row[r + 7] = body.decode_s8(o + 14)
		o += 15
		r += 8
	return {"run": run, "tick": tick, "acks": acks, "row": row,
		"layout": {"robots": R, "hives": H, "elements": E}}

static func _upos(p: PackedByteArray, o: int, row: PackedFloat32Array, r: int) -> void:
	for k in 3:
		row[r + k] = float(p.decode_s16(o + k * 2)) / POS_SCALE

static func _uquat(p: PackedByteArray, o: int, row: PackedFloat32Array, r: int) -> void:
	for k in 4:
		row[r + k] = float(p.decode_s16(o + k * 2)) / 32767.0

## Random bytes as text, for tickets and tokens.
static func token(n_bytes := 16) -> String:
	return Crypto.new().generate_random_bytes(n_bytes).hex_encode()
