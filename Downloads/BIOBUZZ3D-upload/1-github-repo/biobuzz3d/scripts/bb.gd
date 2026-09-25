extends Node
##
## BB — global constants, geometry helpers and input map for BIOBUZZ 3D.
##
## EVERY DIMENSION BELOW IS IN INCHES and comes from the FTC BIOBUZZ Competition
## Manual V1 (2026-09-12) as distilled in DSIM's docs/biobuzz-reference.md.
## Multiply by IN to get Godot metres.
##
## FRAME OF REFERENCE
##   sim x  (audience's right)     -> Godot +X
##   sim y  (away from audience)   -> Godot -Z
##   height above tiles            -> Godot +Y
##   Use fp(x, y, z) to convert a manual coordinate into a Godot position.
##   RED is x < 0 (audience left, manual G304.A), BLUE is x > 0.
##

const IN := 0.0254
const GRAV := 9.81

enum Alliance { RED, BLUE }
enum Kind { POLLEN, NECTAR }
enum Phase { PRE, AUTO, TRANSITION, TELEOP, SETTLE, DONE }
## Full match runs AUTO -> TRANSITION -> TELEOP. The other two exist so drivers
## can practise without sitting through a dead 30 s every time.
enum Mode { FULL_MATCH, TELEOP_ONLY, FREE_PRACTICE }

# ---------------------------------------------------------------- field (S9.2)
const FIELD_HALF := 72.0          # 144 x 144 in inside the walls
const WALL_H := 12.0
const WALL_T := 1.5
const TILE := 24.0                # 36 soft tiles, 24 x 24 x 0.59

# ------------------------------------------------------- elements (S9.8, p74)
const POLLEN_DIA := 2.8           # in   (am-5851, yellow)
const NECTAR_DIA := 3.6           # in   (am-5852, red / blue)
## Mass is NOT published in the manual. These two values are chosen so the
## manual's HIVE tip table (S4.1: 8 pollen empty, 3 pollen + 3 nectar) falls
## out of the rigid-body sim instead of being hard-coded. See DEVLOG.md.
## Element masses and the HIVE tip threshold, per the team's own figures:
## a CELL tips at 0.44 lb of load, which is 8 POLLEN or 6 NECTAR or any mix.
## That fixes POLLEN at 0.44/8 lb and NECTAR at 0.44/6 lb.
const TIP_LB := 0.44
const LB := 0.45359237
const POLLEN_MASS := TIP_LB / 8.0 * LB     # 0.0249 kg
## NECTAR is NOT simply TIP_LB / 6.
##
## The rule is that six NECTAR tips a HIVE and five does not. That fixes a
## RANGE for the ball, not a single value: anything from TIP_MASS/6 (0.0333 kg,
## where six lands exactly on the catch) up to just under TIP_MASS/5 (0.0399)
## satisfies it. Making it exactly TIP_MASS/6 is the tidy-looking choice and it
## is WRONG on the field, because it means a full NECTAR load and a full POLLEN
## load weigh precisely the same and therefore tip at precisely the same speed
## - whereas a real all-NECTAR load visibly goes over quicker.
##
## So: take the top of the range instead. Six NECTAR then OVERSHOOT the 0.44 lb
## catch by ~12% where eight POLLEN land exactly on it, which is more torque and
## a faster swing, for the same reason a heavier load of anything tips faster.
## The hard ceiling is five NECTAR, which must still HOLD: 5 x 0.0385 = 0.1925
## kg against a 0.1983 kg catch. Everything below that is free, and the mixed
## rows move with it - 4 NECTAR + 2 POLLEN now tips where it used to hold,
## which is a step TOWARD the manual's table (it says 4 NECTAR + 1 POLLEN goes
## over) rather than away from it.
##
## The margin has to be this wide for a reason. At the tidy TIP_MASS/6 the two
## full loads weigh the same and tip at the same speed; at 0.0371 the NECTAR
## edge was about 3%, which is SMALLER than the run-to-run spread from where
## the balls happen to settle - so "nectar is faster" was true on average and
## visibly false on plenty of individual tips. 0.0385 puts the edge at ~16%,
## comfortably outside that noise.
const NECTAR_MASS := 0.0385                # kg (range allows 0.0333 - 0.0396)
const TIP_MASS := TIP_LB * LB              # 0.1996 kg in the raised CELL
## A twentieth of a POLLEN. Enough to absorb float rounding on a load that is
## meant to be exactly at the threshold, far too small to admit one fewer ball.
const TIP_EPS := POLLEN_MASS * 0.05
const POLLEN_TOTAL := 40
## Damping applied to a loose element. These are DAMP_MODE_REPLACE values, so
## they are exactly what the physics uses AND exactly what the launcher's
## ballistic solver models — if the two ever disagree, every shot falls short.
const ELEMENT_LINEAR_DAMP := 0.12
## High, because these are perforated plastic balls on foam tiles, not marbles:
## once one stops it STAYS stopped until something pushes it. See element.gd,
## which also brakes a slow-moving ball that is touching the floor.
const ELEMENT_ANGULAR_DAMP := 4.5
## Low, so a ball has to be nearly stopped before the anti-roll brake touches
## it — otherwise the brake eats the bounces.
const ELEMENT_REST_SPEED := 2.5       # in/s
const ELEMENT_FRICTION := 0.72
## Bounce lives in the TILES, not in the balls. Jolt combines restitution by
## taking the larger of the pair, so a springy mat gives a lively floor bounce
## while ball-on-ball stays calm — which matters because a shot that pings off
## the load already in a CELL flies straight back out of the mouth.
const TILE_BOUNCE := 0.55
const ELEMENT_BOUNCE := 0.30          # hollow plastic on a foam mat: it bounces,
                                      # but not so hard that a shot rebounds out
                                      # of a CELL off the load already in there
const NECTAR_PER_ALLIANCE := 8

# ------------------------------------------------- HIVE structure (S9.6, p69)
const HIVE_PIVOT_Y := 43.95       # pivot axis height above the tiles
const HIVE_PIVOT_X := 12.75       # centre-to-centre 25.5 -> red -12.75, blue +12.75
const HIVE_TILT := 30.0           # deg from level in each stable state
const CELL_CENTRE := 15.44        # along the tilted axis, from the pivot
const CELL_INNER := 9.42
const CELL_OUTER := 21.46
const CELL_DEPTH := 12.04         # along the axis
const CELL_WIDTH := 20.0          # across x, NOT foreshortened
const CELL_HEIGHT := 14.0         # interior height of the opening (S9.6.2, Fig 9-11)
const CELL_SHELL := 1.2           # wall thickness

## THE CELL IS OPEN AT ITS OUTER END ONLY (owner ruling 2026-09-12). It is a
## closed box 20 wide x 14 tall x 12 deep whose single 20 x 14 opening is the
## face perpendicular to the bar at the end AWAY from the pivot — not an
## open-topped tray. Raised, that mouth faces up-and-outboard, so a LAUNCH has
## to arrive travelling TOWARD the pivot, from outboard of the cell. Lowered,
## the mouth faces down-and-outboard, which is where a TIP dumps its load.
## Everything about aiming follows from this, so do not "simplify" it back to an
## open top: that would make the game trivially easier than the real field.
const CELL_OPEN_OUTER_ONLY := true
## Raised-cell opening, above the tiles (Fig 9-10): top 65.6, bottom 53.5.
const CELL_MOUTH_TOP := 65.6
const CELL_MOUTH_BOTTOM := 53.5
const HIVE_FRAME_X := 24.5        # leg plane; bars occupy |x| in [24, 25]
const HIVE_FRAME_FOOT := 19.4     # +- y
const HIVE_CLEARANCE := 25.5      # drivable height under a HIVE (G409)

## Bi-stable holding torque, N*m, resisting a swing back through centre.
## Calibrated headless so a resting 8-POLLEN load tips an empty cell and 7 does
## not (Event Field Setup Guide S12.3). Tunable in the pause menu.
const HIVE_HOLD_TORQUE := 3.20   # held solid below TIP_MASS; released above it
## How hard the HIVE's dampers fight the swing - the ONE number that sets how
## long a tip takes, since the load torque is fixed by the 0.44 lb rule.
## Solved by tools/tip_time.tscn: 0.50 puts a full eight-POLLEN load at 3.98 s.
const HIVE_ANGULAR_DAMP := 0.50
const HIVE_SWING_DAMP := 0.22

## Staged pose (S10.3.1, Fig 10-2): each HIVE is tilted so the CELL that points
## at a FLOWER is DOWN. Red's raised CELL is SOUTH (y < 0), blue's is NORTH.
## In swing-local terms cell A is +Z, which is manual -y (south), and cell A is
## raised when the tilt sign is -1.
const STAGED_TILT := {Alliance.RED: -1, Alliance.BLUE: 1}

# ------------------------------------------------------- FLOWERS (S9.7, p72)
const FLOWER_RING_DIA := 4.0      # top ring opening
const FLOWER_TOP_Y := 21.5        # opening height above tiles
const FLOWER_MID_Y := 3.98        # top of the middle ring
const FLOWER_PIPES := 4           # HIPS pipes joining the top and middle rings
const FLOWER_PIPE_DIA := 0.75
const FLOWER_PLATE := 5.0         # top ring plate, a ~5 in rounded square
const FLOWER_SCORE_LO := 3.98     # scoring volume: top of middle ring ...
const FLOWER_SCORE_HI := 21.5     # ... to the top ring (S10.5.2)
const FLOWER_RETRIEVE_H := 3.55   # bottom opening, pollen out only (G418)
const FLOWER_LOWER_HOLE := 2.79   # lower ring hole: cradles a 2.8 pollen
const FLOWER_OFF_WALL := 2.54     # ring centre, from the wall face
const FLOWER_BOX_W := 6.0
const FLOWER_BOX_D := 4.9

## id, centre x, centre y, outward wall normal (deg about +Y), nearest alliance
const FLOWERS := [
	{"id": "F1", "x": -69.46, "y": -24.0, "wall": Vector2(-1, 0), "near": Alliance.RED},
	{"id": "F2", "x": -24.0, "y": 69.46, "wall": Vector2(0, 1), "near": Alliance.RED},
	{"id": "F3", "x": 69.46, "y": 24.0, "wall": Vector2(1, 0), "near": Alliance.BLUE},
	{"id": "F4", "x": 24.0, "y": -69.46, "wall": Vector2(0, -1), "near": Alliance.BLUE},
]

# ------------------------------------------------------- zones (S9.3, Fig 9-2)
## Point-symmetric, NOT mirrored. Rects are [x0, y0, x1, y1] in manual inches.
const LOADING_RED := [-72.0, 24.0, -61.0, 48.0]
const LOADING_BLUE := [61.0, -48.0, 72.0, -24.0]
const GARDEN_RED := [-72.0, -72.0, -49.0, -70.0]
const GARDEN_BLUE := [49.0, 70.0, 72.0, 72.0]

# ------------------------------------------------------- match (S10.4, T9-1)
## THE SCORING RULES' REVISION.
##
## Bump this whenever a scoring rule, a point value or a measured metric
## changes. Practice attempts record it, so a personal best set under the old
## rules is never silently compared against one set under the new ones.
const RULES_REV := 1

## THE STOCK ROBOT'S FEEL. One edit point: Robot defaults, the Garage's spec
## strip and the Play screen's fact row all read these.
const DRIVE_SPEED_IN_S := 68.0
const TURN_RATE_DEG_S := 460.0

const AUTO_S := 30.0
const TRANSITION_S := 8.0
const TELEOP_S := 120.0
const FLOWER_NECTAR_UNLOCK := 60.0   # G410: no NECTAR into a FLOWER before 1:00 left
const ENDGAME_S := 20.0
const SETTLE_S := 2.8                # score is harvested from the field AT REST

# ------------------------------------------------------ scoring (T10-2, p91)
const PTS_LEAVE := 3
const PTS_PARK := 5
const PTS_TIP := 20
const PTS_IN_CELL := 2
const PTS_IN_OWNED_FLOWER := 2
const PTS_BOTTOM_NECTAR := 5
const PTS_GARDEN := 1
const FOUL_MINOR := 5
const FOUL_MAJOR := 20

# ---------------------------------------------------------- robot (S12, R102)
const ROBOT_CUBE := 18.0          # R102 starting configuration
const ROBOT_MASS := 13.6          # kg (~30 lb); R104 sets no weight limit
const ROBOT_BODY_H := 9.0
const WHEEL_R := 2.0
## G407: "A ROBOT may not simultaneously CONTROL more than 4 SCORING ELEMENTS."
## The robot is physically able to take a couple more than that — which is the
## only way the rule can ever be broken, and therefore the only way it can be
## taught. HOPPER_CAP is the LEGAL limit; HOPPER_MAX is what fits.
const HOPPER_CAP := 4
## The intake physically stops at the legal four — you cannot suck up a fifth.
## G407 is still reachable, because CONTROL is not only what is inside the
## robot: a ball being DRAGGED along counts too. See Robot.herded_count().
const HOPPER_MAX := 4
## How far past a bumper the intake reaches. A one-intake robot gets this in
## front only; a two-intake robot gets it at both ends.
const INTAKE_REACH := 8.0
## More than MOMENTARY is about 3 s (S10.6). Holding 5 for longer than this is
## an instance of G407; doing it again, or ever holding 6, reads as STRATEGIC.
const CONTROL_GRACE := 3.0
## What counts as DRAGGING rather than bulldozing. The manual calls inadvertent
## contact with a ball in the robot's path "bulldozing" and says it is NOT
## CONTROL; herding one along with you is. So a ball has to travel with the
## robot for this long, while the robot is actually moving, before it counts.
const HERD_TIME := 1.1              # s of travelling together
const HERD_MIN_SPEED := 7.0         # in/s; below this the robot is not taking it anywhere

## Rapid fire: the whole hopper empties in about half a second.
const FIRE_INTERVAL := 0.13

## Driver-station eye height above the tiles. A 5 ft 9 in driver's eyes sit
## about 4.5 in below the top of their head, so the view is from 64.5 in — you
## look slightly DOWN onto the field, which is what standing at the wall is
## actually like.
const DRIVER_EYE := 64.5

# ------------------------------------------------- what makes it feel real
## An FTC robot is not a game object. Three things account for most of the
## difference, and all three are modelled:
##
##  BATTERY  a 12 V pack reads about 13 V fresh, sags under load, and is
##           noticeably down by endgame. Drive power scales with it, so the
##           robot you finish a match with is slower than the one you started.
##  LATENCY  gamepad -> Driver Station -> Control Hub -> motor is not free.
##           About 70 ms, which is exactly the lag drivers complain about.
##  RAMP     motors do not reach commanded output instantly.
const BATTERY_NOMINAL := 13.0
const BATTERY_FLOOR := 10.8
const BATTERY_SAG_PER_N := 0.004     # volts lost per newton of commanded wheel force
const BATTERY_DRAIN_PER_S := 0.0075  # slow decline across a match
const BATTERY_SHOT_COST := 0.035     # each launch spins the flywheel back up
## How much of the drivetrain a volt of DISCHARGE costs you.
##
## Two different things happen to a battery and only one of them should slow
## the robot down. Sag under load makes the terminal voltage dip the instant you
## floor it and recover when you let off - that is what the HUD bar shows, and
## it must NOT cut your top speed, or the robot never reaches spec even on a
## fresh pack. Discharge is the pack actually emptying over the match, and that
## is what genuinely costs you speed.
##
## So power is a function of OPEN-CIRCUIT voltage, not terminal voltage: you
## start a match at exactly 68 in/s and 460 deg/s, and finish it around 10%
## down - enough to feel in the last thirty seconds, not enough to fight.
const BATTERY_POWER_LOSS_PER_V := 0.085
const BATTERY_POWER_MIN := 0.85      # never worse than this, however long you drive
const CONTROL_LATENCY := 0.070       # s
const MOTOR_RAMP := 6.0              # command units per second

# ============================================================ HEADING HOLD ==
#
# A real FTC robot does not steer on wheel traction alone. It has an IMU and a
# heading controller, and the drivers who are any good run one: hold the stick
# and it turns at a rate, let go and it STOPS on a heading instead of coasting
# past it. Without that the chassis carries its angular momentum, overshoots by
# ten or fifteen degrees and then wanders, which is the "sway" that makes aiming
# feel like wrestling.
#
# So the yaw axis is closed-loop. YAW_P pulls the yaw RATE toward whatever the
# stick is asking for; YAW_HOLD_P adds a position term on the heading itself
# once the stick is centred, so the robot parks on a bearing and stays there.
# The correction is capped at YAW_AUTHORITY so it can never exceed what four
# wheels could actually have produced.
const YAW_P := 9.0                   # rate loop, 1/s
const YAW_HOLD_P := 6.0              # heading loop, only while the stick is centred
## Heading errors under this are commanded as zero rotation.
##
## There is no derivative term here, deliberately. Damping the loop with the
## measured yaw rate looks right on paper and is wrong in practice: a chassis
## riding on four raycast suspensions produces a noisy rate signal at 180 Hz,
## and a D term multiplies that noise straight back into the command. A
## deadband kills the same ring by not chasing errors too small to see.
const YAW_HOLD_DEAD := deg_to_rad(0.35)
## Cap on the heading controller, as angular acceleration (rad/s^2). Four
## wheels at WHEEL_FORCE_MAX on a 0.23 m arm make about 24 N*m, which on a
## 13.6 kg robot's yaw inertia is about 50 rad/s^2. That is the honest ceiling
## and it is what this is set to.
##
## It also sets a floor on how tight turning can possibly be. Shedding the full
## 460 deg/s takes 0.16 s and carries the robot about 37 degrees past the point
## you let go, and no amount of control can beat that — it is the drivetrain's
## own braking limit. Easing off instead of dropping the stick is the technique,
## and from a gentle turn the robot stops within a couple of degrees.
const YAW_AUTHORITY := 50.0
## Rate errors smaller than this are left alone. Without it the rate loop and
## the wheel traction model fight each other every tick and the chassis sits in
## a steady +/- 9 deg/s limit cycle: the heading is stable, but the robot
## visibly buzzes, which is the opposite of feeling planted.
const YAW_SETTLED := deg_to_rad(4.0)

# =========================================================== DRIVETRAIN TRIM =
#
# Turning a team's stopwatch numbers into sim parameters needs two corrections,
# both measured with tools/debug_calibrate.tscn rather than guessed.
#
# ACCEL_TRIM: a mecanum wheel pushes along its ROLLER axis, at 45 degrees to
# the chassis, so only about 0.7 of each wheel's force ends up going where you
# asked — and the commanded contact velocity is projected the same way. A naive
# F = m*a therefore under-delivers by more than half: 6.3 N per wheel produced
# 0.73 m/s^2 where the arithmetic promised 1.74.
#
# BRAKE_TRIM: braking does NOT need the same correction, because the wheels are
# not doing all of it. Rolling resistance, body damping and the heading hold all
# help pull the robot down, so asking the wheels for the full figure stops it in
# well under the distance the team measured.
#
# There is deliberately no trim on the SPEED caps. An earlier pass added one,
# because the robot was settling 7% under its commanded speed — but that was
# the acceleration being too weak to ever reach the cap, not drag stealing the
# top end. With the force right, the caps are hit exactly and a trim would just
# push the robot past the number its team measured.
const ACCEL_TRIM := 2.05
const BRAKE_TRIM := 0.17
const YAW_DEADBAND := 0.02           # stick units below which "centred" starts

# ============================================================ HUMAN PLAYER ==
#
# S9.4 / G426 / G427. There is a person at the LOADING ZONE, and a person is
# not a spawner. They have to see the element, pick it up, walk it to the zone
# and feed it in one at a time — so an element owed to the field arrives a
# second or two later, in the zone, at rest on the tiles, not in mid-air.
const HUMAN_REACT_MIN := 0.9         # s before they even reach for it
const HUMAN_REACT_MAX := 2.4
const HUMAN_PLACE_GAP := 0.6         # G427: one at a time through the ZONE
## An element that leaves the FIELD has to be walked back around the guardrail.
const HUMAN_RETURN_MIN := 2.2
const HUMAN_RETURN_MAX := 4.5


## How long a manual turret nudge holds auto-aim off before it takes over again.
## Long enough to line up a shot by hand, short enough that an accidental brush
## of the D-pad does not silently disable aiming for the rest of the match.
const MANUAL_AIM_HOLD := 2.5
const LAUNCH_SPEED_DEFAULT := 175.0   # in/s
const LAUNCH_SPEED_MAX := 260.0       # in/s  (a flywheel ceiling, not an infinity)

# ------------------------------------------------------------ collision layers
## 1 world + elements + robot (everything that should collide normally)
## 2 robot-only guard shells: smooth hulls around fiddly structures so a bumper
##   cannot wedge into them. Elements never mask this layer, so they pass right
##   through and still stack inside a FLOWER as they should.
## 3 scoring elements. They get their OWN layer so the drivetrain's suspension
##   raycasts can ignore them: with elements on the world layer, a wheel ray hit
##   a POLLEN the robot was driving over, read it as a huge spring compression
##   and launched the robot into the air. Wheels ride on the floor; the chassis
##   still shoves balls normally.
const LAYER_WORLD := 1
const LAYER_GUARD := 2
const LAYER_ELEMENT := 3

# ---------------------------------------------------------------- colours
const C_RED := Color(0.84, 0.16, 0.20)
const C_BLUE := Color(0.13, 0.36, 0.83)
const C_POLLEN := Color(0.97, 0.78, 0.09)
const C_TILE_A := Color(0.31, 0.32, 0.34)
const C_TILE_B := Color(0.26, 0.27, 0.29)
const C_FRAME := Color(0.18, 0.19, 0.21)
const C_WALL := Color(0.72, 0.73, 0.75)
## The perimeter is a black extruded rail top and bottom with a clear
## polycarbonate panel between them, which is what you actually look through at
## an event. Heights are of the 12 in wall.
const C_RAIL := Color(0.055, 0.058, 0.065)
const WALL_RAIL_BOTTOM := 1.75    # in
const WALL_RAIL_TOP := 1.50       # in

# ================================================================= helpers ===

## Manual coordinate (inches) -> Godot position (metres).
func fp(x: float, y: float, z: float = 0.0) -> Vector3:
	return Vector3(x * IN, z * IN, -y * IN)

## The inverse of fp(): a Godot position back into manual inches, as
## (x, y forward, height). The editor works in these numbers throughout.
func to_field(p: Vector3) -> Vector3:
	return Vector3(p.x / IN, -p.z / IN, p.y / IN)

## Ground-plane direction from a manual-frame 2D vector.
func fd(v: Vector2) -> Vector3:
	return Vector3(v.x, 0.0, -v.y)

func m(inches_value: float) -> float:
	return inches_value * IN

func rect_has(rect: Array, x: float, y: float) -> bool:
	return x >= rect[0] and x <= rect[2] and y >= rect[1] and y <= rect[3]

## "at least partially in" — circle of radius r (in) overlapping a manual rect.
func rect_touches(rect: Array, x: float, y: float, r: float) -> bool:
	var cx := clampf(x, rect[0], rect[2])
	var cy := clampf(y, rect[1], rect[3])
	return Vector2(x - cx, y - cy).length() <= r

func loading_zone(a: int) -> Array:
	return LOADING_RED if a == Alliance.RED else LOADING_BLUE

func garden(a: int) -> Array:
	return GARDEN_RED if a == Alliance.RED else GARDEN_BLUE

## Alliance colours. The colourblind pair is Okabe-Ito vermillion and blue,
## which stays distinguishable under the common red/green deficiencies where
## the stock FTC red and blue can collapse toward each other.
func alliance_colour(a: int) -> Color:
	if colorblind:
		return Color(0.84, 0.37, 0.00) if a == Alliance.RED else Color(0.00, 0.45, 0.70)
	return C_RED if a == Alliance.RED else C_BLUE

func alliance_name(a: int) -> String:
	return "RED" if a == Alliance.RED else "BLUE"

func clock_text(t: float) -> String:
	var s := int(ceil(maxf(t, 0.0)))
	return "%d:%02d" % [s / 60, s % 60]

## A flat unlit-ish material, used for every generated surface.
## Clear polycarbonate. Transparent enough to follow a ball through, with
## enough of a sheen left that the panel still reads as a surface rather than a
## hole in the field — which is what it looks like from the driver station.
##
## Culling is disabled because a single-thickness panel seen from the far side
## would otherwise vanish. The CALLER turns shadow casting off on the mesh:
## real polycarb casts nothing you would notice, and a translucent caster lays
## a dark band across the tiles that reads as a wall lying on the floor.
func glass(tint := Color(0.62, 0.70, 0.76), alpha := 0.16) -> StandardMaterial3D:
	var sm := StandardMaterial3D.new()
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.albedo_color = Color(tint.r, tint.g, tint.b, alpha)
	sm.roughness = 0.08
	sm.metallic = 0.0
	sm.metallic_specular = 0.72
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return sm

func mat(c: Color, rough := 0.85, metal := 0.0, emit := 0.0) -> StandardMaterial3D:
	var sm := StandardMaterial3D.new()
	sm.albedo_color = c
	sm.roughness = rough
	sm.metallic = metal
	if emit > 0.0:
		sm.emission_enabled = true
		sm.emission = c
		sm.emission_energy_multiplier = emit
	return sm

# ================================================================== input ====
## Built in code so project.godot stays readable and merge-friendly.
##
## Every action binds a KEY and a GAMEPAD control, so the sim plays identically
## on a controller — which is how a driver actually drives. Layout is Xbox; a
## DualShock/DualSense maps to the same indices through Godot.
##
##   left stick      drive / strafe        right stick X   rotate
##   D-pad L/R       turret (manual)       D-pad U/D       hood (manual)
##   RT or A         fire                  LT or B         eject one
##   LB / RB         launcher power        X               field-centric
##   Y               camera                R3              auto-aim on/off
##   L3              intake off (hold)     START           start match
##   BACK            reset field
##
## Intake runs CONSTANTLY; L3 / X-key is a hold-to-stop, not a hold-to-run.

const ACTIONS := {
	"drive_fwd":     {"keys": [KEY_W], "axis": [JOY_AXIS_LEFT_Y, -1.0]},
	"drive_back":    {"keys": [KEY_S], "axis": [JOY_AXIS_LEFT_Y, 1.0]},
	"strafe_left":   {"keys": [KEY_A], "axis": [JOY_AXIS_LEFT_X, -1.0]},
	"strafe_right":  {"keys": [KEY_D], "axis": [JOY_AXIS_LEFT_X, 1.0]},
	"turn_left":     {"keys": [KEY_Q], "axis": [JOY_AXIS_RIGHT_X, -1.0]},
	"turn_right":    {"keys": [KEY_E], "axis": [JOY_AXIS_RIGHT_X, 1.0]},
	"turret_left":   {"keys": [KEY_LEFT], "buttons": [JOY_BUTTON_DPAD_LEFT]},
	"turret_right":  {"keys": [KEY_RIGHT], "buttons": [JOY_BUTTON_DPAD_RIGHT]},
	"hood_up":       {"keys": [KEY_UP], "buttons": [JOY_BUTTON_DPAD_UP]},
	"hood_down":     {"keys": [KEY_DOWN], "buttons": [JOY_BUTTON_DPAD_DOWN]},
	"power_up":      {"keys": [KEY_BRACKETRIGHT], "buttons": [JOY_BUTTON_RIGHT_SHOULDER]},
	"power_down":    {"keys": [KEY_BRACKETLEFT], "buttons": [JOY_BUTTON_LEFT_SHOULDER]},
	"fire":          {"keys": [KEY_SPACE], "buttons": [JOY_BUTTON_A], "axis": [JOY_AXIS_TRIGGER_RIGHT, 1.0]},
	"outtake":       {"keys": [KEY_Z], "buttons": [JOY_BUTTON_B], "axis": [JOY_AXIS_TRIGGER_LEFT, 1.0]},
	"intake_off":    {"keys": [KEY_X], "buttons": [JOY_BUTTON_LEFT_STICK]},
	"aim_assist":    {"keys": [KEY_C], "buttons": [JOY_BUTTON_RIGHT_STICK]},
	# no stock pad button: every face and d-pad button is already spoken for.
	# Both of these are remappable in Settings -> Controls, where they are listed
	# as unbound so a pad driver can see they need a choice rather than a default
	# that silently steals another action.
	"recalibrate":   {"keys": [KEY_R]},
	"cam_toggle":    {"keys": [KEY_TAB], "buttons": [JOY_BUTTON_Y]},
	"field_centric": {"keys": [KEY_F], "buttons": [JOY_BUTTON_X]},
	"start_match":   {"keys": [KEY_ENTER], "buttons": [JOY_BUTTON_START]},
	"reset":         {"keys": [KEY_BACKSPACE], "buttons": [JOY_BUTTON_BACK]},
	"skip_auto":     {"keys": [KEY_K]},
	"record_auto":   {"keys": [KEY_P]},
	"slow":          {"keys": [KEY_CTRL]},
	"pause":         {"keys": [KEY_ESCAPE], "buttons": [JOY_BUTTON_START]},
	"save_situation": {"keys": [KEY_F5]},
	"retry_scenario": {"keys": [KEY_F6]},
}

## Keyboard rebinds from the settings screen: action -> physical keycode.
## Overrides the `keys` half of ACTIONS only. Controller bindings stay fixed,
## because a gamepad layout is a convention and remapping it mostly produces
## controllers nobody else can pick up and use.
var key_override: Dictionary = {}

## Whether alliance colours are drawn in a red/green-safe pair.
var colorblind := false

## TRUE WHILE THE SCENARIO EDITOR HAS THE FIELD.
##
## Same idea as `restoring`, for the whole time the editor is open: the world
## is posed by hand, so nothing may react to where things are put.
var editing := false

## The one test every reactive system asks: is the world being arranged rather
## than played?
func frozen() -> bool:
	return restoring or editing or viewing or puppet

## TRUE WHILE THIS COMPUTER IS SHOWING AN ONLINE ROOM.
##
## The room's server runs the only simulation. This copy of the world is a
## puppet: every body is frozen and posed from the server's snapshots, and the
## tree is halted exactly as it is for the replay viewer, so nothing here can
## pick up, score, foul, tip or decide anything. Menus, the camera and the
## network client keep running.
var puppet := false

func set_puppet(on: bool) -> void:
	puppet = on
	refresh_halt()

## TRUE WHILE A REPLAY IS ON SCREEN.
##
## The replay viewer poses the real robots, balls and hives from recorded
## samples. Nothing may react to where it puts them — no pickup, no score, no
## foul, no sound — and nothing may advance, so viewing both freezes (every
## reactive system checks `frozen()`) and halts the tree (physics, robots, AI,
## attempts and the recorder all stop). The viewer's own UI and the camera rig
## are PROCESS_MODE_ALWAYS and keep running.
var viewing := false

func set_viewing(on: bool) -> void:
	viewing = on
	refresh_halt()

# ============================================================ SIMULATION TIME =
#
# THE ONLY CLOCK GAMEPLAY IS ALLOWED TO MEASURE ITSELF AGAINST.
#
# `Time.get_ticks_msec()` is the wall clock. It keeps running behind a pause
# menu, so anything measured against it — a shot's attribution window, a manual
# aim hold, a control-latency queue — quietly expires while the player is
# reading the menu, and the run they come back to is not the run they left.
# The independent review found exactly this.
#
# `sim_time` advances only while the world is actually being simulated: not
# while halted, not while a snapshot is being restored, not in the editor. It
# is driven from _physics_process, so it also cannot vary with the frame rate.

## Seconds of simulation since the game started. Monotonic, never reset.
var sim_time := 0.0

## TRUE WHILE THE WHOLE SIMULATION IS STOPPED for a menu.
##
## Distinct from `frozen()`: frozen means the world is being ARRANGED (restore,
## editor) and scripts must not react to it. Halted means the world is exactly
## as the player left it and nothing at all may advance.
var halted := false

## A menu is up over a running match and wants the world stopped.
var menu_halt := false

func sim_now() -> float:
	return sim_time

## THE WORLD IS STOPPED WHILE A MENU IS UP — but never while a snapshot is
## being restored, because restoring needs live physics frames to settle bodies
## into their saved poses and does its own gating through `restoring`.
func refresh_halt() -> void:
	_halt((menu_halt or viewing or puppet) and not restoring)

## STOP OR START THE WORLD.
##
## `SceneTree.paused` is used deliberately in preference to a flag that every
## subsystem has to remember to check. The previous pause was a boolean plus a
## check in the places somebody thought of, and the places nobody thought of —
## rigid bodies, MatchStats, the hive swing, the robot's own mechanisms —
## carried on. An independent review found a ball travelling 19.47 in during a
## one-second pause. Pausing the tree cannot miss a subsystem: anything that
## has not explicitly asked to keep running stops. The things that do ask —
## menus, HUD, camera rig, autoloads — say so with PROCESS_MODE_ALWAYS.
func _halt(on: bool) -> void:
	if halted == on:
		return
	halted = on
	var tree := get_tree()
	if tree != null:
		tree.paused = on

## Setters, so that changing either input re-decides the halt in one place.
func set_menu_halt(on: bool) -> void:
	menu_halt = on
	refresh_halt()

func set_restoring(on: bool) -> void:
	restoring = on
	refresh_halt()

func _physics_process(delta: float) -> void:
	if not halted and not frozen():
		sim_time += delta

## SMOOTH MOTION BETWEEN PHYSICS TICKS.
##
## Physics runs at 180 Hz; the screen refreshes at 60, 75, 120, 144… so a frame
## lands between ticks at a different point every time. Drawn from the last
## tick alone, a moving robot steps 2, then 3, then 4 ticks per frame — that is
## judder, and it is worst in a browser, where frames are less even. With
## interpolation every body is DRAWN part-way between its last two ticks, so
## motion is even at any refresh rate. It changes nothing in the simulation
## (the physics transforms are untouched), only what is drawn.
##
## It is switched off whenever something other than physics is moving the
## world — a replay being viewed, an online guest's world posed from the
## host's snapshots, the scenario editor, a situation being restored — and
## every switch resets the interpolation so nothing slides from where it was.
var smooth_motion := true

func _process(_d: float) -> void:
	refresh_interpolation()

func refresh_interpolation() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var want := smooth_motion and not frozen()
	if tree.physics_interpolation != want:
		tree.physics_interpolation = want
		tree.root.reset_physics_interpolation()

## A body was put somewhere new (teleport, field reset, restore): draw it
## there at once instead of gliding from where it was over one tick.
func snap_visuals(n: Node) -> void:
	if n != null and is_instance_valid(n):
		n.reset_physics_interpolation()

## TRUE WHILE A SAVED SITUATION IS BEING PUT BACK ON THE FIELD.
##
## Restoring moves robots, drops balls into hoppers and swings hives, and every
## one of those is something the game normally reacts to: a ball entering a
## CELL scores, a ball crossing the wall is a foul and fetches a human player,
## an intake touching a ball picks it up, and all of it makes noise. None of
## that is real — it is the save file being unpacked — so the handful of places
## that would react check this flag and sit still until the field is ready.
var restoring := false

# ========================================================== NAMING THE PAD ===
#
# "Button 0" is not something anyone can find with a thumb. These are the
# face-button names printed on the controllers people actually own, with the
# Xbox lettering as the default because that is what Godot's own mapping uses.

const PAD_BUTTON_NAMES := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_LEFT_STICK: "L3 (click left stick)",
	JOY_BUTTON_RIGHT_STICK: "R3 (click right stick)",
	JOY_BUTTON_BACK: "Back", JOY_BUTTON_START: "Start", JOY_BUTTON_GUIDE: "Guide",
	JOY_BUTTON_DPAD_UP: "D-pad up", JOY_BUTTON_DPAD_DOWN: "D-pad down",
	JOY_BUTTON_DPAD_LEFT: "D-pad left", JOY_BUTTON_DPAD_RIGHT: "D-pad right",
}

func pad_button_name(b: int) -> String:
	return String(PAD_BUTTON_NAMES.get(b, "Button %d" % b))

func pad_axis_name(axis: int, dir: float) -> String:
	var up := dir < 0.0
	match axis:
		JOY_AXIS_LEFT_X: return "Left stick %s" % ("left" if up else "right")
		JOY_AXIS_LEFT_Y: return "Left stick %s" % ("up" if up else "down")
		JOY_AXIS_RIGHT_X: return "Right stick %s" % ("left" if up else "right")
		JOY_AXIS_RIGHT_Y: return "Right stick %s" % ("up" if up else "down")
		JOY_AXIS_TRIGGER_LEFT: return "Left trigger"
		JOY_AXIS_TRIGGER_RIGHT: return "Right trigger"
	return "Axis %d%s" % [axis, "-" if up else "+"]

## The keys that currently fire `action`, rebinds included. Everything that
## reads the keyboard goes through here rather than touching ACTIONS.
func keys_for(action: String) -> Array:
	if key_override.has(action):
		return [int(key_override[action])]
	var spec: Dictionary = ACTIONS.get(action, {})
	return spec.get("keys", [])

## Rebuild Godot's own InputMap from ACTIONS plus any rebinds. Called at
## startup and again whenever a binding changes, so `is_action_pressed` and
## DriverInput never disagree about what a key does.
func rebuild_input_map() -> void:
	_build_input_map()

func _ready() -> void:
	# the clock has to keep ticking while the tree is paused, or it could never
	# start again; `halt` is what stops it, not the pause
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_input_map()

func _build_input_map() -> void:
	for a: String in ACTIONS:
		var spec: Dictionary = ACTIONS[a]
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.25)
		else:
			InputMap.action_erase_events(a)
		for k: int in keys_for(a):
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(a, ev)
		for b: int in spec.get("buttons", []):
			var jb := InputEventJoypadButton.new()
			jb.button_index = b
			InputMap.action_add_event(a, jb)
		if spec.has("axis"):
			var jm := InputEventJoypadMotion.new()
			jm.axis = spec["axis"][0]
			jm.axis_value = spec["axis"][1]
			InputMap.action_add_event(a, jm)

## True while any gamepad is plugged in — the HUD uses it to show the right
## button prompts instead of guessing.
func has_pad() -> bool:
	return not Input.get_connected_joypads().is_empty()

func pad_name() -> String:
	var pads := Input.get_connected_joypads()
	return Input.get_joy_name(pads[0]) if not pads.is_empty() else ""
