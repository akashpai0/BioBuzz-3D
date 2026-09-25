class_name CameraRig
extends Node3D
##
## Three views, TAB cycles: CHASE (behind the robot), DRIVER (from the red
## ALLIANCE AREA, which is how you actually drive a match) and OVERHEAD.
##

## OVERVIEW is the replay viewer's wide angled view; like MENU it is set
## directly and never cycled into.
enum Mode { CHASE, DRIVER, OVERHEAD, MENU, OVERVIEW }

var mode: int = Mode.DRIVER
## Which driver station the DRIVER view stands at. Red's is at x = -124, blue's
## is the opposite end, so playing blue means looking the other way down the
## field — as it would be at an event.
var alliance: int = BB.Alliance.RED
var target: Node3D
## Everyone on the field. With two drivers, cycling all the way round the three
## views moves the CHASE camera to the next robot, so either driver can get a
## close look without a second key to learn.
var robots: Array[Robot] = []
var follow := 0
var cam: Camera3D

func _ready() -> void:
	# moved every frame from _process, so it must not be interpolated itself;
	# it follows the robots' interpolated (drawn) positions instead
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cam = Camera3D.new()
	cam.fov = Settings.get_value("game/fov")
	cam.add_to_group("player_cam")      # so Settings can retune the FOV live
	cam.far = 200.0
	add_child(cam)
	cam.current = true

var _orbit := 0.0

func cycle() -> void:
	mode = (mode + 1) % 3          # MENU is set directly, never cycled into
	if mode == Mode.CHASE and robots.size() > 1:
		follow = (follow + 1) % robots.size()

## Who the CHASE camera is behind. Falls back to `target` whenever the roster
## is empty or the robot it was following has been freed.
func focus() -> Node3D:
	if follow < robots.size():
		var r: Robot = robots[follow]
		if is_instance_valid(r):
			return r
	return target

func mode_name() -> String:
	return ["CHASE", "DRIVER", "OVERHEAD", "MENU", "OVERVIEW"][mode]

func _process(delta: float) -> void:
	if target == null:
		return
	var want_pos: Vector3
	var look: Vector3
	match mode:
		Mode.CHASE:
			var who := focus()
			var drawn := who.get_global_transform_interpolated()
			var back := drawn.basis.z
			want_pos = drawn.origin + back * BB.m(52.0) + Vector3.UP * BB.m(34.0)
			# Keep the chase camera inside the perimeter. Parked against a wall
			# it would otherwise sit outside the field and fill half the screen
			# with the back of the wall.
			var lim := BB.m(BB.FIELD_HALF - 4.0)
			want_pos.x = clampf(want_pos.x, -lim, lim)
			want_pos.z = clampf(want_pos.z, -lim, lim)
			look = drawn.origin + Vector3.UP * BB.m(8.0)
		Mode.DRIVER:
			# stood in the red ALLIANCE AREA at a driver's eye height, looking
			# across the field the way you actually would at a competition
			var side := -1.0 if alliance == BB.Alliance.RED else 1.0
			want_pos = BB.fp(124.0 * side, 0.0, BB.DRIVER_EYE)
			look = Vector3(0, BB.m(14.0), 0).lerp(target.get_global_transform_interpolated().origin, 0.35)
		Mode.OVERHEAD:
			want_pos = Vector3(0, BB.m(168.0), BB.m(1.0))
			look = Vector3.ZERO
		Mode.OVERVIEW:
			# the whole field from high behind the driver's end, angled so
			# robot heights and ball arcs still read
			var side := -1.0 if alliance == BB.Alliance.RED else 1.0
			want_pos = Vector3(side * BB.m(122.0), BB.m(112.0), 0.0)
			look = Vector3(side * BB.m(8.0), 0.0, 0.0)
		Mode.MENU:
			# slow orbit of the whole arena behind the title screen
			_orbit += delta * 0.055
			want_pos = Vector3(sin(_orbit) * BB.m(126.0), BB.m(74.0), cos(_orbit) * BB.m(126.0))
			look = Vector3(0, BB.m(26.0), 0)
	var t := 1.0 - pow(0.001, delta)
	cam.global_position = cam.global_position.lerp(want_pos, t if mode == Mode.CHASE else 1.0)
	cam.look_at(look, Vector3.UP)
