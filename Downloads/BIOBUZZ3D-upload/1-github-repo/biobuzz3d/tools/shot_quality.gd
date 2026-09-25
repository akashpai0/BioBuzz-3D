extends Node
## Renders the same match moment at each graphics preset into res://_shots/
## (quality_<preset>_<w>x<h>.png) so the presets can be compared side by side.
var main: Node3D

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_shots"))
	Leaderboard.set_player_name("Shot")
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(1.5).timeout
	main._on_menu_start(BB.Mode.FREE_PRACTICE if "FREE_PRACTICE" in BB.Mode else BB.Mode.FULL_MATCH,
		BB.Alliance.RED, 1, {"robots": 1, "mate_is_ai": true, "per_robot": 1,
		"opponents": 2, "takes_nectar": false})
	await get_tree().create_timer(3.0).timeout
	var sz := get_viewport().get_visible_rect().size
	var f3 := InputEventKey.new(); f3.keycode = KEY_F3; f3.pressed = true
	main._input(f3)
	for q in 4:
		Settings.apply_preset(q)
		for i in 8:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "res://_shots/quality_%s_%dx%d.png" % [
			Settings.QUALITY_NAMES[q].to_lower(), int(sz.x), int(sz.y)]
		img.save_png(ProjectSettings.globalize_path(path))
		print("saved ", path)
	Settings.apply_preset(2)
	get_tree().quit()
