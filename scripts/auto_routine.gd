class_name AutoRoutine
extends RefCounted
##
## RECORD AN AUTO BY DRIVING IT.
##
## No code, no path editor: you drive the thirty seconds you want, save it, and
## the robot plays it back as its autonomous in a real match. What gets stored
## is your INPUT — the drive command and the buttons, sampled on a fixed tick —
## not the robot's position. That matters:
##
##   * it is what a real auto is. An FTC auto is a sequence of motor commands
##     that the field then does something with. Storing positions would be
##     storing the ANSWER, and a saved path that teleports the robot through a
##     ball that happens to be in the way is not practice, it is a cartoon.
##   * it means a replay is honest about being imperfect. Jolt is not
##     deterministic, so the same inputs land a few inches apart run to run —
##     exactly like a real encoder auto that drifts on a different battery.
##     If your routine only works when nothing goes slightly wrong, you have
##     learned something true.
##
## Saved to user://autos/<name>.json.
##

const DIR := "user://autos"
## Input is sampled this often. 30 Hz is finer than a human can steer and keeps
## a 30 second routine under 60 KB.
const TICK := 1.0 / 30.0

var name := ""
var frames: Array = []          # [drive_x, drive_y, drive_z, buttons] per tick
var created := ""
var note := ""

## Bit flags packed into the fourth column of each frame.
const B_FIRE := 1
const B_OUTTAKE := 2
const B_INTAKE_OFF := 4
const B_AIM := 8

func length_s() -> float:
	return float(frames.size()) * TICK

# ================================================================ recording ==

func start_recording() -> void:
	frames.clear()
	created = Time.get_datetime_string_from_system(true)

## Called on a fixed tick while recording.
func capture(drive: Vector3, fire: bool, outtake: bool, intake_off: bool,
		aim: bool) -> void:
	var bits := 0
	if fire: bits |= B_FIRE
	if outtake: bits |= B_OUTTAKE
	if intake_off: bits |= B_INTAKE_OFF
	if aim: bits |= B_AIM
	frames.append([
		snappedf(drive.x, 0.01), snappedf(drive.y, 0.01),
		snappedf(drive.z, 0.01), bits])

## Trim trailing dead time — everyone stops driving a second or two before they
## remember to stop recording, and thirty seconds of auto is precious.
func trim() -> void:
	while frames.size() > 0:
		var f: Array = frames[-1]
		if absf(float(f[0])) > 0.02 or absf(float(f[1])) > 0.02 \
				or absf(float(f[2])) > 0.02 or int(f[3]) != 0:
			break
		frames.pop_back()

# ================================================================ playback ===

## The command at `t` seconds into the routine, or null once it has run out.
func at(t: float) -> Dictionary:
	var i := int(t / TICK)
	if i < 0 or i >= frames.size():
		return {}
	var f: Array = frames[i]
	var bits := int(f[3])
	return {
		"drive": Vector3(float(f[0]), float(f[1]), float(f[2])),
		"fire": (bits & B_FIRE) != 0,
		"outtake": (bits & B_OUTTAKE) != 0,
		"intake_off": (bits & B_INTAKE_OFF) != 0,
		"aim": (bits & B_AIM) != 0,
	}

# ============================================================= persistence ===

static func dir() -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	return DIR

## Every saved routine's name, newest first.
static func list_saved() -> Array:
	var out: Array = []
	var d := DirAccess.open(dir())
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".json"):
			out.append(f.get_basename())
	out.sort()
	return out

static func load_named(n: String) -> AutoRoutine:
	var path := "%s/%s.json" % [dir(), n]
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return null
	var r := AutoRoutine.new()
	r.name = n
	r.created = String(parsed.get("created", ""))
	r.note = String(parsed.get("note", ""))
	r.frames = parsed.get("frames", [])
	return r

func save_as(n: String) -> bool:
	name = n.strip_edges()
	if name == "":
		return false
	var f := FileAccess.open("%s/%s.json" % [AutoRoutine.dir(), name], FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({
		"created": created, "note": note, "frames": frames,
	}))
	f.close()
	return true

static func delete_named(n: String) -> void:
	DirAccess.remove_absolute("%s/%s.json" % [dir(), n])
