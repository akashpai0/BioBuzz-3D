extends Node
## FRAME COST PROBE. Starts a full match (2 v 2: our robot + AI mate, two AI
## opponents) and prints, once a second, what each frame costs:
##   fps, process ms, physics ms (all physics ticks in that frame), ticks/frame
## Runs the same on the desktop and in the browser (the browser build prints
## to the console), so the two can be compared.
var main: Node3D
var t := 0.0
var frames := 0
var samples: Array = []

func _ready() -> void:
	Leaderboard.set_player_name("Perf")
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.0).timeout
	main._on_menu_start(BB.Mode.FULL_MATCH, BB.Alliance.RED, 1,
		{"robots": int(OS.get_environment("PERF_ROBOTS") if OS.get_environment("PERF_ROBOTS") != "" else "2"), "mate_is_ai": true, "per_robot": 1, "opponents": int(OS.get_environment("PERF_OPP") if OS.get_environment("PERF_OPP") != "" else "2"), "takes_nectar": false})
	await get_tree().create_timer(3.0).timeout
	print("PERF start (%s)" % ("browser" if OS.has_feature("web") else OS.get_name()))

func _process(d: float) -> void:
	if main == null or main.mm == null or not main.mm.in_progress():
		return
	frames += 1
	t += d
	samples.append([Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])
	if t >= 1.0:
		var p := 0.0
		var ph := 0.0
		for s in samples:
			p += s[0]; ph += s[1]
		print("PERF fps %d  process %.1f ms  physics %.1f ms/frame  (%.1f ticks/frame)" % [
			frames, p / samples.size(), ph / samples.size(), 180.0 / maxf(frames, 1)])
		t = 0.0
		frames = 0
		samples.clear()
