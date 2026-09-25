extends Node
##
## LOADING A TEAM'S OWN CAD.
##
## Autoloaded as `CadImport`. Handles the two formats that actually come out of
## the CAD a team is using:
##
##   .glb / .gltf   the good one — materials, colours, a node tree. Onshape,
##                  Fusion and SolidWorks all export it. Loaded at runtime with
##                  GLTFDocument.
##   .stl           the one everybody exports first. Triangles and nothing
##                  else, so it arrives untextured and gets a plain material.
##                  Parsed here, because Godot has no runtime STL loader.
##
## IMPORTANT, and said plainly on the import screen: the CAD is the ROBOT'S
## APPEARANCE ONLY. Collision stays the 18 inch cube R102 requires, and the
## drivetrain still comes from the SPECS page. Building a collision hull out of
## arbitrary imported geometry is how you get a robot that catches on its own
## intake and sinks through the floor — and since every legal robot starts
## inside an 18 in cube anyway, the cube is not much of a lie.
##

## Files bigger than this are refused. A robot assembly exported with every
## screw is tens of megabytes of triangles nobody can see, and it will drop the
## frame rate through the floor.
const MAX_BYTES := 48 * 1024 * 1024
const MAX_TRIS := 400000
const HOW_TO_LIGHTEN := ("Export it again at lower detail (Fusion: Refinement Low; "
	+ "SolidWorks: Resolution Coarse; Onshape: Resolution Coarse), or leave out "
	+ "screws and inside parts.")

## Loaded meshes, so the garage preview, the match robots and every rebuild do
## not re-read a big file: path -> {"stamp": modified time, "node": Node3D}.
var _cache := {}

## Loads `path` and returns a Node3D you can add to the scene, or null.
## `err` is filled in with something a person can read.
func load_model(path: String, err: Array = []) -> Node3D:
	if not FileAccess.file_exists(path):
		err.append("No file at that path.")
		return null
	var size := _file_size(path)
	if size > MAX_BYTES:
		err.append(("That file is %.0f MB — the limit is %d MB. " % [size / 1048576.0, MAX_BYTES / 1048576])
			+ HOW_TO_LIGHTEN)
		return null
	var ext := path.get_extension().to_lower()
	var stamp := FileAccess.get_modified_time(path)
	var hit: Dictionary = _cache.get(path, {})
	if not hit.is_empty() and int(hit["stamp"]) == stamp and is_instance_valid(hit["node"]):
		return (hit["node"] as Node3D).duplicate()
	var loaded: Node3D = null
	match ext:
		"glb", "gltf": loaded = _load_gltf(path, err)
		"stl": loaded = _load_stl(path, err)
		_:
			err.append("Unsupported format .%s — export as GLB, glTF or STL." % ext)
			return null
	if loaded == null:
		return null
	for old in _cache.values():
		if is_instance_valid(old["node"]):
			(old["node"] as Node).free()
	hull_points(loaded)
	_cache = {path: {"stamp": stamp, "node": loaded}}
	return loaded.duplicate()

## Which way is up in the file. STL from CAD is almost always Z-up (the
## 3D-printing convention); glTF is Y-up by definition.
static func default_up(path: String) -> String:
	return "z" if path.get_extension().to_lower() == "stl" else "y"

## The starting rotation (degrees) that stands a file of each kind upright.
static func up_rotation(up: String) -> Vector3:
	match up:
		"z": return Vector3(-90, 0, 0)     # (x, y, z) -> (x, z, -y)
		"x": return Vector3(0, 0, 90)      # +X -> +Y
	return Vector3.ZERO

## Degrees -> the model's turn: tip about X, roll about Z, then turn about Y.
static func rot_basis(rot_deg: Vector3) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(rot_deg.y)) \
		* Basis(Vector3.BACK, deg_to_rad(rot_deg.z)) \
		* Basis(Vector3.RIGHT, deg_to_rad(rot_deg.x))

static func _commas(n: int) -> String:
	var t := str(n)
	var out := ""
	while t.length() > 3:
		out = "," + t.substr(t.length() - 3) + out
		t = t.substr(0, t.length() - 3)
	return t + out

func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n

func _load_gltf(path: String, err: Array) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	# EXTRACT_TEXTURES would want a writable res://, which a shipped game has
	# not got; keeping them in memory is what we want anyway.
	var code := doc.append_from_file(path, state)
	if code != OK:
		err.append("Godot could not read that glTF (error %d). Re-export it." % code)
		return null
	var scene := doc.generate_scene(state)
	if scene == null:
		err.append("That glTF has no scene in it.")
		return null
	return scene as Node3D

## Binary and ASCII STL. Binary is an 80-byte header, a uint32 triangle count,
## then 50 bytes per triangle: a normal and three vertices as float32, plus a
## two-byte attribute word almost nobody uses.
func _load_stl(path: String, err: Array) -> Node3D:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		err.append("Could not open that file.")
		return null
	var head := f.get_buffer(5)
	f.seek(0)
	var ascii := head.get_string_from_ascii().to_lower().begins_with("solid")
	# "solid" is not proof: plenty of binary exporters write it into the header
	# anyway, so confirm against the length the triangle count implies.
	if ascii and f.get_length() > 84:
		f.seek(80)
		var claimed := f.get_32()
		if f.get_length() == 84 + claimed * 50:
			ascii = false
		f.seek(0)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	if ascii:
		_parse_ascii_stl(f, verts, normals)
	else:
		if not _parse_binary_stl(f, verts, normals, err):
			f.close()
			return null
	f.close()
	if verts.size() < 3:
		err.append("No triangles in that STL.")
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	# STL carries no colour at all, so it gets a neutral machined grey rather
	# than whatever the last material in the scene happened to be.
	mi.material_override = BB.mat(Color(0.62, 0.64, 0.68), 0.45, 0.25)
	var root := Node3D.new()
	root.add_child(mi)
	return root

func _parse_binary_stl(f: FileAccess, verts: PackedVector3Array,
		normals: PackedVector3Array, err: Array) -> bool:
	f.seek(80)
	var count := f.get_32()
	if count <= 0 or count > MAX_TRIS:
		err.append(("That STL has %s triangles — the limit is %s. " % [_commas(count), _commas(MAX_TRIS)])
			+ HOW_TO_LIGHTEN)
		return false
	verts.resize(count * 3)
	normals.resize(count * 3)
	if f.get_length() < 84 + count * 50:
		err.append("That STL is cut short: it says %s triangles but the file ends early. Export it again." % _commas(count))
		return false
	var buf := f.get_buffer(count * 50)
	for i in count:
		var o := i * 50
		var a := Vector3(buf.decode_float(o + 12), buf.decode_float(o + 16), buf.decode_float(o + 20))
		var b := Vector3(buf.decode_float(o + 24), buf.decode_float(o + 28), buf.decode_float(o + 32))
		var c := Vector3(buf.decode_float(o + 36), buf.decode_float(o + 40), buf.decode_float(o + 44))
		_emit(verts, normals, i * 3, a, b, c)
	return true

## STL lists a triangle's corners counter-clockwise seen from outside; Godot
## draws CLOCKWISE triangles as the front. Emit a, c, b — or the model is drawn
## inside-out (its outside culled, its far inside walls showing). The normal is
## worked out from the corners: many exporters write zeros there.
static func _emit(verts: PackedVector3Array, normals: PackedVector3Array, k: int,
		a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a).normalized()
	verts[k] = a
	verts[k + 1] = c
	verts[k + 2] = b
	normals[k] = n
	normals[k + 1] = n
	normals[k + 2] = n

func _parse_ascii_stl(f: FileAccess, verts: PackedVector3Array,
		normals: PackedVector3Array) -> void:
	var corner: Array[Vector3] = []
	while not f.eof_reached():
		# tabs or runs of spaces: exporters use both
		var p := f.get_line().strip_edges().replace("\t", " ").split(" ", false)
		if p.size() >= 4 and p[0].to_lower() == "vertex":
			corner.append(Vector3(p[1].to_float(), p[2].to_float(), p[3].to_float()))
			if corner.size() == 3:
				var k := verts.size()
				verts.resize(k + 3)
				normals.resize(k + 3)
				_emit(verts, normals, k, corner[0], corner[1], corner[2])
				corner.clear()
		elif p.size() >= 1 and p[0].to_lower() == "endloop":
			corner.clear()
		if verts.size() > MAX_TRIS * 3:
			return

## Scale and centre an imported model so it sits inside the 18 in cube with its
## feet on the tiles, whatever units the CAD was in. Millimetre and inch
## exports differ by a factor of 25, so guessing is not optional.
func fit_to_robot(model: Node3D, extra_scale := 1.0, rot_deg := Vector3.ZERO) -> void:
	var raw := _bounds(model, Transform3D.IDENTITY)
	if raw.size.length() < 0.00001:
		return
	# turn it first, then measure it the way it now sits — from the hull
	# points, not the turned box, or a model tipped 30 degrees floats above
	# the tiles by the corners of a box it does not fill
	var turn := rot_basis(rot_deg)
	var hull := hull_points(model)
	var aabb := AABB()
	if hull.is_empty():
		aabb = Transform3D(turn, Vector3.ZERO) * raw
	else:
		aabb = AABB(turn * hull[0], Vector3.ZERO)
		for p in hull:
			aabb = aabb.expand(turn * p)
	var longest: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var target := BB.m(BB.ROBOT_CUBE)
	var s := target / longest * extra_scale
	model.transform.basis = turn * Basis.from_scale(Vector3(s, s, s))
	# centre it horizontally on the chassis and stand it on the floor
	var c := aabb.get_center() * s
	model.position = Vector3(-c.x, -aabb.position.y * s, -c.z)

## The model's convex-hull corners in its own space: the only points that
## can ever touch the floor or the edge of the cube, whatever way it is turned.
## Worked out once per model and kept on it (duplicates carry it along).
func hull_points(model: Node3D) -> PackedVector3Array:
	if model.has_meta("hull"):
		return model.get_meta("hull")
	var pts := PackedVector3Array()
	for child in _all_meshes(model):
		var mi: MeshInstance3D = child
		if mi.mesh == null:
			continue
		var rel := model.global_transform.affine_inverse() * mi.global_transform \
			if model.is_inside_tree() and mi.is_inside_tree() else _rel_xform(model, mi)
		var shape := mi.mesh.create_convex_shape(true, false)
		if shape == null:
			continue
		for p in shape.points:
			pts.append(rel * p)
	model.set_meta("hull", pts)
	return pts

## `n`'s transform relative to `root` when neither is in the tree yet.
func _rel_xform(root: Node, n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t

## Union of every mesh AABB under `n`, in `n`'s own space.
func _bounds(n: Node3D, xform: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	for child in _all_meshes(n):
		var mi: MeshInstance3D = child
		var box: AABB = mi.get_aabb()
		var rel := n.global_transform.affine_inverse() * mi.global_transform \
			if n.is_inside_tree() and mi.is_inside_tree() else mi.transform
		box = rel * box
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out

func _all_meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_all_meshes(c))
	return out

## How many triangles are in a loaded model — shown on the import screen,
## because it is the number that decides whether the game still runs.
func triangle_count(n: Node) -> int:
	var total := 0
	for m in _all_meshes(n):
		var mesh: Mesh = (m as MeshInstance3D).mesh
		if mesh == null:
			continue
		for si in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			total += (idx.size() if idx.size() > 0 else v.size()) / 3
	return total

## Copy a chosen file into user:// so it survives the game being moved and the
## original being deleted. Returns the new path, or "".
func stash(src: String) -> String:
	DirAccess.make_dir_recursive_absolute(RobotShop.MODEL_DIR)
	var dst := "%s/robot.%s" % [RobotShop.MODEL_DIR, src.get_extension().to_lower()]
	var data := FileAccess.get_file_as_bytes(src)
	if data.is_empty():
		return ""
	var out := FileAccess.open(dst, FileAccess.WRITE)
	if out == null:
		return ""
	out.store_buffer(data)
	out.close()
	return dst
