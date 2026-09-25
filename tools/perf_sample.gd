extends Node
## PERFORMANCE SAMPLE — supplied by the independent reviewer, kept verbatim.
##
## This is the harness that produced the 295.6 avg FPS / 180.03 physics-steps
## figure in ASSESSMENT.md on a Ryzen 7 5800X + RTX 2080 Ti. It is included so
## that the SAME measurement can be repeated on the same machine after this
## pass, which changed process modes across the whole tree, and on the team
## laptops that actually have to run this.
##
##   godot --path . --resolution 1600x900 tools/perf_sample.tscn
##
## Four robots, three AI drivers, 56 elements, VSync off, 20 s after warm-up.
## Run it windowed with nothing else on the GPU, and report the machine.
var main: Node3D
var samples: Array[float] = []
var active := false
var begin_usec := 0
var last_usec := 0
var first_physics := 0
func _ready() -> void:
	Leaderboard.set_player_name("Review")
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout
	await main._on_menu_start(BB.Mode.FREE_PRACTICE, BB.Alliance.RED, 1,
		{"robots": 2, "mate_is_ai": true, "per_robot": 1, "opponents": 2, "takes_nectar": true})
	main.robot.auto_drive = true
	Settings.set_value("video/vsync", 0.0, false)
	Engine.max_fps = 0
	await get_tree().create_timer(3.0).timeout
	print("PERF cpu=", OS.get_processor_name(), " processors=", OS.get_processor_count(),
		" gpu=", RenderingServer.get_video_adapter_name(),
		" renderer=", RenderingServer.get_current_rendering_method(),
		" window=", DisplayServer.window_get_size(),
		" robots=", main.robots.size(), " ais=", main.ais.size(),
		" elements=", get_tree().get_nodes_in_group("element").size())
	begin_usec = Time.get_ticks_usec()
	last_usec = begin_usec
	first_physics = Engine.get_physics_frames()
	active = true
func _process(_delta: float) -> void:
	if not active:
		return
	var now := Time.get_ticks_usec()
	var elapsed := float(now-begin_usec)/1000000.0
	samples.append(float(now-last_usec)/1000.0)
	last_usec = now
	main.robot.set_drive(sin(elapsed)*0.6, 0.15, 0.4)
	if elapsed < 20.0:
		return
	active = false
	samples.sort()
	print("PERF seconds=", elapsed, " frames=", samples.size(),
		" average_fps=", samples.size()/elapsed,
		" frame_ms_p50=", samples[int(samples.size()*0.5)],
		" frame_ms_p95=", samples[int(samples.size()*0.95)],
		" frame_ms_p99=", samples[int(samples.size()*0.99)],
		" physics_steps_per_wall_second=", float(Engine.get_physics_frames()-first_physics)/elapsed)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://_shots/review_gameplay_1600x900.png")
	get_tree().quit()
