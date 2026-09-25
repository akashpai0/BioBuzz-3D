class_name NetHud
extends CanvasLayer
##
## THE ROOM WHILE A RUN IS ON. Every number here is the host's simulation's: clock,
## phase, scoreboard, hoppers and batteries come from the snapshot on screen,
## opponent status and the event log from the room's slow channel.
##
## The personal menu (Esc) is on this layer too, because opening it must NOT
## pause anyone else: it neutralises this player's controls and says so.
##

var client: NetClient
var _root: Control
var _clock: Label
var _phase: Label
var _red: Label
var _blue: Label
var _room: RichTextLabel
var _me: RichTextLabel
var _log: RichTextLabel
var _obj: RichTextLabel
var _notice: Label
var _notice_left := 0.0
var _banner: PanelContainer
var _banner_box: VBoxContainer
var _banner_sig := ""
var _menu: PanelContainer
var _menu_box: VBoxContainer
var _menu_sig := ""
var _count_end_ms := 0
var _last_state := ""
var _hint: Label

func build() -> void:
	layer = 12
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	# ---- clock and score, top centre
	var top := _panel()
	top.anchor_left = 0.5
	top.anchor_right = 0.5
	top.offset_left = -300
	top.offset_right = 300
	top.offset_top = 8
	_root.add_child(top)
	var tv := Gui.vbox(0)
	top.add_child(tv)
	var srow := Gui.hbox(Gui.S24)
	srow.alignment = BoxContainer.ALIGNMENT_CENTER
	tv.add_child(srow)
	_red = Gui.label("", 34, Gui.RED_INK)
	srow.add_child(_red)
	_clock = Gui.label("", 44, Gui.INK)
	srow.add_child(_clock)
	_blue = Gui.label("", 34, Gui.BLUE_INK)
	srow.add_child(_blue)
	_phase = Gui.label("", 14, Gui.MUTED)
	_phase.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(_phase)
	# ---- room, top left
	var tl := _panel()
	tl.position = Vector2(16, 12)
	tl.custom_minimum_size = Vector2(360, 0)
	_root.add_child(tl)
	_room = _rich(340)
	tl.add_child(_room)
	# ---- objective, top right
	var tr := _panel()
	tr.anchor_left = 1.0
	tr.anchor_right = 1.0
	tr.offset_left = -376
	tr.offset_right = -16
	tr.offset_top = 12
	_root.add_child(tr)
	_obj = _rich(340)
	tr.add_child(_obj)
	# ---- my robot, bottom left
	var bl := _panel()
	bl.anchor_top = 1.0
	bl.anchor_bottom = 1.0
	bl.offset_left = 16
	bl.offset_top = -200
	bl.offset_bottom = -40
	bl.custom_minimum_size = Vector2(360, 0)
	_root.add_child(bl)
	_me = _rich(340)
	bl.add_child(_me)
	# ---- event log, bottom right
	var br := _panel()
	br.anchor_left = 1.0
	br.anchor_right = 1.0
	br.anchor_top = 1.0
	br.anchor_bottom = 1.0
	br.offset_left = -396
	br.offset_right = -16
	br.offset_top = -200
	br.offset_bottom = -40
	_root.add_child(br)
	_log = _rich(360)
	br.add_child(_log)
	# ---- hint and notice
	_hint = Gui.label("Esc: your menu (the room keeps playing) · C: camera", 13, Gui.MUTED)
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.anchor_left = 0.5
	_hint.anchor_right = 0.5
	_hint.offset_left = -300
	_hint.offset_right = 300
	_hint.offset_top = -30
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_hint)
	_notice = Gui.label("", 17, Gui.WARN, true)
	_notice.anchor_left = 0.5
	_notice.anchor_right = 0.5
	_notice.offset_left = -420
	_notice.offset_right = 420
	_notice.offset_top = 112
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_notice.add_theme_constant_override("outline_size", 6)
	_root.add_child(_notice)
	# ---- centre banner: countdown, pause, loading, results
	_banner = _panel()
	_banner.anchor_left = 0.5
	_banner.anchor_right = 0.5
	_banner.anchor_top = 0.5
	_banner.anchor_bottom = 0.5
	_banner.offset_left = -360
	_banner.offset_right = 360
	_banner.offset_top = -170
	_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	_banner.visible = false
	_root.add_child(_banner)
	_banner_box = Gui.vbox(10)
	_banner.add_child(_banner_box)
	# ---- personal menu
	_menu = _panel()
	_menu.anchor_left = 0.5
	_menu.anchor_right = 0.5
	_menu.anchor_top = 0.5
	_menu.anchor_bottom = 0.5
	_menu.offset_left = -330
	_menu.offset_right = 330
	_menu.offset_top = -230
	_menu.visible = false
	_root.add_child(_menu)
	_menu_box = Gui.vbox(10)
	_menu.add_child(_menu_box)

func open() -> void:
	_root.visible = true
	refresh()

func close() -> void:
	_root.visible = false

func is_open() -> bool:
	return _root.visible

func notice(t: String) -> void:
	_notice.text = t
	_notice_left = 7.0

func show_result(_r: Dictionary) -> void:
	_banner_sig = ""
	refresh()

func refresh() -> void:
	if client == null or client.session == null:
		return
	_banner_sig = ""
	_menu_sig = ""
	tick()

# ================================================================= frame ===

func tick() -> void:
	if not _root.visible:
		return
	var dt := get_process_delta_time()
	if _notice_left > 0.0:
		_notice_left -= dt
		if _notice_left <= 0.0:
			_notice.text = ""
	var s := client.session
	var st: Dictionary = s.state
	var state := String(st.get("state", ""))
	if state != _last_state:
		_last_state = state
		if state == "countdown":
			_count_end_ms = Time.get_ticks_msec() + int(st.get("countdown_ms", 3000))
	# ---- scoreboard from the snapshot on screen
	var sn := client.shown()
	if not sn.is_empty():
		var row: PackedFloat32Array = sn["row"]
		var free := int(row[7]) & 2 == 2
		var names := ["Pre-match", "Autonomous", "Transition", "Teleop", "Settling", "Finished"]
		_put(_clock, "--:--" if free else BB.clock_text(row[1]))
		_put(_red, str(int(row[3])))
		_put(_blue, str(int(row[4])))
		_put(_phase, "%s · %s · online, the host's clock and score" % [
			names[clampi(int(row[2]), 0, 5)], "free practice" if free else "match clock"])
	# ---- room line
	var lines: Array = ["[b]%s[/b]  ·  %s" % [s.room_name, "you are hosting" if client.hosting
		else ("hosted by %s" % LobbyScreen._host_name(st))]]
	var conn := LobbyScreen._quality(s.ping_ms, s.loss())
	if client.hosting:
		conn = "this computer runs the room"
	elif s.route == "relayed":
		conn += " · via Epic relay"
	elif s.route == "direct":
		conn += " · direct"
	if s.phase == "reconnecting":
		conn = "[color=#FFB066]lost — reconnecting…[/color]"
	lines.append("Connection: %s" % conn)
	for p in st.get("parts", []):
		var tag := ""
		if not bool(p["connected"]):
			tag = " [color=#FF8588]away %d s[/color]" % int(p.get("grace", 0))
		elif int(p.get("pid", -1)) != s.pid and float(p.get("ping", -1.0)) >= 0.0:
			tag = " · %d ms%s" % [int(p["ping"]), " (relay)" if String(p.get("route", "")) == "relayed" else ""]
		if bool(p["connected"]) and bool(p["menu"]):
			tag = " [color=#FFB066]in a menu — neutral[/color]"
		elif bool(p["connected"]) and bool(p.get("needs_neutral", false)) and not (p.get("seat", []) as Array).is_empty():
			tag = " [color=#FFB066]let go of the controls[/color]"
		lines.append("%s%s — %s%s" % [p["name"], " ★" if bool(p["owner"]) else "",
			LobbyScreen._seat_text(p.get("seat", []), st.get("seats", [])), tag])
	_put(_room, "\n".join(lines))
	# ---- my robot
	var r := client.my_robot()
	var mine: Array = []
	if r < 0:
		mine.append("[b]Spectating[/b] — you can take a seat in the lobby or during a pause.")
	else:
		mine.append("[b]You: Robot %d · %s[/b]" % [r + 1, {"whole": "whole robot",
			"driver": "driver", "operator": "operator"}.get(client.my_role(), "")])
		if not sn.is_empty():
			var row2: PackedFloat32Array = sn["row"]
			var o := ReplayRecorder.HEAD + r * ReplayRecorder.PER_ROBOT
			mine.append("hopper %d · battery %.1f V" % [int(row2[o + 9]), row2[o + 11]])
		for rs in s.slow.get("robots", []):
			if int(rs.get("i", -1)) == r:
				mine.append("launcher %d in/s · auto-aim %s · %s · intake %s" % [
					int(rs.get("launch", 0)), "on" if bool(rs.get("auto_aim", false)) else "off",
					"field-centric" if bool(rs.get("field_centric", false)) else "robot-centric",
					"on" if bool(rs.get("intake", true)) else "off"])
				if bool(rs.get("locked", false)):
					mine.append("[color=#A9D994]turret locked · %d in[/color]" % int(rs.get("dist", 0)))
				elif bool(rs.get("blocked", false)):
					mine.append("[color=#FFB066]wrong side of the CELL mouth[/color]")
		if client.menu_open:
			mine.append("[color=#FFB066]Your controls are neutral while your menu is open.[/color]")
	_put(_me, "\n".join(mine))
	var ev: Array = s.slow.get("events", [])
	_put(_log, "[b]EVENT LOG[/b]\n[font_size=13]" + "\n".join(ev.slice(maxi(0, ev.size() - 8))) + "[/font_size]")
	var obj: Dictionary = s.slow.get("objective", {})
	if obj.is_empty():
		var opp: Array = []
		for rs2 in s.slow.get("robots", []):
			if String(rs2.get("status", "")) != "":
				opp.append("%s: %s" % [rs2.get("label", ""), rs2.get("status", "")])
		_put(_obj, "[b]OPPONENTS[/b]\n" + "\n".join(opp) if not opp.is_empty() else "[b]No objective[/b]\nFree practice with the room.")
	else:
		_put(_obj, "[b]OBJECTIVE[/b]\n%s\n[b]%s[/b] · %s%s" % [obj.get("text", ""), obj.get("status", ""),
			obj.get("time", ""), "\n[color=#FFB066]confirming…[/color]" if bool(obj.get("pending", false)) else ""])
	_update_banner(st, state)
	_update_menu()

func _update_banner(st: Dictionary, state: String) -> void:
	var sig := state + JSON.stringify(st.get("requests", [])) + String(st.get("pause_reason", "")) \
		+ JSON.stringify(client.session.result) + str(client.owner())
	for p in st.get("parts", []):
		sig += "%s%s%s" % [p["connected"], p.get("restored", false), p.get("seat", [])]
	if state == "countdown":
		var left := maxi(0, _count_end_ms - Time.get_ticks_msec())
		sig += str(int(ceil(left / 1000.0)))
	if sig == _banner_sig:
		return
	_banner_sig = sig
	for c in _banner_box.get_children():
		c.queue_free()
	var owner := client.owner()
	var show := true
	match state:
		"countdown":
			var left2 := maxi(0, _count_end_ms - Time.get_ticks_msec())
			_banner_box.add_child(_big(str(maxi(1, int(ceil(left2 / 1000.0))))))
			_banner_box.add_child(_center("Starting together…"))
		"loading":
			_banner_box.add_child(_title("Setting the field"))
			var waiting: Array = []
			for p in st.get("parts", []):
				if not (p.get("seat", []) as Array).is_empty() and not bool(p.get("restored", false)):
					waiting.append(p["name"])
			_banner_box.add_child(_center("Waiting for: %s" % ", ".join(waiting) if not waiting.is_empty() else "Everyone has it."))
		"paused":
			_banner_box.add_child(_title("Paused"))
			_banner_box.add_child(_center(String(st.get("pause_reason", ""))))
			var seats_btn := _btn("Seats and roles…", func() -> void: client.lobby.open())
			seats_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			_banner_box.add_child(seats_btn)
			if owner:
				var row := Gui.hbox(Gui.S8)
				row.alignment = BoxContainer.ALIGNMENT_CENTER
				row.add_child(_btn("Resume", func() -> void: client.send(NetProto.RESUME), true))
				row.add_child(_btn("Retry", func() -> void: client.send(NetProto.RETRY)))
				row.add_child(_btn("Back to lobby", func() -> void: client.send(NetProto.LOBBY)))
				row.add_child(_btn("End session", func() -> void: client.leave("")))
				_banner_box.add_child(row)
				_reassign_rows(st)
			else:
				_banner_box.add_child(_center("The host resumes."))
		"results":
			_result_card(client.session.result, owner)
		_:
			show = false
	# requests reach the owner wherever they are
	if owner and state in ["running", "countdown", "paused"]:
		for rq in st.get("requests", []):
			var who := ""
			for p2 in st.get("parts", []):
				if int(p2["pid"]) == int(rq["pid"]):
					who = String(p2["name"])
			var h := Gui.hbox(Gui.S8)
			h.add_child(Gui.label("%s asks to %s." % [who, rq["kind"]], Gui.T_BODY, Gui.WARN))
			var kind := String(rq["kind"])
			h.add_child(_btn("Do it", func() -> void:
				client.send(NetProto.PAUSE if kind == "pause" else NetProto.RETRY)))
			_banner_box.add_child(h)
			show = true
	_banner.visible = show

func _reassign_rows(st: Dictionary) -> void:
	var parts: Array = st.get("parts", [])
	var away := {}
	for p in parts:
		if not bool(p["connected"]):
			away[int(p["pid"])] = p
	var free_people: Array = []
	for p2 in parts:
		if bool(p2["connected"]) and (p2.get("seat", []) as Array).is_empty():
			free_people.append(p2)
	for row in st.get("seats", []):
		for role in ["whole", "driver", "operator"]:
			var holder := int(row[role])
			if not away.has(holder):
				continue
			var h := Gui.hbox(Gui.S8)
			h.add_child(Gui.label("Robot %d %s (%s, away): " % [int(row["robot"]) + 1, role,
				away[holder]["name"]], Gui.T_SMALL, Gui.MUTED))
			for fp in free_people:
				var to := int(fp["pid"])
				var rb := int(row["robot"])
				h.add_child(_btn("Give to %s" % fp["name"], func() -> void:
					client.send(NetProto.REASSIGN, {"robot": rb, "role": role, "to": to})))
			if free_people.is_empty():
				h.add_child(Gui.label("nobody free to take it", Gui.T_SMALL, Gui.MUTED))
			_banner_box.add_child(h)

func _result_card(r: Dictionary, owner: bool) -> void:
	if String(r.get("kind", "")) == "attempt":
		var good := String(r.get("state", "")) == "succeeded"
		_banner_box.add_child(_title("Objective completed" if good else "Objective failed"))
		_banner_box.add_child(_center(String(r.get("objective", ""))))
		_banner_box.add_child(_center("%d / %d · %.1f s · %d points · %d of %d shots made · %d foul points" % [
			int(r.get("progress", 0)), int(r.get("goal", 0)), float(r.get("elapsed", 0.0)),
			int(r.get("points", 0)), int(r.get("made", 0)), int(r.get("shots", 0)), int(r.get("fouls", 0))]))
	else:
		_banner_box.add_child(_title("Match over"))
		_banner_box.add_child(_big("%d – %d" % [int(r.get("red", 0)), int(r.get("blue", 0))]))
		_banner_box.add_child(_center("RED – BLUE, scored by the host's game from the field at rest"))
	_banner_box.add_child(_center("Run %d. Your replay of it is in Progress → Replays." % int(r.get("attempt_no", 0)),
		Gui.MUTED))
	var row := Gui.hbox(Gui.S8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	if owner:
		row.add_child(_btn("Retry for everyone", func() -> void: client.send(NetProto.RETRY), true))
		row.add_child(_btn("Back to lobby", func() -> void: client.send(NetProto.LOBBY)))
		row.add_child(_btn("End session", func() -> void: client.leave("")))
	else:
		row.add_child(_btn("Ask for a retry", func() -> void: client.send(NetProto.RETRY), true))
		row.add_child(_btn("Leave room", func() -> void: client.leave("You left the room.")))
	_banner_box.add_child(row)

func _update_menu() -> void:
	var sig := "%s%s%s" % [client.menu_open, client.owner(), client.room_state()]
	if sig == _menu_sig:
		return
	_menu_sig = sig
	_menu.visible = client.menu_open
	for c in _menu_box.get_children():
		c.queue_free()
	if not client.menu_open:
		return
	_menu_box.add_child(_title("Your menu"))
	_menu_box.add_child(_center("Online play continues. Your controls are neutral while this menu is open, and everyone can see that.", Gui.WARN))
	var owner := client.owner()
	var col := Gui.vbox(8)
	_menu_box.add_child(col)
	col.add_child(_btn("Back to the field", func() -> void: client.set_menu(false), true))
	if owner:
		col.add_child(_btn("Pause the room", func() -> void:
			client.send(NetProto.PAUSE)
			client.set_menu(false)))
		col.add_child(_btn("Retry for everyone", func() -> void:
			client.send(NetProto.RETRY)
			client.set_menu(false)))
		col.add_child(_btn("Back to lobby", func() -> void:
			client.send(NetProto.LOBBY)
			client.set_menu(false)))
	else:
		col.add_child(_btn("Ask the owner to pause", func() -> void:
			client.send(NetProto.PAUSE)
			notice("Pause requested.")))
		col.add_child(_btn("Ask the owner for a retry", func() -> void:
			client.send(NetProto.RETRY)
			notice("Retry requested.")))
	col.add_child(_btn("Settings (controls, camera, sound)", func() -> void:
		client.main.settings_menu.open()))
	col.add_child(_btn("Leave room", func() -> void: client.leave("You left the room.")))

# ================================================================ bits ===

func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Gui.PANEL.r, Gui.PANEL.g, Gui.PANEL.b, 0.88)
	sb.border_color = Gui.LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(Gui.R_CTRL)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	p.add_theme_stylebox_override("panel", sb)
	return p

func _rich(w: int) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.custom_minimum_size = Vector2(w, 0)
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.add_theme_font_size_override("normal_font_size", Gui.T_SMALL)
	r.add_theme_font_size_override("bold_font_size", Gui.T_SMALL)
	r.add_theme_color_override("default_color", Gui.INK)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

func _title(t: String) -> Label:
	var l := Gui.label(t, Gui.T_SECTION, Gui.INK)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

func _center(t: String, col := Gui.INK) -> Label:
	var l := Gui.label(t, Gui.T_BODY, col, true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(660, 0)
	return l

func _big(t: String) -> Label:
	var l := Gui.label(t, 72, Gui.ACCENT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

func _btn(t: String, cb: Callable, primary := false) -> Button:
	var b := Gui.primary(t, Vector2(0, 48)) if primary else Gui.button(t, Gui.Look.SECONDARY, Vector2(0, 48))
	b.pressed.connect(func() -> void:
		SFX.play("select", -14.0)
		cb.call())
	return b

static func _put(c: Control, text: String) -> void:
	if c is RichTextLabel:
		if (c as RichTextLabel).text != text:
			(c as RichTextLabel).text = text
	elif c is Label and (c as Label).text != text:
		(c as Label).text = text
