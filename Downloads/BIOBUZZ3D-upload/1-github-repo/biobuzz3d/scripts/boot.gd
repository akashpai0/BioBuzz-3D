extends Node
##
## THE PROCESS'S FRONT DOOR. Reads the command line once. The game is the
## game: hosting and joining rooms both happen inside it (Play -> Online
## practice). The only other mode is for the automated tests:
##
##   -- --host-test --port N [--owner NAME] [--invite-file PATH] [--grace S]
##        a headless copy of the game hosting a same-network room with no
##        local player; the joiner called NAME gets the host's controls.
##

func _ready() -> void:
	NetRole.parse(OS.get_cmdline_user_args())
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	if NetRole.mode == "host-test":
		await get_tree().create_timer(1.5).timeout
		var net: NetClient = main.net
		var inv := net.host_headless("Test room", int(NetRole.arg("port", "24600")),
			String(NetRole.arg("owner", "")))
		if inv == "":
			print("[host-test] could not open port")
			get_tree().quit(3)
			return
		var f := String(NetRole.arg("invite-file", ""))
		if f != "":
			var fa := FileAccess.open(f + ".tmp", FileAccess.WRITE)
			fa.store_string(inv)
			fa.close()
			DirAccess.rename_absolute(f + ".tmp", f)
		print("[host-test] invite %s" % inv)
		net.room.closed.connect(func(_w: String) -> void: get_tree().quit(0))
