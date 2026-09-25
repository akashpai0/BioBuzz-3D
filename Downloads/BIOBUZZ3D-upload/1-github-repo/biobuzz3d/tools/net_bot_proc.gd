extends Node
## A PLAYER IN ITS OWN PROCESS, for tests that need a second, separate
## program on the network (not just a second connection in one process).
##
##   godot --headless --path . res://tools/net_bot_proc.tscn -- \
##       --invite-file /tmp/invite.txt --seat 0:operator \
##       --fire-every 0.8 --for 20 --out /tmp/bot.json [--net-sim 60,15,0.02]
##
## Joins with the invite in --invite-file (waits for it to appear), takes the
## seat, readies, and while the run is on does what it is told. At the end it
## writes what it saw: its snapshot rows by server tick, and what it did.

var bot := NetBot.new("Operator bot")
var args := {}

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	var i := 0
	while i < a.size():
		if String(a[i]).begins_with("--") and i + 1 < a.size():
			args[String(a[i]).substr(2)] = String(a[i + 1])
			i += 2
		else:
			i += 1
	bot.s.sim_spec = String(args.get("net-sim", ""))
	var inv_file := String(args.get("invite-file", ""))
	var invite := ""
	var t0 := Time.get_ticks_msec()
	while invite == "" and Time.get_ticks_msec() - t0 < 60000:
		if FileAccess.file_exists(inv_file):
			invite = FileAccess.get_file_as_string(inv_file).strip_edges()
		await get_tree().create_timer(0.2).timeout
	bot.name = String(args.get("name", "Operator bot"))
	bot.join(invite)
	await _until(func() -> bool: return bot.s.phase in ["in_room", "failed"], 20.0)
	if bot.s.phase != "in_room":
		_finish({"error": bot.s.error_text})
		return
	var seat := String(args.get("seat", "0:operator")).split(":")
	await _until(func() -> bool: return bot.s.scenario_rev >= 1, 30.0)
	bot.s.send(NetProto.SEAT, {"robot": int(seat[0]), "role": seat[1]})
	await _pump(0.5)
	bot.s.send(NetProto.READY, {"on": true})
	# like a person: if a change in the lobby clears Ready, press it again
	var last_ask := {"t": 0}
	await _until(func() -> bool:
		var me := bot.s.my_part()
		if bot.room_state() == "lobby" and not me.is_empty() and not bool(me.get("ready", false)) \
				and bool(me.get("acked", false)) and Time.get_ticks_msec() - int(last_ask["t"]) > 700:
			last_ask["t"] = Time.get_ticks_msec()
			if (bot.s.my_seat() as Array).is_empty():
				bot.s.send(NetProto.SEAT, {"robot": int(seat[0]), "role": seat[1]})
			bot.s.send(NetProto.READY, {"on": true})
		return bot.room_state() == "running", 90.0)
	bot.send_inputs = true
	var every := float(args.get("fire-every", "0"))
	var dur := float(args.get("for", "15"))
	var fired := 0
	var t1 := Time.get_ticks_msec()
	var next_fire := 0.5
	var rows := {}
	while Time.get_ticks_msec() - t1 < int(dur * 1000.0) and bot.s.phase == "in_room":
		var el := float(Time.get_ticks_msec() - t1) / 1000.0
		if every > 0.0:
			bot.hold("fire", el >= next_fire and el < next_fire + 0.15)
			if el >= next_fire + 0.15:
				next_fire += every
				fired += 1
		bot.poll()
		for sn in bot.s.snaps:
			if rows.size() < 8000:
				rows[str(sn["tick"])] = Array(sn["row"] as PackedFloat32Array)
		await get_tree().process_frame
	# the run is over, or the host ended the session: keep listening briefly
	var t2 := Time.get_ticks_msec()
	while bot.s.phase == "in_room" and Time.get_ticks_msec() - t2 < 1000:
		bot.poll()
		await get_tree().process_frame
	_finish({"fired": fired, "rows": rows, "pid": bot.s.pid, "seat": bot.s.my_seat(),
		"end": bot.s.error_text,
		"snaps_in": bot.s.snaps_in, "bytes_in": bot.s.room.bytes_in, "bytes_out": bot.s.room.bytes_out})

func _finish(d: Dictionary) -> void:
	# written beside, then renamed, so the reader never sees half a file
	var dest := String(args.get("out", "user://bot.json"))
	var f := FileAccess.open(dest + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
	DirAccess.rename_absolute(dest + ".tmp", dest)
	bot.s.leave()
	get_tree().quit()

func _until(cond: Callable, secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0) and not cond.call():
		bot.poll()
		await get_tree().process_frame

func _pump(secs: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		bot.poll()
		await get_tree().process_frame
