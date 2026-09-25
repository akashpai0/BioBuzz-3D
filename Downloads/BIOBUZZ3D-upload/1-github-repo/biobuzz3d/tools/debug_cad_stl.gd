extends Node3D
## STL IMPORT: parses binary and ASCII STL (incl. tabs, "solid" headers on
## binary files), faces point OUT (Godot draws clockwise faces as the front;
## STL files list them counter-clockwise), Z-up CAD stands upright, and an
## oversized file is refused with a sentence that says how to fix it.
## Renders one picture per case to user://cad_*.png.
var fails := 0
func _ok(what: String, got: Variant, want: Variant = true) -> void:
	var good: bool = got == want
	if not good: fails += 1
	print("  [%s] %s%s" % ["ok" if good else "FAIL", what, "" if good else "  (got %s, want %s)" % [got, want]])

## A 2 x 1 x 4 box, Z-up like CAD, faces counter-clockwise seen from outside.
func _box_tris() -> Array:
	var p := func(x: float, y: float, z: float) -> Vector3: return Vector3(x * 2.0, y, z * 4.0)
	var c := []
	for i in 8:
		c.append(p.call(float(i & 1), float((i >> 1) & 1), float((i >> 2) & 1)))
	var quads := [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
	var t := []
	for q in quads:
		t.append([c[q[0]], c[q[1]], c[q[2]]])
		t.append([c[q[0]], c[q[2]], c[q[3]]])
	return t

func _write_binary(path: String, header: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	var h := header.to_ascii_buffer()
	h.resize(80)
	f.store_buffer(h)
	var tris := _box_tris()
	f.store_32(tris.size())
	for t in tris:
		var n: Vector3 = ((t[1] - t[0]).cross(t[2] - t[0])).normalized()
		for v in [n, t[0], t[1], t[2]]:
			f.store_float(v.x); f.store_float(v.y); f.store_float(v.z)
		f.store_16(0)
	f.close()

func _write_ascii(path: String) -> void:
	var s := "solid box\n"
	for t in _box_tris():
		var n: Vector3 = ((t[1] - t[0]).cross(t[2] - t[0])).normalized()
		s += "\tfacet normal\t%f %f %f\n\t\touter loop\n" % [n.x, n.y, n.z]
		for v in t:
			s += "\t\t\tvertex\t%f\t%f\t%f\n" % [v.x, v.y, v.z]
		s += "\t\tendloop\n\tendfacet\n"
	s += "endsolid box\n"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(s)
	f.close()

## Share of triangles whose Godot front side faces away from the mesh centre.
func _inward_share(model: Node3D) -> float:
	var mi: MeshInstance3D = CadImport._all_meshes(model)[0]
	var arr := mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var centre := mi.get_aabb().get_center()
	var inward := 0
	for i in range(0, v.size(), 3):
		# Godot's front face is clockwise: its outward normal is (c-a) x (b-a)
		var n := (v[i + 2] - v[i]).cross(v[i + 1] - v[i])
		var mid := (v[i] + v[i + 1] + v[i + 2]) / 3.0
		if n.dot(mid - centre) < 0.0:
			inward += 1
	return float(inward) / float(v.size() / 3)

## Volume enclosed by the mesh using Godot's front-face (clockwise) winding:
## positive when the faces point out, negative when drawn inside-out. Works for
## an assembly of many closed parts, where "away from the centre" does not.
func _signed_volume(model: Node3D) -> float:
	var mi: MeshInstance3D = CadImport._all_meshes(model)[0]
	var v: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var vol := 0.0
	for i in range(0, v.size(), 3):
		vol += v[i].dot(v[i + 2].cross(v[i + 1]))
	return vol / 6.0

func _ready() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0.9, 0.55, 0.9)
	cam.look_at_from_position(cam.position, Vector3(0, 0.2, 0))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var cases := {
		"binary": "user://cad_box_bin.stl",
		"binary_solid_header": "user://cad_box_solidhdr.stl",
		"ascii_tabs": "user://cad_box_ascii.stl"}
	_write_binary(cases["binary"], "STLB ATF 15.15.0.0 COLOR=")
	_write_binary(cases["binary_solid_header"], "solid exported by a CAD that lies")
	_write_ascii(cases["ascii_tabs"])
	for k in cases:
		var err: Array = []
		var m := CadImport.load_model(ProjectSettings.globalize_path(cases[k]), err)
		_ok("%s: loads" % k, m != null)
		if m == null:
			print("    ", err)
			continue
		_ok("  %s: 12 triangles" % k, CadImport.triangle_count(m), 12)
		_ok("  %s: faces point outward (not drawn inside-out)" % k, _inward_share(m) < 0.01 and _signed_volume(m) > 0.0, true)
		add_child(m)
		CadImport.fit_to_robot(m, 1.0, CadImport.up_rotation(CadImport.default_up(cases[k])))
		var box := CadImport._bounds(m, Transform3D.IDENTITY)
		var world := m.transform * box
		_ok("  %s: Z-up CAD stands upright (tallest side is the height)" % k,
			world.size.y > world.size.x and world.size.y > world.size.z, true)
		_ok("  %s: sits on the floor" % k, absf(world.position.y) < 0.002, true)
		await get_tree().process_frame
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://cad_%s.png" % k)
		m.queue_free()
		await get_tree().process_frame
	# a real team file, if one is given: `-- <path to .stl>`
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and FileAccess.file_exists(args[0]):
		var t0 := Time.get_ticks_msec()
		var e3: Array = []
		var real := CadImport.load_model(args[0], e3)
		var first_ms := Time.get_ticks_msec() - t0
		_ok("real file %s loads" % args[0].get_file(), real != null)
		if real != null:
			print("    %s triangles, first load %d ms" % [CadImport.triangle_count(real), first_ms])
			t0 = Time.get_ticks_msec()
			var again := CadImport.load_model(args[0], e3)
			var second_ms := Time.get_ticks_msec() - t0
			_ok("  loading it again comes from memory (under 50 ms)", second_ms < 50, true)
			print("    second load %d ms" % second_ms)
			again.free()
			_ok("  faces point outward (enclosed volume is positive in Godot's winding)", _signed_volume(real) > 0.0, true)
			add_child(real)
			CadImport.fit_to_robot(real, 1.0, CadImport.up_rotation("z"))
			await get_tree().process_frame
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("user://cad_real.png")
			real.queue_free()
	# an oversized file: refused with a sentence that says how to fix it
	var big := "user://cad_big.stl"
	var f := FileAccess.open(big, FileAccess.WRITE)
	var h := PackedByteArray(); h.resize(80); f.store_buffer(h)
	f.store_32(10248998)
	f.close()
	var err2: Array = []
	var none := CadImport.load_model(ProjectSettings.globalize_path(big), err2)
	_ok("a 10-million-triangle STL is refused", none == null)
	_ok("  and the message says how to export a lighter one",
		not err2.is_empty() and String(err2[0]).contains("Export it again"), true)
	print("    said: ", err2)
	print("  STL IMPORT %s (%d failures)" % ["OK" if fails == 0 else "BROKEN", fails])
	get_tree().quit(1 if fails else 0)
