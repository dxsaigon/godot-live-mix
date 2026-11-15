@tool
extends EditorDebuggerPlugin
## Editor end of the Live Mixer's debugger channel. Receives the running
## game's bus levels and state, and sends changes from the dock back.
##
## If several game instances are running (Debug > Run Multiple Instances),
## the mixer follows the first one that reports in, and moves to another
## when that one stops.

signal state_received(buses: Array)
signal peaks_received(peaks: PackedFloat32Array)
signal running_changed(running: bool)
signal audio_received(rate: float, frames: PackedVector2Array)
signal silence_received(rate: float, frame_count: int)
## The game changed the noise mode itself (its hold-to-solo key).
signal noise_mode_received(mode: int)

const PREFIX: String = "live_mixer"

var _session_id: int = -1


func _has_capture(capture: String) -> bool:
	return capture == PREFIX


func _setup_session(session_id: int) -> void:
	var session: EditorDebuggerSession = get_session(session_id)
	session.stopped.connect(_on_session_stopped.bind(session_id))


func _capture(message: String, data: Array, session_id: int) -> bool:
	if not _is_followed(session_id):
		return true
	match message:
		"live_mixer:peaks":
			peaks_received.emit(data[0] as PackedFloat32Array)
			return true
		"live_mixer:state":
			state_received.emit(data[0] as Array)
			return true
		"live_mixer:audio":
			audio_received.emit(float(data[0]), data[1] as PackedVector2Array)
			return true
		"live_mixer:silence":
			silence_received.emit(float(data[0]), int(data[1]))
			return true
		"live_mixer:noise_mode":
			noise_mode_received.emit(int(data[0]))
			return true
	return false


func is_running() -> bool:
	return _session_id >= 0


## Sends "live_mixer:<message>" to the followed game. Does nothing if no
## game is running.
func send(message: String, data: Array) -> void:
	if _session_id < 0:
		return
	var session: EditorDebuggerSession = get_session(_session_id)
	if session == null or not session.is_active():
		return
	session.send_message(PREFIX + ":" + message, data)


func _is_followed(session_id: int) -> bool:
	if _session_id == session_id:
		return true
	if _session_id >= 0:
		var current: EditorDebuggerSession = get_session(_session_id)
		if current != null and current.is_active():
			return false
	_session_id = session_id
	running_changed.emit(true)
	return true


func _on_session_stopped(session_id: int) -> void:
	if session_id != _session_id:
		return
	_session_id = -1
	running_changed.emit(false)
