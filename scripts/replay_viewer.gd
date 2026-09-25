class_name ReplayViewer
extends CanvasLayer
##
## WATCH A RECORDING. READ-ONLY.
##
## The viewer poses the real field from recorded samples. While it is up the
## world is FROZEN and HALTED (BB.set_viewing): physics does not step, no robot
## reads a controller, no AI decides anything, no attempt, statistic or
## recorder runs, and every reactive system sees `BB.frozen()` and sits still.
## Setting a transform on a frozen body with the physics server stopped moves
## the picture and nothing else — so scrubbing cannot score, foul, pick up,
## tip, make a sound, or create an attempt record.
##
## What is on screen at time t:
##   - poses are INTERPOLATED between the two recorded samples either side of
##     t, purely for smooth motion — except across a discontinuity (a ball
##     changing owner, a teleport-sized jump), where the earlier sample is held;
##   - every number (clock, scoreboard, hopper counts, battery, opponent status)
##     is the LAST RECORDED VALUE at or before t, never interpolated.
##
## The camera, playback speed and event panel are the viewer's own settings,
## not part of the recording, and changing them touches nothing else.
##

signal closed(reason: String, payload: Dictionary)

const SPEEDS := [0.25, 0.5, 1.0, 2.0]
const EVENT_LEAD_S := 3.0          # "a few seconds earlier"
const MAX_EVENT_ROWS := 600

var main: Node3D
var reader: ReplayReader
var t := 0.0
var playing := false
var speed := 1.0
var cam_key := "overview"
var _cam_keys: Array = []
var _elements: Array = []          # sample order -> GameElement
var _robots: Array = []
var _hives: Array = []
var _applied_t := -1.0
var _damaged_now := false
var _open := false
var _practise_cp := -1
var _practise_snap: Dictionary = {}

var _root: Control
var _timeline: ReplayTimeline
var _time_lbl: Label
var _clock_lbl: Label
var _play_btn: Button
var _speed_btns: Array = []
var _cam_btn: Button
var _events_btn: Button
var _practise_btn: Button
var _back_btn: Button
var _title_lbl: Label
var _sub_lbl: Label
var _score_lbl: RichTextLabel
var _robots_lbl: RichTextLabel
var _note_lbl: Label
var _prof_lbl: Label
var _events_panel: PanelContainer
var _events_box: VBoxContainer
var _event_rows: Array = []
var _help_lbl: Label
var _modal: PanelContainer
var _modal_box: VBoxContainer
var _flash_lbl: Label
var _flash_left := 0.0
var _events_passed := -1
var _look := ""

## How many times apply() ran, for the tests.
var applies := 0

func _ready() -> void:
	layer = 31
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_root.visible = false

func is_open() -> bool:
	return _open

# ================================================================== opening ==

## Load a recording and take over the field. Returns "" or a sentence saying
## why it cannot be shown. Never called while a run is in progress.
func open(path: String) -> String:
	var r := ReplayReader.new()
	var err := r.open(path)
	if err != "":
		r.close()
		return err
	var cp0 := r.checkpoint(0)
	if cp0.is_empty():
		r.close()
		return "The recording's first checkpoint is damaged, so the field cannot be set up."
	reader = r
	SFX.stop_all_loops()
	var problems: Array = await Snapshot.restore(main, cp0, true)
	BB.editing = false
	BB.set_viewing(true)
	SFX.stop_all_loops()
	_robots = []
	for rb in main.robots:
		_robots.append(rb)
	_hives = []
	for a in reader.header.get("hives", []):
		_hives.append(main.field.hives.get(int(a)))
	_elements = []
	_elements.resize(reader.n_elements)
	for n in main.get_tree().get_nodes_in_group("element"):
		var sid := String(n.get_meta("sid", ""))
		if sid.begins_with("e"):
			var k := int(sid.substr(1)) - 1
			if k >= 0 and k < _elements.size():
				_elements[k] = n
	var missing := 0
	for e in _elements:
		if e == null:
			missing += 1
	_open = true
	t = 0.0
	playing = false
	_applied_t = -1.0
	_look = ""
	_close_modal()
	_fill_static()
	if missing > 0 or _robots.size() != reader.n_robots:
		problems.append("%d recorded object%s could not be placed" % [
			missing, "" if missing == 1 else "s"])
	_note_lbl.text = "" if problems.is_empty() else "Note: " + "; ".join(problems)
	_cam_keys = ["overview", "top", "driver"]
	for i in _robots.size():
		_cam_keys.append("follow:%d" % i)
	var pref := ReplayStore.camera_pref()
	cam_key = pref if pref in _cam_keys or pref.begins_with("follow:") else "overview"
	if not cam_key in _cam_keys:
		cam_key = "follow:0"
	_apply_camera()
	_root.visible = true
	_apply(0.0)
	_refresh_ui()
	_play_btn.grab_focus()
	return ""

func _fill_static() -> void:
	var h := reader.header
	_title_lbl.text = "REPLAY · %s" % reader.title()
	var outcome := String(reader.final.get("outcome_label", ""))
	if not reader.complete:
		outcome = "Incomplete — playable to %s" % _clock(reader.duration)
	_prof_lbl.text = ("RECORDED: clock, scoreboard, hoppers, batteries, opponent status "
		+ "(robot profile \"%s\").  YOUR SETTINGS: camera, speed. Robots are drawn "
		+ "with your current Garage model.") % String(h.get("robot_profile", "?"))
	_sub_lbl.text = "Recorded %s · %s%s · %s" % [
		String(h.get("created_local", "")), String(h.get("mode_name", "")),
		(" · " + String(h.get("scenario_name", ""))) if String(h.get("scenario_name", "")) != "" else "",
		outcome]
	_timeline.duration = maxf(reader.duration, 0.001)
	_timeline.checkpoints = reader.checkpoint_times()
	_timeline.events = reader.events
	_timeline.gaps = []
	_build_event_list()

## Put everything back the way the game expects it, then hand control back.
func close(reason := "back", payload := {}) -> void:
	if not _open:
		return
	_open = false
	playing = false
	_root.visible = false
	_close_modal()
	if reader:
		reader.close()
	reader = null
	# stays frozen (BB.viewing) until main has re-staged the world
	closed.emit(reason, payload)

# ================================================================= playback ==

func _process(delta: float) -> void:
	if not _open:
		return
	if _flash_left > 0.0:
		_flash_left -= delta
		if _flash_left <= 0.0:
			_flash_lbl.text = ""
	if _modal.visible:
		return
	_scrub_axes(delta)
	if playing:
		t += delta * speed
		if t >= reader.duration:
			t = reader.duration
			playing = false
	if absf(t - _applied_t) > 0.00001:
		_apply(t)
	_refresh_ui()

func seek(to: float) -> void:
	t = clampf(to, 0.0, reader.duration if reader else 0.0)
	_apply(t)
	_refresh_ui()

func set_speed(s: float) -> void:
	speed = s
	_refresh_ui()

func toggle_play() -> void:
	if t >= reader.duration - 0.0001:
		t = 0.0
	playing = not playing
	_refresh_ui()

func step_checkpoint(dir: int) -> void:
	var times := reader.checkpoint_times()
	if dir < 0:
		var best := 0.0
		for c in times:
			if float(c) < t - 0.01:
				best = float(c)
		seek(best)
	else:
		for c in times:
			if float(c) > t + 0.01:
				seek(float(c))
				return
		seek(reader.duration)
	playing = false

## APPLY THE RECORDING AT TIME `tt` TO THE FIELD. Pure presentation.
func _apply(tt: float) -> void:
	_applied_t = tt
	applies += 1
	var fs := tt * reader.rate
	var s := clampi(int(floor(fs + 0.000001)), 0, reader.sample_count() - 1)
	var alpha := clampf(fs - float(s), 0.0, 1.0)
	var a := reader.sample(s)
	if a.is_empty():
		_damaged_now = true
		return
	_damaged_now = false
	var b: Array = []
	if alpha > 0.0005 and s + 1 < reader.sample_count():
		b = reader.sample(s + 1)
	var fa: PackedFloat32Array = a[0]
	var oa: int = a[1]
	var fb: PackedFloat32Array = b[0] if not b.is_empty() else PackedFloat32Array()
	var ob: int = b[1] if not b.is_empty() else 0
	WorldPose.apply({"robots": _robots, "hives": _hives, "elements": _elements},
		fa, oa, fb, ob, alpha, not b.is_empty(), reader.n_robots, reader.n_hives,
		reader.n_elements)

## The recorded numbers at or before `t`.
func recorded_at(tt: float) -> Dictionary:
	var s := clampi(int(floor(tt * reader.rate + 0.000001)), 0, reader.sample_count() - 1)
	var a := reader.sample(s)
	if a.is_empty():
		return {}
	var f: PackedFloat32Array = a[0]
	var o: int = a[1]
	var out := {"sample": s, "t": f[o], "time_left": f[o + 1], "phase": int(f[o + 2]),
		"red": int(f[o + 3]), "blue": int(f[o + 4]),
		"fouls_red": int(f[o + 5]), "fouls_blue": int(f[o + 6]),
		"final": int(f[o + 7]) & 1 == 1, "free": int(f[o + 7]) & 2 == 2, "robots": []}
	var ro := o + reader.head
	var rmeta: Array = reader.header.get("robots", [])
	for i in reader.n_robots:
		var m: Dictionary = rmeta[i] if i < rmeta.size() else {}
		(out["robots"] as Array).append({
			"label": String(m.get("label", "R%d" % (i + 1))),
			"alliance": int(m.get("alliance", 0)), "ai": bool(m.get("ai", false)),
			"hopper": int(f[ro + 9]), "enabled": f[ro + 10] > 0.5,
			"battery": f[ro + 11],
			"status": reader.status_at(s, i),
			"behavior": String(m.get("behavior", "")),
		})
		ro += reader.per_robot
	return out

# ==================================================================== input ==

## The viewer's own controls. Gameplay is not running while it is up, so no
## driving binding is taken over; every key it uses is printed on screen.
func _input(ev: InputEvent) -> void:
	if not _open:
		return
	var typing := get_viewport().gui_get_focus_owner() is LineEdit
	if ev is InputEventKey and ev.pressed:
		var k := ev as InputEventKey
		if k.keycode == KEY_ESCAPE:
			if _modal.visible:
				_close_modal()
			else:
				close("back")
			get_viewport().set_input_as_handled()
			return
		if typing or _modal.visible:
			return
		var handled := true
		match k.keycode:
			KEY_SPACE, KEY_K:
				toggle_play()
			KEY_LEFT:
				playing = false
				seek(t - (5.0 if k.shift_pressed else 1.0))
			KEY_RIGHT:
				playing = false
				seek(t + (5.0 if k.shift_pressed else 1.0))
			KEY_COMMA:
				playing = false
				seek(t - 1.0 / reader.rate)
			KEY_PERIOD:
				playing = false
				seek(t + 1.0 / reader.rate)
			KEY_BRACKETLEFT:
				step_checkpoint(-1)
			KEY_BRACKETRIGHT:
				step_checkpoint(1)
			KEY_1: set_speed(0.25)
			KEY_2: set_speed(0.5)
			KEY_3: set_speed(1.0)
			KEY_4: set_speed(2.0)
			KEY_C:
				cycle_camera()
			KEY_E:
				toggle_events()
			KEY_P:
				open_practise()
			KEY_HOME:
				seek(0.0)
			KEY_END:
				seek(reader.duration)
			_:
				handled = false
		if handled:
			get_viewport().set_input_as_handled()
	elif ev is InputEventJoypadButton and ev.pressed:
		var jb := ev as InputEventJoypadButton
		var handled2 := true
		match jb.button_index:
			JOY_BUTTON_B:
				if _modal.visible:
					_close_modal()
				else:
					close("back")
			JOY_BUTTON_X:
				if not _modal.visible:
					toggle_play()
			JOY_BUTTON_Y:
				if not _modal.visible:
					cycle_camera()
			JOY_BUTTON_LEFT_SHOULDER:
				if not _modal.visible:
					step_checkpoint(-1)
			JOY_BUTTON_RIGHT_SHOULDER:
				if not _modal.visible:
					step_checkpoint(1)
			JOY_BUTTON_BACK:
				if not _modal.visible:
					toggle_events()
			_:
				handled2 = false
		if handled2:
			get_viewport().set_input_as_handled()

## Hold a trigger to scrub: left back, right forward, harder is faster.
func _scrub_axes(delta: float) -> void:
	var v := 0.0
	for dev in Input.get_connected_joypads():
		v += Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_RIGHT)
		v -= Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_LEFT)
	if absf(v) > 0.15:
		playing = false
		t = clampf(t + v * delta * 6.0, 0.0, reader.duration)

# =================================================================== camera ==

func cycle_camera() -> void:
	var i := _cam_keys.find(cam_key)
	cam_key = _cam_keys[(i + 1) % _cam_keys.size()]
	_apply_camera()
	ReplayStore.set_camera_pref(cam_key)
	_refresh_ui()

func set_camera(key: String) -> void:
	if not key in _cam_keys:
		return
	cam_key = key
	_apply_camera()
	_refresh_ui()

func _apply_camera() -> void:
	var rig: CameraRig = main.rig
	rig.robots = main.robots
	if not main.robots.is_empty():
		rig.target = main.robots[0]
	rig.alliance = int(reader.header.get("our_alliance", BB.Alliance.RED))
	if cam_key == "overview":
		rig.mode = CameraRig.Mode.OVERVIEW
	elif cam_key == "top":
		rig.mode = CameraRig.Mode.OVERHEAD
	elif cam_key == "driver":
		rig.mode = CameraRig.Mode.DRIVER
	elif cam_key.begins_with("follow:"):
		rig.follow = int(cam_key.substr(7))
		rig.mode = CameraRig.Mode.CHASE

func _cam_name(key: String) -> String:
	match key:
		"overview": return "Overview"
		"top": return "Top down"
		"driver": return "Driver station"
	if key.begins_with("follow:"):
		var i := int(key.substr(7))
		var rm: Array = reader.header.get("robots", []) if reader else []
		return "Follow %s" % (String(rm[i].get("label", "robot")) if i < rm.size() else "robot")
	return key

# =================================================================== events ==

func toggle_events() -> void:
	_events_panel.visible = not _events_panel.visible
	_refresh_ui()

func _build_event_list() -> void:
	for c in _events_box.get_children():
		c.queue_free()
	_event_rows.clear()
	_events_passed = -1
	if reader.events.is_empty():
		_events_box.add_child(Gui.note("No gameplay events were recorded."))
		_events_passed = -1
		return
	var evs: Array = reader.events
	if evs.size() > MAX_EVENT_ROWS:
		# a very long session: list the significant ones; every event is still
		# marked on the timeline
		evs = evs.filter(func(e) -> bool: return String(e.get("type", "")) != "shot")
		_events_box.add_child(Gui.note(("%d events; launches are left out of this "
			+ "list (they are on the timeline).") % reader.events.size()))
	if evs.size() > MAX_EVENT_ROWS:
		evs = evs.slice(0, MAX_EVENT_ROWS)
		_events_box.add_child(Gui.note("Showing the first %d." % MAX_EVENT_ROWS))
	for ev in evs:
		var row := Gui.hbox(6)
		var tt := float(ev.get("t", 0.0))
		var go := Gui.button("%s  %s" % [_clock(tt), String(ev.get("label", ""))],
			Gui.Look.GHOST, Vector2(0, 36))
		go.alignment = HORIZONTAL_ALIGNMENT_LEFT
		go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		go.clip_text = true
		go.add_theme_font_size_override("font_size", Gui.T_SMALL)
		go.tooltip_text = String(ev.get("label", ""))
		go.pressed.connect(func() -> void:
			playing = false
			seek(tt))
		row.add_child(go)
		var early := Gui.button("−%d s" % int(EVENT_LEAD_S), Gui.Look.SECONDARY, Vector2(64, 36))
		early.add_theme_font_size_override("font_size", Gui.T_SMALL)
		early.tooltip_text = "Jump to %d seconds before this" % int(EVENT_LEAD_S)
		early.pressed.connect(func() -> void:
			playing = false
			seek(tt - EVENT_LEAD_S))
		row.add_child(early)
		_events_box.add_child(row)
		_event_rows.append([tt, go])

# ========================================================= practise here ===

## Pause, move to the nearest complete checkpoint, and offer to save it.
func open_practise() -> void:
	if not _open:
		return
	playing = false
	var want := t
	var i := reader.nearest_checkpoint(t)
	var ct := float(reader.checkpoints[i]["t0"])
	seek(ct)
	_practise_cp = i
	_practise_snap = reader.checkpoint(i)
	for c in _modal_box.get_children():
		c.queue_free()
	_modal_box.add_child(Gui.section("Practise from here"))
	if absf(want - ct) > 0.001:
		_modal_box.add_child(Gui.para(("Moved to the nearest full checkpoint, "
			+ "%s. You were at %s. Checkpoints are recorded once a second; "
			+ "the game will not simulate forward to invent the moment in between.")
			% [_clock(ct), _clock(want)], Gui.WARN))
	else:
		_modal_box.add_child(Gui.para("Checkpoint at %s." % _clock(ct), Gui.MUTED))
	var why := ReplayBranch.refusal(_practise_snap)
	if why != "":
		_modal_box.add_child(Gui.para(why, Gui.RED_INK))
		var row0 := Gui.hbox(Gui.S8)
		var ok0 := Gui.button("Keep watching", Gui.Look.SECONDARY, Vector2(0, 50))
		ok0.pressed.connect(_close_modal)
		row0.add_child(ok0)
		_modal_box.add_child(row0)
		_show_modal(ok0)
		return
	var rec := recorded_at(ct)
	if not rec.is_empty():
		_modal_box.add_child(Gui.body("Recorded score at this moment: RED %d · BLUE %d" % [
			int(rec["red"]), int(rec["blue"])]))
		_modal_box.add_child(Gui.para(("It stays as the new situation's starting "
			+ "scoreboard. An objective you add later still counts from zero.")))
	for line in ReplayBranch.summary(_practise_snap):
		_modal_box.add_child(Gui.para("• " + String(line)))
	_modal_box.add_child(Gui.label("Situation name", Gui.T_SMALL, Gui.MUTED))
	var name_edit := Gui.line_edit("Name this situation",
		"%s @ %s" % [reader.title(), _clock(ct)])
	_modal_box.add_child(name_edit)
	var msg := Gui.note("")
	_modal_box.add_child(msg)
	var row := Gui.hbox(Gui.S8)
	var save := Gui.primary("Save situation", Vector2(220, 50))
	var cancel := Gui.button("Cancel", Gui.Look.SECONDARY, Vector2(0, 50))
	cancel.pressed.connect(_close_modal)
	save.pressed.connect(func() -> void:
		var n := name_edit.text.strip_edges()
		if n == "":
			msg.text = "Give it a name first."
			return
		var sid := save_practice(n)
		if sid == "":
			msg.text = "Could not write that situation to disk. Nothing was saved."
			msg.add_theme_color_override("font_color", Gui.RED_INK)
			return
		_saved_card(sid, n))
	name_edit.text_submitted.connect(func(_s: String) -> void: save.pressed.emit())
	row.add_child(save)
	row.add_child(cancel)
	_modal_box.add_child(row)
	_show_modal(name_edit)

## Save the chosen checkpoint as a situation. Returns its id or "".
## Reads the replay; writes only the situation library.
func save_practice(n: String) -> String:
	if _practise_snap.is_empty() or ReplayBranch.refusal(_practise_snap) != "":
		return ""
	var snap := ReplayBranch.make_situation(_practise_snap, reader.id, reader.title())
	var ct := float(snap.get("origin", {}).get("replay_t", 0.0))
	var note := "From replay \"%s\" at %s." % [reader.title(), _clock(ct)]
	return ScenarioLibrary.save(snap, n, note)

func _saved_card(sid: String, n: String) -> void:
	for c in _modal_box.get_children():
		c.queue_free()
	_modal_box.add_child(Gui.section("Saved"))
	_modal_box.add_child(Gui.para(("\"%s\" is in your situations. The replay "
		+ "is unchanged.") % n))
	var row := Gui.hbox(Gui.S8)
	var go := Gui.primary("Start practising  →", Vector2(240, 50))
	go.pressed.connect(func() -> void: close("practise", {"id": sid, "action": "play"}))
	var edit := Gui.button("Edit scenario", Gui.Look.SECONDARY, Vector2(0, 50))
	edit.tooltip_text = "Open it in the editor, for example to add an objective"
	edit.pressed.connect(func() -> void: close("practise", {"id": sid, "action": "edit"}))
	var keep := Gui.button("Keep watching", Gui.Look.SECONDARY, Vector2(0, 50))
	keep.pressed.connect(_close_modal)
	row.add_child(go)
	row.add_child(edit)
	row.add_child(keep)
	_modal_box.add_child(row)
	_show_modal(go)

func _show_modal(focus: Control) -> void:
	_modal.visible = true
	_side_panels(false)
	focus.call_deferred("grab_focus")
	_refresh_ui()

func _close_modal() -> void:
	if _modal:
		_modal.visible = false
		_side_panels(true)
	if _practise_btn and _open:
		_practise_btn.grab_focus()

# ======================================================================= UI ==

var _tl_panel: Control
var _tr_panel: Control
var _events_were := false

func _side_panels(on: bool) -> void:
	if _tl_panel == null:
		return
	if not on:
		_events_were = _events_panel.visible
		_events_panel.visible = false
	elif _events_were:
		_events_panel.visible = true
	_tl_panel.visible = on
	_tr_panel.visible = on

func flash(text: String) -> void:
	_flash_lbl.text = text
	_flash_left = 4.0

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# ---- top left: what this is, and the recorded scoreboard
	var tl := _panel()
	tl.set_anchors_preset(Control.PRESET_TOP_LEFT)
	tl.position = Vector2(16, 16)
	tl.custom_minimum_size = Vector2(520, 0)
	_root.add_child(tl)
	_tl_panel = tl
	var tlv := Gui.vbox(4)
	tl.add_child(tlv)
	_title_lbl = Gui.label("", Gui.T_BODY, Gui.ACCENT)
	_title_lbl.clip_text = true
	_title_lbl.custom_minimum_size = Vector2(480, 0)
	tlv.add_child(_title_lbl)
	_sub_lbl = Gui.label("", Gui.T_SMALL, Gui.MUTED, true)
	_sub_lbl.custom_minimum_size = Vector2(480, 0)
	tlv.add_child(_sub_lbl)
	_score_lbl = _rich()
	tlv.add_child(_score_lbl)
	_prof_lbl = Gui.label("", 12, Gui.MUTED, true)
	_prof_lbl.custom_minimum_size = Vector2(480, 0)
	tlv.add_child(_prof_lbl)
	_note_lbl = Gui.label("", 12, Gui.WARN, true)
	_note_lbl.custom_minimum_size = Vector2(480, 0)
	tlv.add_child(_note_lbl)

	# ---- top right: every robot, as recorded
	var tr := _panel()
	tr.anchor_left = 1.0
	tr.anchor_right = 1.0
	tr.offset_left = -440
	tr.offset_right = -16
	tr.offset_top = 16
	_root.add_child(tr)
	_tr_panel = tr
	_robots_lbl = _rich()
	_robots_lbl.custom_minimum_size = Vector2(400, 0)
	tr.add_child(_robots_lbl)

	# ---- right: the event list
	_events_panel = _panel()
	_events_panel.anchor_left = 1.0
	_events_panel.anchor_right = 1.0
	_events_panel.anchor_top = 0.0
	_events_panel.anchor_bottom = 1.0
	_events_panel.offset_left = -440
	_events_panel.offset_right = -16
	_events_panel.offset_top = 200
	_events_panel.offset_bottom = -196
	_events_panel.visible = false          # E / Events opens it; the field comes first
	_root.add_child(_events_panel)
	var ev_v := Gui.vbox(6)
	_events_panel.add_child(ev_v)
	ev_v.add_child(Gui.label("EVENTS  ·  select to jump, −%d s to see the lead-up" % int(EVENT_LEAD_S),
		12, Gui.MUTED))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	ev_v.add_child(sc)
	_events_box = Gui.vbox(2)
	_events_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_events_box)

	# ---- bottom: the transport
	var bar := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Gui.PANEL.r, Gui.PANEL.g, Gui.PANEL.b, 0.94)
	sb.border_color = Gui.LINE
	sb.border_width_top = 1
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	bar.add_theme_stylebox_override("panel", sb)
	bar.anchor_left = 0.0
	bar.anchor_right = 1.0
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_top = -180
	_root.add_child(bar)
	var bv := Gui.vbox(8)
	bar.add_child(bv)
	var trow := Gui.hbox(Gui.S16)
	bv.add_child(trow)
	_time_lbl = Gui.label("", Gui.T_BODY, Gui.INK)
	_time_lbl.custom_minimum_size = Vector2(190, 0)
	trow.add_child(_time_lbl)
	_timeline = ReplayTimeline.new()
	_timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline.seek_requested.connect(func(tt: float) -> void:
		playing = false
		seek(tt))
	trow.add_child(_timeline)
	_clock_lbl = Gui.label("", Gui.T_BODY, Gui.INK)
	_clock_lbl.custom_minimum_size = Vector2(250, 0)
	_clock_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	trow.add_child(_clock_lbl)

	var crow := Gui.hbox(Gui.S8)
	bv.add_child(crow)
	var prev := Gui.button("◀ Checkpoint", Gui.Look.SECONDARY, Vector2(0, 50))
	prev.tooltip_text = "Previous checkpoint  [ "
	prev.pressed.connect(func() -> void: step_checkpoint(-1))
	crow.add_child(prev)
	_play_btn = Gui.primary("Play", Vector2(120, 50))
	_play_btn.pressed.connect(toggle_play)
	crow.add_child(_play_btn)
	var nxt := Gui.button("Checkpoint ▶", Gui.Look.SECONDARY, Vector2(0, 50))
	nxt.tooltip_text = "Next checkpoint  ]"
	nxt.pressed.connect(func() -> void: step_checkpoint(1))
	crow.add_child(nxt)
	crow.add_child(_gap())
	for sp in SPEEDS:
		var b := Gui.button(_speed_text(sp), Gui.Look.OPTION, Vector2(64, 50))
		b.pressed.connect(func() -> void: set_speed(sp))
		crow.add_child(b)
		_speed_btns.append([sp, b])
	crow.add_child(_gap())
	_cam_btn = Gui.button("", Gui.Look.SECONDARY, Vector2(250, 50))
	_cam_btn.tooltip_text = "Camera (your setting, not part of the recording)  C"
	_cam_btn.pressed.connect(cycle_camera)
	crow.add_child(_cam_btn)
	_events_btn = Gui.button("Events", Gui.Look.SECONDARY, Vector2(0, 50))
	_events_btn.pressed.connect(toggle_events)
	crow.add_child(_events_btn)
	crow.add_child(Gui.spacer())
	_practise_btn = Gui.primary("Practise from here", Vector2(230, 50))
	_practise_btn.pressed.connect(open_practise)
	crow.add_child(_practise_btn)
	_back_btn = Gui.button("Back", Gui.Look.SECONDARY, Vector2(110, 50))
	_back_btn.pressed.connect(func() -> void: close("back"))
	crow.add_child(_back_btn)

	var hrow := Gui.hbox(Gui.S16)
	bv.add_child(hrow)
	_help_lbl = Gui.label(_help_text(), 12, Gui.MUTED)
	hrow.add_child(_help_lbl)
	hrow.add_child(Gui.spacer())
	_flash_lbl = Gui.label("", Gui.T_SMALL, Gui.WARN)
	hrow.add_child(_flash_lbl)

	# ---- the save card: the full height above the transport bar, scrolling
	# if a busy moment has more to say than fits
	_modal = _panel()
	_modal.anchor_left = 0.5
	_modal.anchor_right = 0.5
	_modal.anchor_top = 0.0
	_modal.anchor_bottom = 1.0
	_modal.offset_left = -420
	_modal.offset_right = 420
	_modal.offset_top = 16
	_modal.offset_bottom = -196
	_modal.visible = false
	_root.add_child(_modal)
	var msc := ScrollContainer.new()
	msc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	msc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_modal.add_child(msc)
	var mv := Gui.vbox(10)
	mv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	msc.add_child(mv)
	_modal_box = mv

static func _help_text() -> String:
	return ("Keys: Space play/pause · ← → 1 s (Shift 5 s) · , . one sample · "
		+ "[ ] checkpoint · 1–4 speed · C camera · E events · P practise · Esc back"
		+ "     Controller: %s play/pause · triggers scrub · %s / %s checkpoint · "
		+ "%s camera · %s activates the focused button · %s back") % [
		BB.pad_button_name(JOY_BUTTON_X),
		BB.pad_button_name(JOY_BUTTON_LEFT_SHOULDER),
		BB.pad_button_name(JOY_BUTTON_RIGHT_SHOULDER),
		BB.pad_button_name(JOY_BUTTON_Y), BB.pad_button_name(JOY_BUTTON_A),
		BB.pad_button_name(JOY_BUTTON_B)]

func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Gui.PANEL.r, Gui.PANEL.g, Gui.PANEL.b, 0.90)
	sb.border_color = Gui.LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(Gui.R_CTRL)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	p.add_theme_stylebox_override("panel", sb)
	return p

func _rich() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.add_theme_font_size_override("normal_font_size", Gui.T_SMALL)
	r.add_theme_font_size_override("bold_font_size", Gui.T_SMALL)
	r.add_theme_color_override("default_color", Gui.INK)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

func _gap() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(12, 0)
	return c

static func _speed_text(s: float) -> String:
	return "%s×" % (("%.2f" % s).rstrip("0").rstrip("."))

func _refresh_ui() -> void:
	if reader == null:
		return
	_timeline.set_state(t)
	_put_text(_time_lbl, "%s / %s" % [_clock(t), _clock(reader.duration)])
	_put_text(_play_btn, "Pause" if playing else "Play")
	var look := "%s|%s|%s" % [speed, cam_key, _events_panel.visible]
	if look != _look:
		_look = look
		for pair in _speed_btns:
			Gui.select(pair[1], is_equal_approx(float(pair[0]), speed))
		_cam_btn.text = "Camera: %s" % _cam_name(cam_key)
		Gui.select(_events_btn, _events_panel.visible)
	var rec := recorded_at(t)
	if rec.is_empty() or _damaged_now:
		_put_text(_clock_lbl, "Damaged section")
		_put_text(_score_lbl, "[color=#FF8588]This part of the recording could not be read.[/color]")
		return
	var phase_names := ["Pre-match", "Auto", "Transition", "Teleop", "Settling", "Finished"]
	var ph: String = phase_names[clampi(int(rec["phase"]), 0, 5)]
	_put_text(_clock_lbl, "Match clock: %s" % ("no clock" if bool(rec["free"])
		else "%s %s" % [ph, BB.clock_text(float(rec["time_left"]))]))
	_put_text(_score_lbl, ("[b][color=#FF8588]RED %d[/color]   [color=#8DB4FF]BLUE %d[/color][/b]"
		+ "   %s%s") % [int(rec["red"]), int(rec["blue"]), ph,
		"" if bool(rec["free"]) else " · " + BB.clock_text(float(rec["time_left"]))])
	var lines: Array = []
	for r in rec["robots"]:
		var col := "#FF8588" if int(r["alliance"]) == BB.Alliance.RED else "#8DB4FF"
		var line := "[b][color=%s]%s[/color][/b]  hopper %d · %.1f V%s" % [col,
			String(r["label"]), int(r["hopper"]), float(r["battery"]),
			"" if bool(r["enabled"]) else " · disabled"]
		if bool(r["ai"]):
			line += "\n    %s%s" % [String(r["behavior"]),
				(" — " + String(r["status"])) if String(r["status"]) != "" else ""]
		lines.append(line)
	_put_text(_robots_lbl, "\n".join(lines))
	# Recolour only when the playhead crosses an event: a theme override on
	# every row every frame relayouts the whole list.
	var passed := 0
	for row in _event_rows:
		if float(row[0]) <= t + 0.0001:
			passed += 1
	if passed != _events_passed:
		_events_passed = passed
		for i in _event_rows.size():
			var btn: Button = _event_rows[i][1]
			if is_instance_valid(btn):
				btn.add_theme_color_override("font_color", Gui.INK if i < passed else Gui.MUTED)

## Change a label only when its text actually changes: re-setting a rich
## label every frame re-parses and re-lays it out.
static func _put_text(c: Control, text: String) -> void:
	if c is RichTextLabel:
		if (c as RichTextLabel).text != text:
			(c as RichTextLabel).text = text
	elif c is Label:
		if (c as Label).text != text:
			(c as Label).text = text
	elif c is Button:
		if (c as Button).text != text:
			(c as Button).text = text

static func _clock(tt: float) -> String:
	return "%d:%04.1f" % [int(tt) / 60, fmod(maxf(tt, 0.0), 60.0)]
