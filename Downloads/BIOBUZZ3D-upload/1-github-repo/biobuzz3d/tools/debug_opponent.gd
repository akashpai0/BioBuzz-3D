extends Node
##
## THE OPPONENT HAS TO ACTUALLY PLAY.
##
## The brief is deliberately narrow: drive to the nearest POLLEN at a reasonable
## pace, pick up four, go and score them, repeat. So that is what this checks,
## end to end, over a full teleop period — not that it plays well, but that it
## plays at all and never just stands there.
##
var main: Node3D
var opp: Robot
var t := 0.0
var fails := 0
var picked_peak := 0
var ever_full := false
var shots := 0
var tips := 0
var idle := 0.0
var moved := 0.0
var last_pos := Vector3.ZERO
var top_speed := 0.0
var jammed := 0.0
var jam_gap := 9.0

const RUN_S := 70.0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	main.menu.close()
	await get_tree().create_timer(1.5).timeout
	main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 1})
	await get_tree().create_timer(2.5).timeout
	opp = main.opponent
	# park our own robot out of the way; this is about the opponent
	main.robot.auto_drive = true
	main.robot.set_drive(0, 0, 0)
	opp.launched.connect(func(_e: GameElement) -> void: shots += 1)
	for a in main.field.hives:
		(main.field.hives[a] as Hive).tipped.connect(func(al: int, _h: Hive) -> void:
			if al == opp.alliance:
				tips += 1)
	last_pos = opp.global_position
	print("\n--- THE OPPONENT ---")
	set_physics_process(true)

func _ok(label: String, got, want) -> void:
	var good: bool = got == want
	if not good:
		fails += 1
	print("  %s %-50s got %s   want %s" % ["PASS" if good else "FAIL", label, str(got), str(want)])

func _physics_process(d: float) -> void:
	if opp == null or not is_instance_valid(opp):
		return
	t += d
	moved += (opp.global_position - last_pos).length() / BB.IN
	last_pos = opp.global_position
	var sp := opp.speed_in_s()
	top_speed = maxf(top_speed, sp)
	# Parked at the firing spot is doing its job, not idling.
	var ai2: AIDriver = main.ai
	if sp < 2.0 and ai2 and ai2.mode != AIDriver.Mode.SHOOT:
		idle += d
	picked_peak = maxi(picked_peak, opp.hopper.size())
	if opp.hopper.size() >= BB.HOPPER_CAP:
		ever_full = true
	# Pinned against the HIVE legs is the specific failure this is here for:
	# the bot used to drive at a ball with a leg in the way and grind on it for
	# the rest of the match.
	# Standing still to SHOOT is not being jammed — the firing spot happens to
	# sit within a robot's length of a leg.
	var ai: AIDriver = main.ai
	if sp < 2.5 and _near_leg() and ai and ai.mode != AIDriver.Mode.SHOOT:
		jammed += d
		jam_gap = 0.0
	else:
		jam_gap += d
	if t > RUN_S:
		_report()

## Within a robot's reach of one of the four HIVE legs.
func _near_leg() -> bool:
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var lx: float = BB.HIVE_FRAME_X * sx
			var ly: float = BB.HIVE_FRAME_FOOT * sy
			if Vector2(opp.fx() - lx, opp.fy() - ly).length() < 14.0:
				return true
	return false

func _report() -> void:
	set_physics_process(false)
	_ok("it collects POLLEN", picked_peak >= 1, true)
	_ok("it fills up to the legal four", ever_full, true)
	_ok("it never exceeds four", picked_peak <= BB.HOPPER_CAP, true)
	_ok("it takes shots", shots >= 4, true)
	_ok("it scores", tips >= 1, true)
	_ok("it keeps moving when it is not shooting", idle < RUN_S * 0.4, true)
	_ok("it drives at a reasonable pace, not flat out",
		top_speed > 15.0 and top_speed < opp.max_speed_in_s * 0.92, true)
	_ok("it never gets pinned on the HIVE legs", jammed < 3.0, true)
	_ok("it stays on the field",
		absf(opp.fx()) < BB.FIELD_HALF and absf(opp.fy()) < BB.FIELD_HALF, true)
	print("\n  in %.0f s: peak hopper %d, %d shots, %d tips" % [
		RUN_S, picked_peak, shots, tips])
	print("  drove %.0f ft, top speed %.1f in/s, idle %.1f s, jammed on a leg %.1f s" % [
		moved / 12.0, top_speed, idle, jammed])
	print("  %s  (%d failures)" % [
		"THE OPPONENT PLAYS" if fails == 0 else "THE OPPONENT IS BROKEN", fails])
	get_tree().quit(1 if fails > 0 else 0)
