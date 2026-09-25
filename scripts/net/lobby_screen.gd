class_name LobbyScreen
extends CanvasLayer
##
## THE ROOM, BEFORE A RUN: who is here, who holds which seat, what will be
## played, and who is ready. Every seat change goes to the host's room, which
## grants it or says no — two people can never end up holding one role.
##

var client: NetClient
var _s: Dictionary
var _root: Control
var _body: VBoxContainer
var _sig := ""
var _msg: Label
var _conn: Label
var _pick := 0
var _choices: Array = []          # [label, kind, key]

func build() -> void:
	layer = 26
	_s = Gui.shell("Play", func(_p: String) -> void: pass)
	_root = _s["root"]
	_root.visible = false
	add_child(_root)
	for b in (_s["nav"] as Dictionary).values():
		(b as Control).visible = false
	_conn = Gui.label("", Gui.T_SMALL, Gui.MUTED)
	_s["head_right"].add_child(_conn)
	_body = Gui.vbox(Gui.S16)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_s["body"].add_child(_body)
	_s["foot_btn"].pressed.connect(func() -> void:
		SFX.play("select", -12.0)
		var me := client.session.my_part()
		client.send(NetProto.READY, {"on": not bool(me.get("ready", false))}))
	var alt: Button = _s["foot_alt"]
	alt.visible = true
	alt.pressed.connect(func() -> void:
		var paused := client.room_state() == "paused"
		if paused:
			close()                       # back to the field; the owner resumes
		elif client.owner():
			client.send(NetProto.START)
		else:
			client.leave("You left the room."))

func open() -> void:
	if not _root.visible:
		_sig = ""
	_root.visible = true
	refresh()

func close() -> void:
	_root.visible = false

func is_open() -> bool:
	return _root.visible

func show_message(t: String, bad: bool) -> void:
	if _msg:
		_msg.text = t
		_msg.add_theme_color_override("font_color", Gui.RED_INK if bad else Gui.WARN)

## Cheap per-frame update: connection line only.
func tick() -> void:
	if not _root.visible:
		return
	var s := client.session
	var q := "Your connection: %s" % _quality(s.ping_ms, s.loss())
	if client.hosting:
		q = "You are hosting: this computer runs the room."
	elif s.route == "relayed":
		q += " · via Epic relay"
	elif s.route == "direct":
		q += " · direct"
	if s.phase == "reconnecting":
		q = "Connection lost — reconnecting…"
	var others := everyone_line(s)
	_conn.text = q + ("\n" + others if others != "" else "")

## Everyone else's connection as the host measures it, one short line.
static func everyone_line(s: NetSession) -> String:
	var bits: Array = []
	for p in s.state.get("parts", []):
		if int(p.get("pid", -1)) == s.pid:
			continue
		if not bool(p.get("connected", true)):
			bits.append("%s: reconnecting (%d s left)" % [p["name"], int(p.get("grace", 0))])
		elif float(p.get("ping", -1.0)) >= 0.0:
			bits.append("%s %d ms" % [p["name"], int(p["ping"])])
	return " · ".join(bits)

static func _quality(ms: float, loss := 0.0) -> String:
	if ms < 0.0:
		return "measuring…"
	var word := "good" if ms < 90.0 and loss < 0.02 else ("fair" if ms < 160.0 and loss < 0.06 else "poor")
	var extra := (", %d %% loss" % int(round(loss * 100.0))) if loss >= 0.01 else ""
	return "%s (%d ms%s)" % [word, int(ms), extra]

## Rebuild when anything but the ping changed.
func refresh() -> void:
	if not _root.visible or client.session == null:
		return
	var st: Dictionary = client.session.state
	var clean := st.duplicate(true)
	for p in clean.get("parts", []):
		p.erase("rtt")
		p.erase("ping")
		p["grace"] = int(p.get("grace", 0))
	var sig := JSON.stringify(clean) + str(client.session.scenario_rev) + str(client._built_rev)
	if sig == _sig:
		return
	_sig = sig
	_rebuild(st)

func _rebuild(st: Dictionary) -> void:
	for c in _body.get_children():
		c.queue_free()
	var s := client.session
	var me := s.my_part()
	var owner := client.owner()
	_s["eyebrow"].text = "ONLINE ROOM · %s" % ("YOU ARE HOSTING" if client.hosting else "HOSTED BY %s" % _host_name(st).to_upper())
	_s["title"].text = s.room_name if s.room_name != "" else "Online room"

	# ---- code + room controls
	var top := Gui.card(Gui.S8)
	_body.add_child(top[0])
	var th := Gui.hbox(Gui.S16)
	top[1].add_child(th)
	var code_v := Gui.vbox(2)
	var net_word := "INTERNET" if s.code.begins_with(NetInvite.PREFIX + "E") else "SAME NETWORK ONLY"
	code_v.add_child(Gui.label("INVITE · %s" % net_word, Gui.T_EYEBROW, Gui.MUTED))
	code_v.add_child(Gui.label(_short_invite(s.code), Gui.T_BODY, Gui.ACCENT))
	th.add_child(code_v)
	var copy := Gui.button("Copy invite", Gui.Look.SECONDARY, Vector2(0, 46))
	copy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(s.code)
		show_message("Invite copied. Paste it to your team (Discord, text…). It works until this room ends.", false))
	th.add_child(copy)
	var parts: Array = st.get("parts", [])
	var free := 0
	for row in st.get("seats", []):
		if bool(row["ai"]):
			continue
		if int(row["whole"]) < 0 and int(row["driver"]) < 0 and int(row["operator"]) < 0:
			free += 2
		elif int(row["whole"]) < 0:
			free += int(int(row["driver"]) < 0) + int(int(row["operator"]) < 0)
	th.add_child(Gui.label("%d of %d players · %d seat%s free" % [parts.size(),
		int(st.get("capacity", 8)), free, "" if free == 1 else "s"], Gui.T_SMALL, Gui.MUTED))
	th.add_child(Gui.spacer())
	if owner:
		var lock := Gui.button("Joining locked" if bool(st.get("locked", false)) else "Lock joining",
			Gui.Look.OPTION, Vector2(0, 46))
		Gui.select(lock, bool(st.get("locked", false)))
		lock.pressed.connect(func() -> void:
			client.send(NetProto.LOCK, {"on": not bool(st.get("locked", false))}))
		th.add_child(lock)
		var low := int(st.get("snap_every", 3)) > 3
		var rate := Gui.button("Low upload: on" if low else "Low upload: off", Gui.Look.OPTION, Vector2(0, 46))
		Gui.select(rate, low)
		rate.tooltip_text = ("Your game sends every guest about 58 KB/s (≈0.5 Mbit/s) at 60 updates a second. "
			+ "Low upload halves that; guests see the field a little later.")
		rate.pressed.connect(func() -> void: client.send(NetProto.SET_RATE, {"low": not low}))
		th.add_child(rate)
	var leave := Gui.button("End session" if client.hosting else "Leave room", Gui.Look.SECONDARY, Vector2(0, 46))
	leave.tooltip_text = "Ends the room for everyone; everyone keeps their replays" if client.hosting else ""
	leave.pressed.connect(func() -> void: client.leave("You left the room."))
	th.add_child(leave)
	_msg = Gui.label("", Gui.T_SMALL, Gui.WARN, true)
	top[1].add_child(_msg)

	var cols := Gui.two_columns(_body)
	var left: VBoxContainer = cols[0]
	var right: VBoxContainer = cols[1]

	# ---- seats
	var seats_card := Gui.card(Gui.S8)
	left.add_child(seats_card[0])
	var sv: VBoxContainer = seats_card[1]
	sv.add_child(Gui.section("Robots and seats"))
	sv.add_child(Gui.note("Whole robot = one person does everything. Or split it: the driver moves, the operator runs the intake, turret and launcher."))
	var names := {}
	for p in parts:
		names[int(p["pid"])] = p
	var srows: Array = st.get("seats", [])
	if srows.is_empty():
		sv.add_child(Gui.para("The host has not chosen a scenario yet."))
	for row in srows:
		sv.add_child(Gui.divider())
		sv.add_child(_seat_row(row, names, owner))

	# ---- people
	var pc := Gui.card(Gui.S8)
	left.add_child(pc[0])
	pc[1].add_child(Gui.section("People"))
	for p in parts:
		pc[1].add_child(_person_row(p, owner, s.scenario_rev))

	# ---- scenario
	var sc := Gui.card(Gui.S8)
	right.add_child(sc[0])
	var scv: VBoxContainer = sc[1]
	scv.add_child(Gui.section("Scenario"))
	if owner:
		_choices = []
		for k in NetScenario.STANDARD_ORDER:
			_choices.append([String(NetScenario.STANDARD[k]["name"]), "standard", k])
		for e in ScenarioLibrary.list_all():
			if String(e["error"]) == "":
				_choices.append(["Saved: " + String(e["name"]), "saved", String(e["id"])])
		var labels: Array = []
		for c in _choices:
			labels.append(c[0])
		var dd := Gui.dropdown(labels, _pick, func(i: int) -> void: _pick = i, 300)
		dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var prow := Gui.hbox(Gui.S8)
		prow.add_child(dd)
		var share := Gui.button("Use this", Gui.Look.SECONDARY, Vector2(0, 46))
		share.pressed.connect(func() -> void:
			var c: Array = _choices[_pick]
			if String(c[1]) == "standard":
				client.share_standard(String(c[2]))
				show_message("Setting up \"%s\"…" % c[0], false)
			else:
				var err := client.share_situation(String(c[2]))
				show_message(err if err != "" else "Sharing \"%s\"…" % c[0], err != ""))
		prow.add_child(share)
		scv.add_child(prow)
		scv.add_child(Gui.note("Standard setups use your Garage drivetrain profile for every robot."))
	var sm: Dictionary = st.get("scenario", {}).get("summary", {})
	if sm.is_empty():
		scv.add_child(Gui.para("Nothing chosen yet." if owner else "Waiting for the owner to choose a scenario."))
	else:
		scv.add_child(Gui.label(String(sm.get("name", "")), Gui.T_SECTION, Gui.INK))
		scv.add_child(Gui.body("%s · %s · starts at %s" % [sm.get("mode", ""), sm.get("phase", ""), sm.get("clock", "")]))
		scv.add_child(Gui.note("Objective: %s" % sm.get("objective", "")))
		scv.add_child(Gui.note("Drivetrain: %s" % sm.get("hardware", "")))
		for r in sm.get("robots", []):
			scv.add_child(Gui.note("Robot %d · %s · %s%s" % [int(r["index"]) + 1, r["label"],
				BB.alliance_name(int(r["alliance"])), (" · AI: " + String(r["behavior"])) if bool(r["ai"]) else ""]))
		for n in sm.get("notes", []):
			scv.add_child(Gui.label(String(n), Gui.T_SMALL, Gui.WARN, true))
		var loaded := client._built_rev == s.scenario_rev
		scv.add_child(Gui.label("Loaded on this computer." if loaded else "Loading on this computer…",
			Gui.T_SMALL, Gui.GOOD if loaded else Gui.MUTED))
		if s.scenario_error != "":
			scv.add_child(Gui.label(s.scenario_error, Gui.T_SMALL, Gui.RED_INK, true))
		var keep := Gui.button("Save scenario locally", Gui.Look.SECONDARY, Vector2(0, 44))
		keep.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		keep.tooltip_text = "Adds it to your situation library as a new situation; nothing is overwritten"
		keep.pressed.connect(func() -> void:
			var id := client.save_scenario_locally()
			show_message("Saved to your situations." if id != "" else "Could not save it.", id == ""))
		scv.add_child(keep)

	# ---- start
	var go := Gui.card(Gui.S8)
	right.add_child(go[0])
	go[1].add_child(Gui.section("Start"))
	var blockers: Array = st.get("blockers", [])
	if blockers.is_empty():
		go[1].add_child(Gui.label("Everyone needed is ready." if owner else "Everyone needed is ready. The host starts.",
			Gui.T_BODY, Gui.GOOD))
	else:
		for bl in blockers.slice(0, 6):
			go[1].add_child(Gui.label("• " + String(bl), Gui.T_SMALL, Gui.MUTED, true))
	for rq in st.get("requests", []):
		var who: Dictionary = names.get(int(rq["pid"]), {})
		go[1].add_child(Gui.label("%s asks to %s." % [who.get("name", "Someone"), rq["kind"]], Gui.T_SMALL, Gui.WARN))

	# ---- footer
	var paused := String(st.get("state", "")) == "paused"
	if paused:
		var pz := Gui.card(Gui.S8)
		_body.add_child(pz[0])
		_body.move_child(pz[0], 1)
		pz[1].add_child(Gui.section("The room is paused"))
		pz[1].add_child(Gui.para(String(st.get("pause_reason", ""))))
		pz[1].add_child(Gui.note("Change seats now if you need to. Anyone whose seat changed presses Ready again; the host resumes with a shared countdown."))
		if owner:
			var res := Gui.primary("Resume for everyone", Vector2(240, 48))
			res.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			res.pressed.connect(func() -> void: client.send(NetProto.RESUME))
			pz[1].add_child(res)
	var ready := bool(me.get("ready", false))
	_s["foot_btn"].text = "Not ready" if ready else "Ready"
	_s["foot_btn"].disabled = sm.is_empty()
	var alt: Button = _s["foot_alt"]
	alt.text = "Back to the field" if paused else ("Start  →" if owner else "Leave room")
	alt.disabled = owner and not blockers.is_empty() and not paused
	_s["foot_line"].text = "You are %s%s" % [me.get("name", ""), " · host" if owner else ""]
	_s["foot_note"].text = _seat_text(me.get("seat", []), srows)

func _seat_row(row: Dictionary, names: Dictionary, owner: bool) -> Control:
	var v := Gui.vbox(6)
	var h := Gui.hbox(Gui.S8)
	v.add_child(h)
	h.add_child(Gui.label("Robot %d" % (int(row["robot"]) + 1), Gui.T_BODY, Gui.INK))
	h.add_child(Gui.label(String(row["label"]).trim_prefix("Robot %d " % (int(row["robot"]) + 1)),
		Gui.T_SMALL, Gui.MUTED))
	h.add_child(Gui.spacer())
	if owner:
		var ai := Gui.button("Driven by AI" if bool(row["ai"]) else "Driven by people",
			Gui.Look.OPTION, Vector2(0, 40))
		Gui.select(ai, bool(row["ai"]))
		ai.tooltip_text = "Hand this robot to the AI (its configured opponent behavior) or to people"
		ai.pressed.connect(func() -> void:
			client.send(NetProto.SET_AI, {"robot": int(row["robot"]), "on": not bool(row["ai"])}))
		h.add_child(ai)
	if bool(row["ai"]):
		v.add_child(Gui.note("The AI drives this robot."))
		return v
	var seats := Gui.hbox(6)
	v.add_child(seats)
	var my := client.session.pid
	for role in ["whole", "driver", "operator"]:
		var holder := int(row[role])
		var title: String = {"whole": "Whole robot", "driver": "Driver", "operator": "Operator"}[role]
		var txt := ""
		var b: Button
		if holder == my:
			txt = "%s: you — leave" % title
			b = Gui.button(txt, Gui.Look.OPTION, Vector2(0, 44))
			Gui.select(b, true)
			b.pressed.connect(func() -> void: client.send(NetProto.SEAT, {"robot": -1}))
		elif holder >= 0:
			var who: Dictionary = names.get(holder, {})
			txt = "%s: %s%s" % [title, who.get("name", "?"), "" if bool(who.get("connected", true)) else " (away)"]
			b = Gui.button(txt, Gui.Look.OPTION, Vector2(0, 44))
			b.disabled = true
		else:
			var blocked: bool = (role == "whole" and (int(row["driver"]) >= 0 or int(row["operator"]) >= 0)) \
				or (role != "whole" and int(row["whole"]) >= 0)
			txt = "%s: take" % title
			b = Gui.button(txt, Gui.Look.OPTION, Vector2(0, 44))
			b.disabled = blocked
			b.pressed.connect(func() -> void:
				SFX.play("select", -14.0)
				client.send(NetProto.SEAT, {"robot": int(row["robot"]), "role": role}))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", Gui.T_SMALL)
		seats.add_child(b)
	return v

static func _host_name(st: Dictionary) -> String:
	for p in st.get("parts", []):
		if bool(p.get("owner", false)):
			return String(p.get("name", "the host"))
	return "the host"

## The invite is long; show its start and end, copy the whole thing.
static func _short_invite(t: String) -> String:
	if t.length() <= 34:
		return t
	return "%s…%s" % [t.substr(0, 20), t.substr(t.length() - 8)]

func _person_row(p: Dictionary, owner: bool, rev: int) -> Control:
	var h := Gui.hbox(Gui.S8)
	var nm := "%s%s" % [p["name"], " ★" if bool(p["owner"]) else ""]
	h.add_child(Gui.label(nm, Gui.T_BODY, Gui.ACCENT if int(p["pid"]) == client.session.pid else Gui.INK))
	var status := ""
	var how := String(p.get("route", ""))
	if not bool(p["connected"]):
		status = "disconnected — %d s to come back" % int(p.get("grace", 0))
	elif not bool(p["acked"]) and rev >= 0:
		status = "loading the scenario"
	elif bool(p["ready"]):
		status = "ready"
	else:
		status = "not ready"
	h.add_child(Gui.label(status, Gui.T_SMALL, Gui.GOOD if status == "ready" else Gui.MUTED))
	if how != "" and bool(p["connected"]):
		h.add_child(Gui.label({"local": "hosting", "direct": "direct", "relayed": "via Epic relay",
			"lan": "same network", "connecting": "connecting"}.get(how, how), Gui.T_SMALL,
			Gui.WARN if how == "relayed" else Gui.MUTED))
	h.add_child(Gui.spacer())
	h.add_child(Gui.label(_seat_text(p.get("seat", []), client.session.state.get("seats", [])),
		Gui.T_SMALL, Gui.MUTED))
	if owner and not bool(p["owner"]):
		var rm := Gui.button("Remove", Gui.Look.GHOST, Vector2(0, 36))
		Gui.tint(rm, Gui.RED_INK)
		rm.pressed.connect(func() -> void: client.send(NetProto.KICK, {"pid": int(p["pid"])}))
		h.add_child(rm)
	return h

static func _seat_text(seat: Array, rows: Array) -> String:
	if seat.is_empty():
		return "no seat yet"
	var r := int(seat[0])
	var role: String = {"whole": "whole robot", "driver": "driver", "operator": "operator"}.get(String(seat[1]), "")
	return "Robot %d · %s" % [r + 1, role]

static func _pretty(c: String) -> String:
	return c.substr(0, 4) + "-" + c.substr(4) if c.length() == 8 else c
