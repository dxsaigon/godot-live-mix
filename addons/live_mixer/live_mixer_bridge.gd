extends Node
## Game side of the Live Mixer. Autoloaded as LiveMixerBridge when the
## plugin is enabled.
##
## Sends bus levels and bus state to the editor's Live Mixer dock, and
## applies the changes made there to this running game's AudioServer.
##
## LOUDNESS: adds an AudioEffectCapture as the last effect on Master (after
## any limiter) and streams what it hears to the dock, which measures LUFS.
## The capture is never saved anywhere and is left out of the state sent to
## the dock, so it can't be committed. Note a capture on Master hears the
## signal BEFORE Master's own fader; the dock adds the fader back on.
##
## REFERENCE NOISE: plays one of the pink_noise_-20lufs_*.wav files (10 s of
## stereo pink noise with separate noise in each channel, made to loop
## seamlessly, normalised to exactly -20 LUFS
## integrated) into Master, turned up or down so it measures exactly the
## dock's target loudness. There's one file per common mix rate, and the one
## matching the game's is used, because resampling dulls the top end enough
## to read about 0.3 LU low. "Solo" mode silences the
## game while it plays (by muting every bus that feeds Master) so the two
## can be compared by ear. The dock always sees those buses' real settings,
## and they're restored when solo ends.
##
## WITH GAME: the noise plays alongside the game, and a hidden
## AudioEffectAmplify at the very start of Master turns both down by
## WITH_GAME_DUCK_DB, so a game mixed on target plus the noise still totals
## the target (two unrelated signals at equal loudness sum to +3 dB). Like
## the capture, it's left out of the state sent to the dock.
##
## HOLD TO SOLO: holding HOLD_SOLO_KEY in the game window switches the noise
## to Solo, and letting go puts it back how it was. The dock's dropdown
## follows. Polled rather than read from input events, so it works whatever
## the game does with its input.
##
## PAUSED: the dock's Active switch sends "set_active". While paused,
## nothing is sent, the capture and the With-game duck come off Master, any
## noise stops, and _process() is switched off, so the per-frame cost is
## zero. Messages from the dock are still handled.
##
## Only active when the game was launched from the editor (or with
## --remote-debug). In a release export, or an exported debug build run on
## its own, it switches itself off in _ready() and costs nothing.
##
## Buses are addressed by name, not index, so a message can't land on the
## wrong bus if the layout changes while it's in flight.

enum NoiseMode { OFF, WITH_GAME, SOLO }

const CAPTURE: StringName = &"live_mixer"
const PEAK_INTERVAL: float = 1.0 / 30.0
const STATE_INTERVAL: float = 0.25
const CAPTURE_BUFFER_SEC: float = 0.5
## The capture goes empty when Master is silent long enough for the
## AudioServer to switch it off. After this long with nothing, the gap is
## reported to the dock as silence so the meter falls.
const SILENCE_AFTER_SEC: float = 0.25
## Loaded on first use (not preloaded) so it costs nothing until then.
## "%d" is the mix rate.
const NOISE_PATH: String = "pink_noise_-20lufs_%d.wav"
const NOISE_RATES: Array[int] = [44100, 48000]
## The noise files' integrated loudness. Change it only if the files change.
const NOISE_FILE_LUFS: float = -20.0
## Hold in the game window to hear the reference noise solo. Pick something
## the game doesn't use, and that the editor doesn't use either: when the
## game runs embedded in the editor, the editor sees the key too (F7, for
## one, opens its debugger panel).
const HOLD_SOLO_KEY: Key = KEY_P
## How far "With game" turns the game and the noise down. -3 makes two
## equally loud signals sum to the target.
const WITH_GAME_DUCK_DB: float = -3.0

var _peak_accum: float = 0.0
var _state_accum: float = 0.0
var _last_state: Array = []
var _force_state: bool = true
var _capture: AudioEffectCapture = null
var _duck: AudioEffectAmplify = null
var _empty_time: float = 0.0
var _noise_mode: NoiseMode = NoiseMode.OFF
var _noise_target_lufs: float = -18.0
var _noise_player: AudioStreamPlayer = null
var _hold_key_down: bool = false
## The mode to go back to when the hold key is released.
var _mode_before_hold: NoiseMode = NoiseMode.OFF
## Buses muted for solo -> the mute they really have (what the dock sees,
## and what's restored).
var _solo_saved: Dictionary = {}
var _active: bool = true


func _ready() -> void:
	if not EngineDebugger.is_active():
		set_process(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	EngineDebugger.register_message_capture(CAPTURE, _on_editor_message)
	AudioServer.bus_layout_changed.connect(_on_layout_changed)
	AudioServer.bus_renamed.connect(_on_bus_renamed)
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = CAPTURE_BUFFER_SEC
	_duck = AudioEffectAmplify.new()
	_duck.volume_db = WITH_GAME_DUCK_DB
	_ensure_capture()


func _exit_tree() -> void:
	if not EngineDebugger.is_active():
		return
	_end_solo()
	_set_duck(false)
	# Take the capture off Master too, in case the autoload is removed while
	# the game keeps running.
	for e: int in AudioServer.get_bus_effect_count(0):
		if AudioServer.get_bus_effect(0, e) == _capture:
			AudioServer.remove_bus_effect(0, e)
			break
	if EngineDebugger.has_capture(CAPTURE):
		EngineDebugger.unregister_message_capture(CAPTURE)


func _process(delta: float) -> void:
	_state_accum += delta
	if _force_state or _state_accum >= STATE_INTERVAL:
		_state_accum = 0.0
		_send_state_if_changed()

	_peak_accum += delta
	if _peak_accum >= PEAK_INTERVAL:
		_peak_accum = 0.0
		_send_peaks()

	_send_audio(delta)
	_poll_hold_key()
	_update_noise()


func _send_peaks() -> void:
	var count: int = AudioServer.bus_count
	var peaks: PackedFloat32Array = PackedFloat32Array()
	peaks.resize(count * 2)
	# A bus that's gone quiet and been switched off reports -200 dB, which
	# the dock shows as inactive.
	for i: int in count:
		peaks[i * 2] = AudioServer.get_bus_peak_volume_left_db(i, 0)
		peaks[i * 2 + 1] = AudioServer.get_bus_peak_volume_right_db(i, 0)
	EngineDebugger.send_message("live_mixer:peaks", [peaks])


## Drains the capture every frame (it only holds CAPTURE_BUFFER_SEC) and
## sends the raw frames to the dock.
func _send_audio(delta: float) -> void:
	var rate: float = AudioServer.get_mix_rate()
	var available: int = _capture.get_frames_available()
	if available > 0:
		_empty_time = 0.0
		var frames: PackedVector2Array = _capture.get_buffer(available)
		EngineDebugger.send_message("live_mixer:audio", [rate, frames])
		return
	_empty_time += delta
	if _empty_time >= SILENCE_AFTER_SEC:
		EngineDebugger.send_message("live_mixer:silence", [rate, int(_empty_time * rate)])
		_empty_time = 0.0


## Puts the capture back as the last effect on Master if a layout change
## removed it.
func _ensure_capture() -> void:
	for e: int in AudioServer.get_bus_effect_count(0):
		if AudioServer.get_bus_effect(0, e) == _capture:
			return
	AudioServer.add_bus_effect(0, _capture, -1)


## Sends every bus's settings, but only when something changed since the
## last send, including changes made by game code (a settings menu, a
## ducking script). That keeps the dock's sliders honest.
func _send_state_if_changed() -> void:
	var state: Array = _build_state()
	if not _force_state and state == _last_state:
		return
	_force_state = false
	_last_state = state
	EngineDebugger.send_message("live_mixer:state", [state])


func _build_state() -> Array:
	var buses: Array = []
	for i: int in AudioServer.bus_count:
		var bus_name: String = AudioServer.get_bus_name(i)
		var effects: Array = []
		for e: int in AudioServer.get_bus_effect_count(i):
			var effect: AudioEffect = AudioServer.get_bus_effect(i, e)
			if _is_hidden_effect(effect):
				continue
			effects.append([_effect_label(effect), AudioServer.is_bus_effect_enabled(i, e)])
		buses.append({
			"name": bus_name,
			"volume_db": AudioServer.get_bus_volume_db(i),
			"mute": bool(_solo_saved[bus_name]) if _solo_saved.has(bus_name) else AudioServer.is_bus_mute(i),
			"solo": AudioServer.is_bus_solo(i),
			"bypass": AudioServer.is_bus_bypassing_effects(i),
			"send": String(AudioServer.get_bus_send(i)),
			"effects": effects,
		})
	return buses


func _is_hidden_effect(effect: AudioEffect) -> bool:
	return effect == _capture or effect == _duck


## The dock numbers a bus's effects without the hidden ones; this turns its
## number into the real index. -1 if there's no such effect.
func _real_effect_index(bus: int, dock_index: int) -> int:
	var visible: int = 0
	for e: int in AudioServer.get_bus_effect_count(bus):
		if _is_hidden_effect(AudioServer.get_bus_effect(bus, e)):
			continue
		if visible == dock_index:
			return e
		visible += 1
	return -1


func _effect_label(effect: AudioEffect) -> String:
	if effect == null:
		return "?"
	if effect.resource_name != "":
		return effect.resource_name
	return effect.get_class().trim_prefix("AudioEffect")


func _on_layout_changed() -> void:
	_force_state = true
	if not _active:
		return
	_ensure_capture()
	if _noise_mode == NoiseMode.WITH_GAME:
		_set_duck(true)


func _on_bus_renamed(_index: int, _old_name: StringName, _new_name: StringName) -> void:
	_force_state = true


## Messages from the editor arrive here with the "live_mixer:" prefix
## already stripped.
func _on_editor_message(message: String, data: Array) -> bool:
	match message:
		"request_state":
			_force_state = true
			return true
		"set_noise":
			if _active:
				_set_noise(int(data[0]) as NoiseMode, float(data[1]))
			else:
				_noise_target_lufs = float(data[1])
			return true
		"set_active":
			_set_active(bool(data[0]))
			return true

	if data.is_empty():
		push_error("Live Mixer: '%s' arrived with no bus name." % message)
		return true
	var bus_name: String = str(data[0])
	var bus: int = AudioServer.get_bus_index(bus_name)
	if bus < 0:
		push_warning("Live Mixer: the game has no bus called '%s'. Ignoring '%s'." % [bus_name, message])
		return true

	match message:
		"set_volume":
			AudioServer.set_bus_volume_db(bus, float(data[1]))
		"set_mute":
			if _solo_saved.has(bus_name):
				# Held muted by solo: remember the choice, apply it after.
				_solo_saved[bus_name] = bool(data[1])
			else:
				AudioServer.set_bus_mute(bus, bool(data[1]))
		"set_solo":
			AudioServer.set_bus_solo(bus, bool(data[1]))
		"set_bypass":
			AudioServer.set_bus_bypass_effects(bus, bool(data[1]))
		"set_effect_enabled":
			var effect_index: int = _real_effect_index(bus, int(data[1]))
			if effect_index < 0:
				push_warning("Live Mixer: bus '%s' has no effect %d." % [bus_name, int(data[1])])
				return true
			AudioServer.set_bus_effect_enabled(bus, effect_index, bool(data[2]))
		_:
			push_warning("Live Mixer: unknown message '%s'." % message)
			return false

	# Echo the new state straight away rather than waiting for the next tick.
	_force_state = true
	return true


func _set_active(on: bool) -> void:
	if on == _active:
		return
	_active = on
	if on:
		_ensure_capture()
		# The capture held nothing while it was off; don't report the gap.
		_capture.clear_buffer()
		_empty_time = 0.0
		_force_state = true
		set_process(true)
		return
	_set_noise(NoiseMode.OFF, _noise_target_lufs)
	_hold_key_down = false
	for e: int in AudioServer.get_bus_effect_count(0):
		if AudioServer.get_bus_effect(0, e) == _capture:
			AudioServer.remove_bus_effect(0, e)
			break
	set_process(false)


# --- Reference noise ---------------------------------------------------------


func _set_noise(mode: NoiseMode, target_lufs: float) -> void:
	_noise_target_lufs = target_lufs
	_noise_mode = mode
	if mode == NoiseMode.SOLO:
		_begin_solo()
	else:
		_end_solo()
	_set_duck(mode == NoiseMode.WITH_GAME)
	if mode == NoiseMode.OFF:
		if _noise_player != null:
			_noise_player.stop()
		return
	if _noise_player == null and not _create_noise_player():
		return
	_update_noise()
	if not _noise_player.playing:
		_noise_player.play()


func _poll_hold_key() -> void:
	var down: bool = Input.is_key_pressed(HOLD_SOLO_KEY)
	if down == _hold_key_down:
		return
	_hold_key_down = down
	if down:
		_mode_before_hold = _noise_mode
		_set_noise(NoiseMode.SOLO, _noise_target_lufs)
	else:
		_set_noise(_mode_before_hold, _noise_target_lufs)
	EngineDebugger.send_message("live_mixer:noise_mode", [int(_noise_mode)])


func _update_noise() -> void:
	if _noise_player == null or not _noise_player.playing:
		return
	# The capture is before Master's fader but the noise goes through it, so
	# take the fader back off to land exactly on the target.
	_noise_player.volume_db = _noise_target_lufs - NOISE_FILE_LUFS - AudioServer.get_bus_volume_db(0)


func _create_noise_player() -> bool:
	var rate: int = int(AudioServer.get_mix_rate())
	var file_rate: int = rate
	if not NOISE_RATES.has(rate):
		file_rate = NOISE_RATES[0] if absi(rate - NOISE_RATES[0]) < absi(rate - NOISE_RATES[1]) else NOISE_RATES[1]
		push_warning("Live Mixer: no reference noise made for a %d Hz mix rate; using the %d Hz file, which will read slightly off target." % [rate, file_rate])
	var script: Script = get_script() as Script
	var path: String = script.resource_path.get_base_dir().path_join(NOISE_PATH % file_rate)
	var stream: AudioStreamWAV = load(path) as AudioStreamWAV
	if stream == null:
		push_error("Live Mixer: couldn't load the reference noise at %s. Is the file still in the plugin folder?" % path)
		return false
	# Loop in code rather than relying on the file's import settings.
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = int(round(stream.get_length() * stream.mix_rate))
	_noise_player = AudioStreamPlayer.new()
	_noise_player.stream = stream
	_noise_player.bus = &"Master"
	_noise_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_noise_player)
	return true


## Adds or removes the hidden -3 dB at the start of Master for "With game".
func _set_duck(on: bool) -> void:
	var index: int = -1
	for e: int in AudioServer.get_bus_effect_count(0):
		if AudioServer.get_bus_effect(0, e) == _duck:
			index = e
	if on and index < 0:
		AudioServer.add_bus_effect(0, _duck, 0)
	elif not on and index >= 0:
		AudioServer.remove_bus_effect(0, index)


func _begin_solo() -> void:
	for i: int in range(1, AudioServer.bus_count):
		if AudioServer.get_bus_send(i) != &"Master":
			continue
		var bus_name: String = AudioServer.get_bus_name(i)
		if _solo_saved.has(bus_name):
			continue
		_solo_saved[bus_name] = AudioServer.is_bus_mute(i)
		AudioServer.set_bus_mute(i, true)


func _end_solo() -> void:
	for bus_name: String in _solo_saved:
		var bus: int = AudioServer.get_bus_index(bus_name)
		if bus >= 0:
			AudioServer.set_bus_mute(bus, bool(_solo_saved[bus_name]))
	_solo_saved.clear()
	_force_state = true
