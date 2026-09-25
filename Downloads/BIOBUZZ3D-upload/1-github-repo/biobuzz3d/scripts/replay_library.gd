class_name ReplayLibrary
extends RefCounted
##
## PROGRESS → REPLAYS. The collection, searchable and sortable, built from
## sidecars and the index cache — never from the recordings themselves.
##
## Every destructive action is explicit: deleting asks first and says how
## many replays and files it will remove; changing the folder asks whether to
## SWITCH (recordings stay where they are) or MOVE them. Nothing is removed to
## make room, ever.
##

const PAGE := 25
const SORTS := ["Newest first", "Oldest first", "Longest", "Highest score",
	"Title A–Z", "Largest file"]
const MODES := ["All modes", "Full match", "Teleop only", "Free practice",
	"Online practice"]
const OUTCOMES := ["Any outcome", "Finished", "Objective completed",
	"Objective failed", "Abandoned", "Ended", "Incomplete or damaged"]

var host: ProgressScreen
var entries: Array = []
var query := ""
var sort_i := 0
var mode_i := 0
var outcome_i := 0
var favorites_only := false
var shown := PAGE
var selected := {}
var editing_id := ""
var editing_what := ""
var _loaded := false
var last_load_usec := 0

func reload() -> void:
	var t0 := Time.get_ticks_usec()
	entries = ReplayStore.list()
	last_load_usec = Time.get_ticks_usec() - t0
	_loaded = true
	for id in selected.keys():
		var still := false
		for e in entries:
			if String(e["id"]) == id:
				still = true
		if not still:
			selected.erase(id)

func ensure_loaded() -> void:
	if not _loaded:
		reload()

# ================================================================ filtering ==

func filtered() -> Array:
	var q := query.strip_edges().to_lower()
	var out: Array = []
	for e in entries:
		if favorites_only and not bool(e.get("favorite", false)):
			continue
		if mode_i > 0 and String(e.get("mode_name", "")) != MODES[mode_i]:
			continue
		if outcome_i > 0:
			var want: String = OUTCOMES[outcome_i]
			var h := String(e.get("health", "ok"))
			if want == "Incomplete or damaged":
				if h == "ok" or h == "recording":
					continue
			elif String(e.get("outcome_label", "")) != want or h != "ok":
				continue
		if q != "":
			var hay := " ".join([String(e.get("title", "")),
				String(e.get("scenario_name", "")), String(e.get("mode_name", "")),
				String(e.get("outcome_label", "")), String(e.get("created_local", "")),
				" ".join(PackedStringArray(e.get("tags", [])))]).to_lower()
			var ok := true
			for word in q.split(" ", false):
				var w := String(word).trim_prefix("#")
				if not hay.contains(w):
					ok = false
					break
			if not ok:
				continue
		out.append(e)
	match sort_i:
		1: out.sort_custom(func(a, b) -> bool:
			return String(a.get("created", "")) < String(b.get("created", "")))
		2: out.sort_custom(func(a, b) -> bool:
			return float(a.get("duration", 0.0)) > float(b.get("duration", 0.0)))
		3: out.sort_custom(func(a, b) -> bool:
			return _ours(a) > _ours(b))
		4: out.sort_custom(func(a, b) -> bool:
			return String(a.get("title", "")).to_lower() < String(b.get("title", "")).to_lower())
		5: out.sort_custom(func(a, b) -> bool:
			return int(a.get("bytes", 0)) > int(b.get("bytes", 0)))
		_: out.sort_custom(func(a, b) -> bool:
			return String(a.get("created", "")) > String(b.get("created", "")))
	return out

static func _ours(e: Dictionary) -> int:
	var sc: Variant = e.get("score", {})
	return int((sc as Dictionary).get("ours", -1)) if sc is Dictionary else -1

# ==================================================================== build ==

func build(body: VBoxContainer) -> void:
	ensure_loaded()
	var suspended: bool = host.session_suspended.call() if host.session_suspended.is_valid() else false
	var busy: bool = host.replay_folder_busy.call() if host.replay_folder_busy.is_valid() else false

	if suspended:
		var warn := Gui.card(Gui.S8)
		body.add_child(warn[0])
		warn[1].add_child(Gui.para(("A run is paused behind this screen. You can "
			+ "browse, rename and tag replays now; to watch one, resume that run "
			+ "and finish it, or end it from the pause menu. It will not be "
			+ "discarded for you."), Gui.WARN))

	# ---- latest replay
	var top := Gui.card(Gui.S8)
	body.add_child(top[0])
	var tv: VBoxContainer = top[1]
	var latest := ReplayStore.latest(entries)
	if entries.is_empty():
		tv.add_child(Gui.section("No replays yet"))
		tv.add_child(Gui.para(("Every match and practice attempt you play is "
			+ "recorded here automatically, including ones you abandon part-way. "
			+ "Nothing to switch on. Play one and it will appear.")))
	elif latest.is_empty():
		tv.add_child(Gui.section("Latest replay"))
		tv.add_child(Gui.para("None of the replays here can be played; see the list below."))
	else:
		var head := Gui.hbox(Gui.S16)
		tv.add_child(head)
		var hv := Gui.vbox(2)
		hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hv.add_child(Gui.eyebrow("LATEST REPLAY"))
		hv.add_child(Gui.label(String(latest.get("title", "")), Gui.T_SECTION, Gui.INK))
		hv.add_child(Gui.note(_facts(latest)))
		var use0 := ReplayStore.usage(entries)
		hv.add_child(Gui.label("%d replays · %s on this computer (folder and options at the bottom of this page)" % [
			int(use0["replays"]), ReplayStore.size_text(int(use0["bytes"]))], Gui.T_SMALL, Gui.MUTED))
		head.add_child(hv)
		var w := Gui.primary("Watch latest  →", Vector2(210, 52))
		w.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		w.pressed.connect(func() -> void: host.request_watch(String(latest["id"]), false))
		head.add_child(w)
		var p := Gui.button("Practise from here", Gui.Look.SECONDARY, Vector2(0, 52))
		p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		p.pressed.connect(func() -> void: host.request_watch(String(latest["id"]), true))
		head.add_child(p)

	if entries.is_empty():
		_storage(body, busy)
		return

	# ---- search, sort, filter
	var tools := Gui.card(Gui.S8)
	body.add_child(tools[0])
	var tl: VBoxContainer = tools[1]
	var trow := Gui.hbox(Gui.S8)
	tl.add_child(trow)
	var search := Gui.line_edit("Search titles, situations, tags…", query)
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_submitted.connect(func(q: String) -> void:
		query = q
		shown = PAGE
		host.refresh())
	search.text_changed.connect(func(q: String) -> void: query = q)
	trow.add_child(search)
	var go := Gui.button("Search", Gui.Look.SECONDARY, Vector2(0, 46))
	go.pressed.connect(func() -> void:
		query = search.text
		shown = PAGE
		host.refresh())
	trow.add_child(go)
	trow.add_child(Gui.dropdown(SORTS, sort_i, func(i: int) -> void:
		sort_i = i
		host.refresh(), 200))
	trow.add_child(Gui.dropdown(MODES, mode_i, func(i: int) -> void:
		mode_i = i
		shown = PAGE
		host.refresh(), 180))
	trow.add_child(Gui.dropdown(OUTCOMES, outcome_i, func(i: int) -> void:
		outcome_i = i
		shown = PAGE
		host.refresh(), 230))
	var fav := Gui.button("★ Favourites", Gui.Look.OPTION, Vector2(0, 46))
	Gui.select(fav, favorites_only)
	fav.pressed.connect(func() -> void:
		favorites_only = not favorites_only
		shown = PAGE
		host.refresh())
	trow.add_child(fav)

	var list := filtered()
	var selrow := Gui.hbox(Gui.S8)
	tl.add_child(selrow)
	var count := Gui.label("%d of %d shown" % [mini(shown, list.size()), list.size()]
		+ ("" if selected.is_empty() else " · %d selected" % selected.size()), Gui.T_SMALL, Gui.MUTED)
	count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	selrow.add_child(count)
	selrow.add_child(Gui.spacer())
	var all := Gui.button("Select all shown", Gui.Look.GHOST, Vector2(0, 40))
	all.pressed.connect(func() -> void:
		for e in list.slice(0, shown):
			if String(e.get("health", "")) != "recording":
				selected[String(e["id"])] = true
		host.refresh())
	selrow.add_child(all)
	if not selected.is_empty():
		var clr := Gui.button("Clear selection", Gui.Look.GHOST, Vector2(0, 40))
		clr.pressed.connect(func() -> void:
			selected.clear()
			host.refresh())
		selrow.add_child(clr)
		var del := Gui.button("Delete %d selected…" % selected.size(), Gui.Look.SECONDARY, Vector2(0, 40))
		Gui.tint(del, Gui.RED_INK)
		del.pressed.connect(func() -> void: confirm_delete(selected.keys()))
		selrow.add_child(del)

	# ---- the rows
	var rows := Gui.card(Gui.S8)
	body.add_child(rows[0])
	var rv: VBoxContainer = rows[1]
	if list.is_empty():
		rv.add_child(Gui.para("No replays match. Clear the search or the filters to see them all."))
		_storage(body, busy)
		return
	var first := true
	for e in list.slice(0, shown):
		if not first:
			rv.add_child(Gui.divider())
		first = false
		rv.add_child(_row(e))
	if list.size() > shown:
		var more := Gui.button("Show %d more" % mini(PAGE, list.size() - shown),
			Gui.Look.SECONDARY, Vector2(0, 46))
		more.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		more.pressed.connect(func() -> void:
			shown += PAGE
			host.refresh())
		rv.add_child(more)
	_storage(body, busy)

func _storage(body: VBoxContainer, busy: bool) -> void:
	# ---- storage
	var st := Gui.card(Gui.S8)
	body.add_child(st[0])
	var sv: VBoxContainer = st[1]
	var use := ReplayStore.usage(entries)
	sv.add_child(Gui.section("Stored on this computer"))
	var path_lbl := Gui.label(ReplayStore.folder(), Gui.T_SMALL, Gui.INK, true)
	sv.add_child(path_lbl)
	sv.add_child(Gui.note(("%d replay%s · %d file%s · %s. No limit on how many "
		+ "are kept; disk space is the only limit, and nothing is ever deleted "
		+ "without you asking.") % [int(use["replays"]), "" if int(use["replays"]) == 1 else "s",
		int(use["files"]), "" if int(use["files"]) == 1 else "s",
		ReplayStore.size_text(int(use["bytes"]))]))
	var srow := Gui.hbox(Gui.S8)
	srow.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var open_b := Gui.button("Open replay folder", Gui.Look.SECONDARY, Vector2(0, 46))
	open_b.pressed.connect(func() -> void:
		ReplayStore.ensure_folder()
		OS.shell_open(ReplayStore.folder()))
	srow.add_child(open_b)
	var change := Gui.button("Change folder…", Gui.Look.SECONDARY, Vector2(0, 46))
	change.disabled = busy
	change.tooltip_text = "Finish the run being recorded first." if busy else \
		"Switch to another folder, or move your replays there"
	change.pressed.connect(func() -> void: _choose_folder())
	srow.add_child(change)
	if not ReplayStore.is_default_folder():
		var dflt := Gui.button("Use the default folder", Gui.Look.SECONDARY, Vector2(0, 46))
		dflt.disabled = busy
		dflt.pressed.connect(func() -> void: _folder_chosen(ReplayStore.default_folder()))
		srow.add_child(dflt)
	var refresh_b := Gui.button("Refresh list", Gui.Look.GHOST, Vector2(0, 46))
	refresh_b.tooltip_text = "Read the folder again (the list is rebuilt from the files)"
	refresh_b.pressed.connect(func() -> void:
		ReplayStore.rebuild_index()
		reload()
		host.refresh())
	srow.add_child(refresh_b)
	sv.add_child(srow)


func _facts(e: Dictionary) -> String:
	var parts: Array = []
	parts.append(String(e.get("created_local", "")))
	parts.append(ReplayStore._clock(float(e.get("duration", 0.0))))
	parts.append(String(e.get("mode_name", "")))
	if String(e.get("scenario_name", "")) != "":
		parts.append(String(e.get("scenario_name", "")))
	parts.append(String(e.get("outcome_label", "")))
	var sc: Variant = e.get("score", {})
	if sc is Dictionary and (sc as Dictionary).has("red"):
		parts.append("RED %d · BLUE %d%s" % [int(sc["red"]), int(sc["blue"]),
			"" if bool((sc as Dictionary).get("final", false)) else " (scoreboard)"])
	parts.append(ReplayStore.size_text(int(e.get("bytes", 0))))
	var out := " · ".join(parts.filter(func(p) -> bool: return String(p) != ""))
	var tags: Array = e.get("tags", [])
	if not tags.is_empty():
		out += "   " + " ".join(tags.map(func(tg) -> String: return "#" + String(tg)))
	return out

func _row(e: Dictionary) -> Control:
	var id := String(e["id"])
	var health := String(e.get("health", "ok"))
	var v := Gui.vbox(4)
	var h := Gui.hbox(Gui.S8)
	v.add_child(h)
	# a drawn tick box: the engine's default CheckBox icon is invisible on
	# this theme's dark panels
	var on_now := selected.has(id)
	var sel := Gui.button("☑" if on_now else "☐", Gui.Look.GHOST, Vector2(40, 40))
	sel.add_theme_font_size_override("font_size", 24)
	sel.add_theme_color_override("font_color", Gui.ACCENT if on_now else Gui.MUTED)
	sel.tooltip_text = "Select (for deleting several at once)"
	sel.disabled = health == "recording"
	sel.pressed.connect(func() -> void:
		if selected.has(id):
			selected.erase(id)
		else:
			selected[id] = true
		host.refresh())
	h.add_child(sel)
	var star := Gui.button("★" if bool(e.get("favorite", false)) else "☆", Gui.Look.GHOST, Vector2(40, 40))
	star.tooltip_text = "Favourite"
	star.add_theme_color_override("font_color", Gui.ACCENT if bool(e.get("favorite", false)) else Gui.MUTED)
	star.pressed.connect(func() -> void:
		if ReplayStore.set_favorite(id, not bool(e.get("favorite", false))):
			reload()
		else:
			host.show_note("Could not save that change to disk.")
		host.refresh())
	h.add_child(star)

	var info := Gui.vbox(2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(info)
	if editing_id == id:
		var edit := Gui.line_edit("Title" if editing_what == "title" else "tags, comma, separated",
			String(e.get("title", "")) if editing_what == "title"
			else ", ".join(PackedStringArray(e.get("tags", []))))
		info.add_child(edit)
		var er := Gui.hbox(Gui.S8)
		var save := Gui.button("Save", Gui.Look.SECONDARY, Vector2(0, 40))
		var commit := func() -> void:
			var ok := ReplayStore.set_title(id, edit.text) if editing_what == "title" \
				else ReplayStore.set_tags(id, edit.text)
			if not ok:
				host.show_note("Could not save that change." if editing_what == "tags"
					or edit.text.strip_edges() != "" else "A title cannot be empty.")
				return
			editing_id = ""
			reload()
			host.refresh()
		save.pressed.connect(commit)
		edit.text_submitted.connect(func(_t: String) -> void: commit.call())
		er.add_child(save)
		var cancel := Gui.button("Cancel", Gui.Look.GHOST, Vector2(0, 40))
		cancel.pressed.connect(func() -> void:
			editing_id = ""
			host.refresh())
		er.add_child(cancel)
		info.add_child(er)
		edit.call_deferred("grab_focus")
	else:
		var tl := Gui.label(String(e.get("title", id)), Gui.T_BODY, Gui.INK)
		tl.clip_text = true
		info.add_child(tl)
		info.add_child(Gui.note(_facts(e)))
	if health != "ok":
		var col := Gui.WARN if health in ["recovered", "recording"] else Gui.RED_INK
		info.add_child(Gui.label(String(e.get("health_note", "")), Gui.T_SMALL, col, true))

	var acts := Gui.hbox(6)
	acts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(acts)
	var playable := bool(e.get("playable", false)) and health != "recording"
	var watch := _small("Watch")
	watch.disabled = not playable
	watch.pressed.connect(func() -> void: host.request_watch(id, false))
	acts.add_child(watch)
	var pr := _small("Practise…")
	pr.disabled = not playable
	pr.tooltip_text = "Open the replay to choose a moment to practise from"
	pr.pressed.connect(func() -> void: host.request_watch(id, true))
	acts.add_child(pr)
	var rn := _small("Rename")
	rn.disabled = health == "missing" and e.get("title", "") == ""
	rn.pressed.connect(func() -> void:
		editing_id = id
		editing_what = "title"
		host.refresh())
	acts.add_child(rn)
	var tg := _small("Tags")
	tg.pressed.connect(func() -> void:
		editing_id = id
		editing_what = "tags"
		host.refresh())
	acts.add_child(tg)
	var sf := _small("Show file")
	sf.disabled = health == "missing"
	sf.pressed.connect(func() -> void:
		OS.shell_show_in_file_manager(String(e.get("path", ""))))
	acts.add_child(sf)
	var dl := _small("Delete")
	dl.disabled = health == "recording"
	Gui.tint(dl, Gui.RED_INK)
	dl.pressed.connect(func() -> void: confirm_delete([id]))
	acts.add_child(dl)
	return v

func _small(t: String) -> Button:
	var b := Gui.button(t, Gui.Look.SECONDARY, Vector2(0, 40))
	b.add_theme_font_size_override("font_size", Gui.T_SMALL)
	return b

# =================================================================== delete ==

## Ask first, with the exact numbers. `ids` may be one or many.
func confirm_delete(ids: Array) -> void:
	var n := ids.size()
	var files := 0
	var bytes := 0
	for e in entries:
		if ids.has(String(e["id"])):
			files += int(e.get("files", 0))
			bytes += int(e.get("bytes", 0))
	var d := ConfirmationDialog.new()
	d.title = "Delete replay%s" % ("" if n == 1 else "s")
	d.dialog_text = ("Delete %d replay%s? This removes %d file%s (%s) from\n%s\n\n"
		+ "It cannot be undone. Situations you saved from these replays are "
		+ "separate files and are not affected.") % [n, "" if n == 1 else "s",
		files, "" if files == 1 else "s", ReplayStore.size_text(bytes),
		ReplayStore.folder()]
	d.ok_button_text = "Delete %d" % n
	d.dialog_autowrap = true
	d.min_size = Vector2i(640, 0)
	host.add_child(d)
	d.confirmed.connect(func() -> void:
		var r := ReplayStore.delete(ids)
		for id in ids:
			selected.erase(String(id))
		reload()
		var failed: Array = r["failed"]
		host.show_note(("Deleted %d replay%s (%d files, %s)." % [int(r["deleted"]),
			"" if int(r["deleted"]) == 1 else "s", int(r["files"]),
			ReplayStore.size_text(int(r["bytes"]))])
			+ ("" if failed.is_empty() else " %d could not be deleted." % failed.size()))
		host.refresh()
		d.queue_free())
	d.canceled.connect(func() -> void: d.queue_free())
	d.popup_centered()
	d.get_cancel_button().grab_focus()

# =================================================================== folder ==

func _choose_folder() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.title = "Choose a folder for replays"
	fd.current_dir = ReplayStore.folder()
	host.add_child(fd)
	fd.dir_selected.connect(func(p: String) -> void:
		fd.queue_free()
		_folder_chosen(p))
	fd.canceled.connect(func() -> void: fd.queue_free())
	fd.popup_centered_ratio(0.6)

## SWITCH or MOVE — the player decides, and the dialog says what each does.
func _folder_chosen(p: String) -> void:
	if p == ReplayStore.folder():
		host.show_note("That is already the replay folder.")
		return
	var n := entries.size()
	var d := AcceptDialog.new()
	d.title = "Replay folder"
	d.dialog_text = ("New recordings will go to:\n%s\n\n"
		+ "SWITCH: use that folder from now on. The %d replay%s in the current "
		+ "folder stay where they are and show again if you switch back.\n"
		+ "MOVE: move the %d replay%s there as well, then switch. Each one is "
		+ "copied and checked before the original is removed.") % [p, n,
		"" if n == 1 else "s", n, "" if n == 1 else "s"]
	d.dialog_autowrap = true
	d.min_size = Vector2i(680, 0)
	d.ok_button_text = "Switch"
	if n > 0:
		d.add_button("Move %d and switch" % n, true, "move")
	d.add_cancel_button("Cancel")
	host.add_child(d)
	d.confirmed.connect(func() -> void:
		var err := ReplayStore.set_folder(p)
		host.show_note(err if err != "" else "Switched. New replays go to %s." % p)
		reload()
		host.refresh()
		d.queue_free())
	d.custom_action.connect(func(action: StringName) -> void:
		if action != "move":
			return
		var r := ReplayStore.move_all(p)
		var failed: Array = r["failed"]
		host.show_note(String(r["error"]) if String(r["error"]) != "" and int(r["moved"]) == 0
			else "Moved %d replay%s.%s" % [int(r["moved"]), "" if int(r["moved"]) == 1 else "s",
			"" if failed.is_empty() else " %d could not be moved and are still in the old folder." % failed.size()])
		reload()
		host.refresh()
		d.queue_free())
	d.canceled.connect(func() -> void: d.queue_free())
	d.popup_centered()
