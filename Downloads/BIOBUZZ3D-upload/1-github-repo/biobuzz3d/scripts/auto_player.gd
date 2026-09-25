class_name AutoPlayer
extends Node
##
## Records and replays an AutoRoutine against one robot.
##
## Recording runs off the robot's own `_drive` vector, AFTER the input has been
## read, so what is captured is exactly what the driver asked for — including
## the precision-mode scaling and whichever device they were on. Playback feeds
## it back in through `set_drive()`, the same door the AI opponent uses.
##

signal recording_stopped(routine: AutoRoutine)

var robot: Robot
var routine: AutoRoutine
var recording := false
var playing := false

var _t := 0.0
var _fired_last := false

func begin_record(r: Robot) -> void:
	robot = r
	routine = AutoRoutine.new()
	routine.start_recording()
	recording = true
	playing = false
	_t = 0.0

func stop_record() -> AutoRoutine:
	recording = false
	if routine:
		routine.trim()
	recording_stopped.emit(routine)
	return routine

func begin_play(r: Robot, rt: AutoRoutine) -> void:
	robot = r
	routine = rt
	playing = rt != null and not rt.frames.is_empty()
	recording = false
	_t = 0.0
	if playing:
		robot.auto_drive = true

func stop_play() -> void:
	if playing and robot and is_instance_valid(robot):
		robot.set_drive(0, 0, 0)
		robot.auto_drive = false
	playing = false

func _physics_process(delta: float) -> void:
	# `frozen()` means the world is being ARRANGED; `halted` means it is
	# stopped for a menu. This node is PAUSABLE so it should not be called at
	# all while halted — the check stays because when it was missing, recording
	# quietly inserted thirty frames and playback ate a second of the routine
	# behind the pause menu, and a sample stream is not something to leave to
	# one line of wiring elsewhere.
	if BB.frozen() or BB.halted:
		return
	if robot == null or not is_instance_valid(robot):
		return
	if recording:
		_t += delta
		while _t >= AutoRoutine.TICK:
			_t -= AutoRoutine.TICK
			routine.capture(robot.drive_command(), robot.wants_fire(),
				robot.wants_outtake(), not robot.intake_on, robot.auto_aim)
		return
	if not playing:
		return
	_t += delta
	var cmd := routine.at(_t)
	if cmd.is_empty():
		stop_play()
		return
	var d: Vector3 = cmd["drive"]
	robot.set_drive(d.x, d.y, d.z)
	robot.intake_on = not bool(cmd["intake_off"])
	robot.auto_aim = bool(cmd["aim"])
	# fire on the RISING edge, so a held trigger does not empty the hopper on
	# one frame and then keep trying
	var f := bool(cmd["fire"])
	if f and robot.can_fire():
		robot.fire()
	_fired_last = f
	if bool(cmd["outtake"]):
		robot.eject_one()
