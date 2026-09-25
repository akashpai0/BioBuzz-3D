class_name OnlineScreen
extends CanvasLayer
##
## PLAY -> ONLINE PRACTICE. Host a room from this game, or join one by pasting
## the host's invite.
##

var client: NetClient
var _s: Dictionary
var _root: Control
var _room_name: LineEdit
var _name: LineEdit
var _invite: LineEdit
var _msg: Label
var _busy: Label
var _how: HBoxContainer
var _relay: HBoxContainer
var _eos_line: Label
var _how_note: Label

const HOW := ["internet", "lan"]
const RELAY := ["allow", "force", "off"]

func build() -> void:
	layer = 26
	_s = Gui.shell("Play", func(p: String) -> void:
		close()
		client.main.goto(p))
	_root = _s["root"]
	_root.visible = false
	add_child(_root)
	_s["eyebrow"].text = "ONLINE PRACTICE"
	_s["title"].text = "Practise together."
	var cols := Gui.two_columns(_s["body"])
	var left: VBoxContainer = cols[0]
	var right: VBoxContainer = cols[1]

	# status and errors at the TOP, so they are seen at any window size
	_busy = Gui.label("", Gui.T_BODY, Gui.ACCENT)
	left.add_child(_busy)
	_msg = Gui.label("", Gui.T_BODY, Gui.RED_INK, true)
	left.add_child(_msg)

	var who := Gui.card(Gui.S8)
	left.add_child(who[0])
	who[1].add_child(Gui.section("Your name in the room"))
	_name = Gui.line_edit("Display name", client.display_name)
	_name.max_length = 24
	who[1].add_child(_name)

	var cr := Gui.card(Gui.S8)
	left.add_child(cr[0])
	var cv: VBoxContainer = cr[1]
	cv.add_child(Gui.section("Host a room"))
	cv.add_child(Gui.para("Your game runs the practice for everyone: physics, scoring, opponents and retries happen on this computer. You get an invite to send to your team. Keep the game open while you host."))
	_room_name = Gui.line_edit("Room name", "%s's practice" % client.display_name)
	_room_name.max_length = 40
	cv.add_child(_room_name)
	# the default room name follows the player's name until they type their own
	_name.text_changed.connect(func(t: String) -> void:
		if _room_name.text == "" or _room_name.text.ends_with("'s practice"):
			_room_name.text = "%s's practice" % NetProto.clean_name(t))
	_how = Gui.options(["Over the internet", "Same network only"], HOW.find(client.method),
		func(i: int) -> void:
			client.method = HOW[i]
			client.save_config()
			_refresh_how())
	cv.add_child(_how)
	_how_note = Gui.note("")
	_how_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cv.add_child(_how_note)
	var host := Gui.primary("Host room", Vector2(220, 50))
	host.pressed.connect(_host)
	cv.add_child(host)

	var jn := Gui.card(Gui.S8)
	left.add_child(jn[0])
	var jv: VBoxContainer = jn[1]
	jv.add_child(Gui.section("Join a room"))
	jv.add_child(Gui.para("Paste the invite the host sent you. It starts with BBZ1-."))
	var row := Gui.hbox(Gui.S8)
	_invite = Gui.line_edit("BBZ1-…")
	_invite.max_length = 400
	_invite.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_invite.text_submitted.connect(func(_t: String) -> void: _join())
	row.add_child(_invite)
	var paste := Gui.button("Paste", Gui.Look.SECONDARY, Vector2(90, 50))
	paste.pressed.connect(func() -> void:
		_invite.text = DisplayServer.clipboard_get().strip_edges())
	row.add_child(paste)
	var join := Gui.primary("Join", Vector2(120, 50))
	join.pressed.connect(_join)
	row.add_child(join)
	jv.add_child(row)

	var sv := Gui.card(Gui.S8)
	right.add_child(sv[0])
	var sb: VBoxContainer = sv[1]
	sb.add_child(Gui.section("Internet connection"))
	sb.add_child(Gui.para(("Over the internet uses Epic Online Services: each game "
		+ "gets an anonymous ID (no Epic account, no sign-in), the host's room is "
		+ "listed so an invite can find it, and the two computers connect peer to "
		+ "peer through both routers — or through Epic's relay when a direct path "
		+ "can't be made. Nobody opens ports, and there is no server to run.")))
	_eos_line = Gui.label("", Gui.T_SMALL, Gui.MUTED, true)
	sb.add_child(_eos_line)
	sb.add_child(Gui.note("Relay (for testing a connection):"))
	_relay = Gui.options(["Automatic", "Always relay", "Never relay"],
		RELAY.find(client.eos.relay_mode), func(i: int) -> void:
			client.eos.set_relay_mode(RELAY[i])
			client.save_config())
	sb.add_child(_relay)
	sb.add_child(Gui.note(("Automatic is right for play. Always relay proves the relay "
		+ "path works; Never relay shows whether a direct path exists.")))
	sb.add_child(Gui.note(("Everyone in a room needs the same game build "
		+ "(%s). Offline play never needs any of this.") % NetRole.GAME_VERSION))
	var hw := Gui.card(Gui.S8)
	right.add_child(hw[0])
	hw[1].add_child(Gui.section("How a session goes"))
	hw[1].add_child(Gui.para(("Host room → copy the invite → friends paste it → "
		+ "everyone takes a seat (whole robot, or driver and operator) → the host "
		+ "picks a scenario → Ready → Start. The host can pause and retry for "
		+ "everyone; anyone can ask for either. If the host leaves, the session "
		+ "ends for everyone and everyone keeps their replays.")))

	_s["foot_btn"].text = "Back to Play"
	_s["foot_btn"].pressed.connect(func() -> void:
		close()
		client.main.goto("Play"))
	_s["foot_line"].text = "Private rooms · up to %d players" % NetRole.MAX_PARTICIPANTS
	client.eos.status_changed.connect(_refresh_eos)
	_refresh_how()
	_refresh_eos()

func _refresh_how() -> void:
	Gui.set_options(_how, HOW.find(client.method))
	if client.method == "internet":
		_how_note.text = "Friends anywhere. Needs Epic Online Services in this build."
	else:
		_how_note.text = ("Only for computers on the same network (the same school or "
			+ "house Wi-Fi). It will not reach friends at home.")

func _refresh_eos() -> void:
	var e := client.eos
	if OS.has_feature("web"):
		_eos_line.text = "Not available in the browser version."
		_eos_line.add_theme_color_override("font_color", Gui.MUTED)
		return
	var why := e.unavailable_reason()
	if why != "":
		_eos_line.text = why
		_eos_line.add_theme_color_override("font_color", Gui.WARN)
		return
	var t := "Ready to connect."
	match e.status:
		"starting": t = "Connecting to Epic Online Services…"
		"ready":
			t = "Connected to Epic Online Services."
			if e.nat_type != "":
				t += " This network's NAT type: %s." % e.nat_type
		"error": t = e.status_text
	_eos_line.text = t
	_eos_line.add_theme_color_override("font_color", Gui.RED_INK if e.status == "error" else Gui.MUTED)

func _host() -> void:
	SFX.play("select", -12.0)
	_start_busy("Opening the room…" if client.method == "lan" else "Connecting to Epic Online Services…")
	var err: String = await client.host_room(_room_name.text, _name.text, client.method)
	if err != "":
		show_message(err, true)

func _join() -> void:
	var inv := NetInvite.parse(_invite.text)
	if not bool(inv.get("ok", false)):
		show_message(String(inv["error"]), true)
		return
	SFX.play("select", -12.0)
	_start_busy("Finding the room…" if String(inv["kind"]) == "eos" else "Connecting…")
	var err: String = await client.join_room(_invite.text, _name.text)
	if err != "":
		show_message(err, true)

func _start_busy(t: String) -> void:
	_busy.text = t
	_msg.text = ""

func show_message(t: String, bad: bool) -> void:
	_busy.text = ""
	_msg.text = t
	_msg.add_theme_color_override("font_color", Gui.RED_INK if bad else Gui.GOOD)

func _process(_d: float) -> void:
	if _busy:
		_busy.visible = _busy.text != ""
		_msg.visible = _msg.text != ""
	if not _root.visible or client.session == null:
		return
	if client.session.phase == "entering":
		_busy.text = "Connecting to the host's game…"

func open() -> void:
	_root.visible = true
	if client.display_name == "":
		# first run: the name typed at sign-in is the obvious default
		client.display_name = NetProto.clean_name(Leaderboard.player_name())
	_name.text = client.display_name
	if _room_name.text == "" or _room_name.text.ends_with("'s practice"):
		_room_name.text = "%s's practice" % client.display_name
	_refresh_how()
	_refresh_eos()
	if OS.has_feature("web"):
		show_message(NetClient.WEB_NO_ONLINE, true)
		for b in _root.find_children("*", "Button", true, false):
			var t := (b as Button).text
			if t in ["Host room", "Join", "Paste"]:
				(b as Button).disabled = true

func close() -> void:
	_root.visible = false

func is_open() -> bool:
	return _root.visible
