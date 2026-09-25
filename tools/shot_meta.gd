extends Node
## Screenshots of the sign-in and leaderboard screens.
var main: Node3D

func _ready() -> void:
	# force the first-run state so the sign-in screen appears
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Leaderboard.PROFILE_PATH))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(1.5).timeout
	await _snap("signin")

	# sign in, then show the board (the leaderboard test seeded some runs)
	Leaderboard.set_player_name("Julian")
	if main.signin:
		main.signin._field.text = "Julian"
		main.signin._go()
	await get_tree().create_timer(0.6).timeout
	main.menu._open_board()
	await get_tree().create_timer(0.6).timeout
	await _snap("leaderboard")
	get_tree().quit()

func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://_shots/%s.png" % name)
	print("saved %s" % name)
