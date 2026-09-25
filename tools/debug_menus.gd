extends Node
## THE MENU WIRING, TESTED AS BEHAVIOUR.
##
## Screenshots prove a page looks right; this proves the buttons do something.
## Pausing behind the menus must not cost you the match, a seat pinned to a
## device must actually get that device, and a change made in the Garage must
## reach the robot that gets built.

var main: Node3D
var fails := 0

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.0).timeout
	print("\n--- MENU WIRING ---")

	await _pause_keeps_the_match()
	await _seat_pinning()
	await _garage_reaches_the_robot()
	_settings_persist()

	print("  %s  (%d failure%s)" % [
		"THE MENUS ARE WIRED UP" if fails == 0 else "MENU WIRING BROKEN",
		fails, "" if fails == 1 else "s"])
	get_tree().quit(1 if fails > 0 else 0)

## ESC out of a running match, walk through Settings and the Garage, come back
## — same match, same clock, same score.
func _pause_keeps_the_match() -> void:
	main._on_menu_start(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 1,
		{"robots": 1, "per_robot": 1, "opponents": 0})
	await get_tree().create_timer(2.5).timeout
	_ok("a match is running", main.mm.in_progress(), true)
	var t0: float = main.mm.time_left
	main.mm.scoring.tips[BB.Alliance.RED] = 2

	main.mm.pause()
	main.menu.match_running = true
	main.menu.open()
	main.rig.mode = CameraRig.Mode.MENU
	_ok("pausing does not end the match", main.mm.in_progress(), true)
	_ok("the robots are switched off", main.robot.enabled, false)

	main.goto("Settings", 3)
	await get_tree().create_timer(0.6).timeout
	_ok("settings opened over the paused match", main.settings_menu.is_open(), true)
	_ok("the clock did not move while paused",
		absf(main.mm.time_left - t0) < 0.001, true)

	main.goto("Garage", 0)
	await get_tree().create_timer(0.4).timeout
	main.goto("Play")
	await get_tree().create_timer(0.4).timeout
	_ok("back on Play the match is still running", main.mm.in_progress(), true)
	# Play shows the PAUSE MENU over the match rather than resuming behind the
	# player's back: coming back from Settings should not drop you into a live
	# robot you were not holding.
	_ok("  and Play is showing the pause menu", main.menu.match_running, true)
	_ok("  the same score", int(main.mm.scoring.tips[BB.Alliance.RED]), 2)
	main.menu.close()
	main._resume_match()
	await get_tree().create_timer(0.1).timeout
	_ok("  and Resume puts the robots back live", main.robot.enabled, true)
	# it is running again, so it has moved — but only by the time since resume,
	# not by the whole trip through the menus
	_ok("  and the clock picked up where it stopped",
		(t0 - main.mm.time_left) < 0.8, true)
	main.mm.abort()
	main.menu.match_running = false

## A seat pinned to a device in Settings has to get that device.
func _seat_pinning() -> void:
	Settings.seats.clear()
	Settings.set_seat_device(0, -1)          # robot 1 driver -> keyboard
	main._build_robots(BB.Alliance.RED, 1)
	await get_tree().create_timer(0.3).timeout
	_ok("a pinned seat gets its device", main.robot.device, -1)
	# a pin to a device that is not plugged in must fall back, not go dead
	Settings.set_seat_device(0, 7)
	main._build_robots(BB.Alliance.RED, 1)
	await get_tree().create_timer(0.3).timeout
	_ok("a pin to a missing controller falls back",
		main.robot.device > DriverInput.NONE, true)
	Settings.seats.clear()
	Settings.save_to_disk()

## Changing the robot in the Garage has to reach the robot that gets built.
func _garage_reaches_the_robot() -> void:
	main.goto("Garage", 0)
	await get_tree().create_timer(0.4).timeout
	main.menu.robot_intakes = 2
	main.menu.takes_nectar = true
	main.goto("Play")
	await get_tree().create_timer(0.6).timeout
	_ok("the Garage's intake count reached the robot", main.robot.intakes, 2)
	main.menu.started.emit(BB.Mode.TELEOP_ONLY, BB.Alliance.RED, 2, {
		"robots": 1, "mate_is_ai": false, "per_robot": 1, "opponents": 0,
		"takes_nectar": true})
	await get_tree().create_timer(2.0).timeout
	_ok("  and so did pollen + nectar", main.robot.takes_nectar, true)
	main.mm.abort()
	main.menu.robot_intakes = 1
	main.menu.takes_nectar = false

## Settings are on disk before your hand leaves the mouse.
func _settings_persist() -> void:
	var was := Settings.get_value("audio/crowd")
	Settings.set_value("audio/crowd", 0.31)
	var cfg := ConfigFile.new()
	cfg.load(Settings.PATH)
	_ok("a slider is on disk immediately",
		absf(float(cfg.get_value("audio", "crowd", 0.0)) - 0.31) < 0.001, true)
	Settings.set_value("audio/crowd", was)

func _ok(what: String, got: Variant, want: Variant) -> void:
	var pass_: bool = str(got) == str(want)
	if not pass_:
		fails += 1
	print("  %s %-46s got %s   want %s" % [
		"PASS" if pass_ else "FAIL", what, str(got), str(want)])
