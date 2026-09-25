extends Node
##
## ALL SOUND, SYNTHESISED AT STARTUP.
##
## There is not a single audio file in this project, for the same reason there
## is not a single mesh file: a .wav is an unreviewable binary blob, and the
## field, the robot and the elements are all built from code already. Every
## sound below is generated into an AudioStreamWAV in _ready() — noise shaped by
## a filter, tones built from harmonics, impacts as an exponentially decaying
## burst. Total cost is about 25 ms of startup and ~1.5 MB of RAM.
##
## It also means every sound is PARAMETRIC. The flywheel is not a recording of
## a flywheel, it is an oscillator whose pitch is driven by the launcher's
## actual spin-up, so it rises and falls with the mechanism instead of being
## triggered near it.
##
## Autoloaded as `SFX`.
##

## Everything is generated at this rate. 22.05 kHz is plenty for motor whine and
## impacts and halves the memory against 44.1.
const RATE := 22050
## How many one-shots can overlap before the oldest is recycled. A field of 56
## elements all landing at once would otherwise spawn 56 players.
const VOICES := 18

var _streams: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _voices3d: Array[AudioStreamPlayer3D] = []
var _next_voice := 0
var _next_voice3d := 0
var _loops: Dictionary = {}
var _ambience: AudioStreamPlayer

## Bus layout, created at runtime so there is no .tres to keep in sync.
const BUS_SFX := "SFX"
const BUS_AMB := "AMBIENCE"

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS      # menus and pauses still click
	_make_buses()
	_build()
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX
		add_child(p)
		_voices.append(p)
		var p3 := AudioStreamPlayer3D.new()
		p3.bus = BUS_SFX
		p3.unit_size = 6.0
		p3.max_distance = 40.0
		add_child(p3)
		_voices3d.append(p3)

	_ambience = AudioStreamPlayer.new()
	_ambience.bus = BUS_AMB
	_ambience.stream = _streams["crowd"]
	_ambience.volume_db = -18.0
	add_child(_ambience)
	_ambience.play()

func _make_buses() -> void:
	for b in [BUS_SFX, BUS_AMB]:
		if AudioServer.get_bus_index(b) >= 0:
			continue
		var i := AudioServer.bus_count
		AudioServer.add_bus(i)
		AudioServer.set_bus_name(i, b)
		AudioServer.set_bus_send(i, "Master")

# =============================================================== public API ==

## Fire a one-shot by name. `pitch` multiplies the generated frequency, which is
## how one impact sample covers everything from a pollen tap to a robot hitting
## the wall.
## How many one-shot sounds have been started, for tests that must prove
## something made no noise.
var plays := 0

func play(name: String, volume_db := 0.0, pitch := 1.0) -> void:
	plays += 1
	if not _streams.has(name):
		return
	var p := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	p.stream = _streams[name]
	p.volume_db = volume_db
	p.pitch_scale = clampf(pitch, 0.1, 4.0)
	p.play()

## The same, positioned in the world — used for anything you should be able to
## locate by ear, like a ball landing in a cell on the far side of the field.
func play_at(name: String, where: Vector3, volume_db := 0.0, pitch := 1.0) -> void:
	plays += 1
	if not _streams.has(name):
		return
	var p := _voices3d[_next_voice3d]
	_next_voice3d = (_next_voice3d + 1) % _voices3d.size()
	p.stream = _streams[name]
	p.global_position = where
	p.volume_db = volume_db
	p.pitch_scale = clampf(pitch, 0.1, 4.0)
	p.play()

## A continuous sound owned by `key` — the intake, the flywheel, the drivetrain.
## Call set_loop() every frame with the level and pitch you want; it starts and
## stops itself, so callers never track playing state.
func set_loop(key: String, name: String, volume_db: float, pitch := 1.0) -> void:
	var p: AudioStreamPlayer = _loops.get(key)
	if p == null:
		if not _streams.has(name):
			return
		p = AudioStreamPlayer.new()
		p.bus = BUS_SFX
		p.stream = _streams[name]
		add_child(p)
		_loops[key] = p
	if volume_db <= -38.0:
		if p.playing:
			p.stop()
		return
	p.pitch_scale = clampf(pitch, 0.1, 4.0)
	p.volume_db = volume_db
	if not p.playing:
		p.play()

## Silence every continuous sound — the replay viewer poses robots without
## running them, and a drivetrain hum frozen at its last level is a lie.
func stop_all_loops() -> void:
	for k in _loops:
		var p: AudioStreamPlayer = _loops[k]
		if p and p.playing:
			p.stop()

func stop_loop(key: String) -> void:
	var p: AudioStreamPlayer = _loops.get(key)
	if p and p.playing:
		p.stop()

## 0..1 for each of the three mixer channels the settings screen exposes.
func set_volume(bus: String, linear: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return
	AudioServer.set_bus_mute(i, linear <= 0.001)
	AudioServer.set_bus_volume_db(i, linear_to_db(clampf(linear, 0.0001, 1.0)))

func get_volume(bus: String) -> float:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return 1.0
	if AudioServer.is_bus_mute(i):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(i))

# ================================================================= synthesis =

func _build() -> void:
	# --- crowd. Filtered noise with a slow swell on top, which is what a gym
	# full of people actually sounds like from the driver station: no voices you
	# can pick out, just a broad hiss that breathes.
	_streams["crowd"] = _wav(_crowd(6.0), true)
	# --- mechanisms
	_streams["intake"] = _wav(_motor(1.0, 78.0, 0.55), true)
	_streams["flywheel"] = _wav(_motor(1.0, 220.0, 0.16), true)
	_streams["drive"] = _wav(_motor(1.0, 52.0, 0.42), true)
	# --- events
	_streams["shot"] = _wav(_shot())
	_streams["pollen"] = _wav(_impact(0.11, 900.0, 34.0, 0.55))
	_streams["nectar"] = _wav(_impact(0.13, 620.0, 28.0, 0.60))
	_streams["wall"] = _wav(_impact(0.20, 260.0, 16.0, 0.75))
	_streams["intake_grab"] = _wav(_impact(0.08, 1400.0, 46.0, 0.35))
	_streams["tip"] = _wav(_tip())
	_streams["buzzer"] = _wav(_buzzer(1.10, 392.0))
	_streams["start"] = _wav(_buzzer(0.55, 523.0))
	_streams["foul"] = _wav(_buzzer(0.35, 233.0))
	_streams["click"] = _wav(_impact(0.045, 1800.0, 90.0, 0.22))
	_streams["select"] = _wav(_impact(0.07, 950.0, 60.0, 0.25))

## Wrap a float buffer as a 16-bit mono stream, optionally looping.
func _wav(samples: PackedFloat32Array, looping := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		var v := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		bytes.encode_s16(i * 2, v)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	if looping:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w

## Crowd noise: white noise pushed through a one-pole low pass to take the
## fizz off, a second slower pass for body, then a gentle random swell.
func _crowd(dur: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var lp := 0.0
	var lp2 := 0.0
	var swell := 0.0
	var swell_t := 0.0
	for i in n:
		var white := rng.randf_range(-1.0, 1.0)
		lp += (white - lp) * 0.055
		lp2 += (lp - lp2) * 0.20
		# the swell wanders rather than pulsing on a timer, so the loop never
		# develops an audible rhythm
		swell_t += 1.0 / float(RATE)
		swell = sin(swell_t * 0.7) * 0.18 + sin(swell_t * 0.23 + 1.1) * 0.12
		out[i] = (lp2 * 2.6) * (0.72 + swell)
	return _seam(out, 0.35)

## A brushed DC motor: a handful of harmonics over a whine, plus commutator
## hash. `rough` mixes in the hash, which is what separates an intake roller
## from a flywheel.
func _motor(dur: float, base: float, rough: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var hash_lp := 0.0
	# whole numbers of cycles in the buffer, or the loop point clicks
	var cycles := maxf(1.0, round(base * dur))
	var f := cycles / dur
	for i in n:
		var t := float(i) / float(RATE)
		var ph := TAU * f * t
		var v := sin(ph) * 0.55
		v += sin(ph * 2.0) * 0.22
		v += sin(ph * 3.0) * 0.12
		v += sin(ph * 5.0) * 0.06
		hash_lp += (rng.randf_range(-1.0, 1.0) - hash_lp) * 0.35
		v += hash_lp * rough
		out[i] = v * 0.45
	return out

## Launch: a pressure thump with a rising whoosh over it.
func _shot() -> PackedFloat32Array:
	var dur := 0.26
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var lp := 0.0
	for i in n:
		var t := float(i) / float(RATE)
		var env: float = exp(-t * 16.0)
		var thump: float = sin(TAU * (150.0 - t * 240.0) * t) * env
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.45
		var air: float = lp * exp(-t * 9.0) * 0.5
		out[i] = clampf(thump * 0.7 + air, -1.0, 1.0)
	return out

## One knock: a decaying tone plus a noise transient. Everything from a pollen
## tap to a robot into the wall is this, at a different pitch and decay.
func _impact(dur: float, freq: float, decay: float, noise_mix: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(freq)
	var lp := 0.0
	for i in n:
		var t := float(i) / float(RATE)
		var env: float = exp(-t * decay)
		var tone: float = sin(TAU * freq * t) * 0.6 + sin(TAU * freq * 1.94 * t) * 0.25
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.6
		out[i] = (tone * (1.0 - noise_mix) + lp * noise_mix) * env
	return out

## The HIVE going over: a groan while it swings, then the stop.
func _tip() -> PackedFloat32Array:
	var dur := 0.7
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 55
	var lp := 0.0
	for i in n:
		var t := float(i) / float(RATE)
		var v := 0.0
		# metallic clank at the start
		var env: float = exp(-t * 11.0)
		v += (sin(TAU * 170.0 * t) * 0.5 + sin(TAU * 291.0 * t) * 0.3
			+ sin(TAU * 437.0 * t) * 0.18) * env
		# balls tumbling out after it
		if t > 0.06:
			lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.5
			v += lp * exp(-(t - 0.06) * 6.0) * 0.30
		out[i] = clampf(v, -1.0, 1.0)
	return out

## Match horn. Two slightly detuned squares, which is close enough to the real
## thing to make people look up.
func _buzzer(dur: float, freq: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / float(RATE)
		var a: float = signf(sin(TAU * freq * t))
		var b: float = signf(sin(TAU * freq * 1.006 * t))
		# short fades so it does not click on either end
		var env: float = minf(1.0, t * 60.0) * minf(1.0, (dur - t) * 22.0)
		out[i] = (a * 0.5 + b * 0.5) * env * 0.42
	return out

## Crossfade the tail of a buffer over its head so a looping sample has no seam.
func _seam(buf: PackedFloat32Array, fade_s: float) -> PackedFloat32Array:
	var f := int(fade_s * RATE)
	if f <= 0 or f * 2 >= buf.size():
		return buf
	var n := buf.size() - f
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = buf[i]
	for i in f:
		var k := float(i) / float(f)
		out[i] = buf[i] * k + buf[n + i] * (1.0 - k)
	return out
