@tool
extends Control
## A vertical bus fader that uses the meter beside it as its scale: the track
## runs exactly along the meter's bars, with the same dB-to-height mapping, so
## the handle at 0 dB sits level with the meter's 0 tick.
##
## Drag the handle to move it (it doesn't jump to the mouse), click the track
## to jump there, scroll for ±0.5 dB (Shift: ±0.1), double-click for 0 dB.
##
## Values below MIN_DB (the dB box can go to -80) park the handle at the
## bottom of the track.

signal value_changed(value: float)
signal drag_started
signal drag_ended

const MIN_DB: float = -60.0
const MAX_DB: float = 6.0
const STEP: float = 0.1
const WHEEL_STEP: float = 0.5
const WHEEL_STEP_FINE: float = 0.1
## At 100% display scale; multiplied by the editor's scale.
const WIDTH: float = 18.0
const TRACK_WIDTH: float = 4.0
const HANDLE_HEIGHT: float = 9.0

const COLOR_TRACK: Color = Color(0.0, 0.0, 0.0, 0.45)
const COLOR_FILL: Color = Color(1.0, 1.0, 1.0, 0.18)
const COLOR_UNITY: Color = Color(1.0, 1.0, 1.0, 0.35)
const COLOR_HANDLE: Color = Color(0.78, 0.8, 0.84)
const COLOR_HANDLE_HOVER: Color = Color(0.92, 0.93, 0.96)
const COLOR_HANDLE_LINE: Color = Color(0.1, 0.1, 0.12)

## The meter whose bars set the track's top and height. Without one the
## track uses the whole height.
var meter: Control = null:
	set(new_meter):
		meter = new_meter
		if meter != null and meter.has_signal(&"span_changed"):
			meter.connect(&"span_changed", queue_redraw)
		queue_redraw()

var value: float = 0.0

var _scale: float = 1.0
var _dragging: bool = false
## Where on the handle the mouse grabbed it, so the handle doesn't jump.
var _grab_offset: float = 0.0
var _hover: bool = false
var _style: StyleBoxFlat = null


func _init() -> void:
	_scale = EditorInterface.get_editor_scale()
	custom_minimum_size = Vector2(WIDTH * _scale, 60.0 * _scale)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	tooltip_text = "Bus volume. Changes the running game immediately.\nDrag, scroll (Shift: fine), double-click for 0 dB."
	resized.connect(queue_redraw)
	_style = StyleBoxFlat.new()
	_style.set_corner_radius_all(int(round(2.0 * _scale)))


func set_value_no_signal(new_value: float) -> void:
	value = new_value
	queue_redraw()


func is_dragging() -> bool:
	return _dragging


## Track top and height in this control's coordinates, taken from the meter.
func _span() -> Vector2:
	if meter == null or not meter.has_method(&"get_bar_span"):
		return Vector2(0.0, size.y)
	var meter_span: Vector2 = meter.call(&"get_bar_span")
	# The two sit side by side in a row, but measure the offset anyway in case
	# a container ever nudges one of them.
	var offset: float = meter.get_global_rect().position.y - get_global_rect().position.y
	return Vector2(meter_span.x + offset, meter_span.y)


func _db_to_y(db: float) -> float:
	var span: Vector2 = _span()
	var ratio: float = clampf((db - MIN_DB) / (MAX_DB - MIN_DB), 0.0, 1.0)
	return span.x + span.y * (1.0 - ratio)


func _y_to_db(y: float) -> float:
	var span: Vector2 = _span()
	if span.y <= 0.0:
		return value
	var ratio: float = clampf(1.0 - (y - span.x) / span.y, 0.0, 1.0)
	return snappedf(MIN_DB + ratio * (MAX_DB - MIN_DB), STEP)


func _handle_rect() -> Rect2:
	var height: float = roundf(HANDLE_HEIGHT * _scale)
	var y: float = roundf(_db_to_y(value) - height * 0.5)
	return Rect2(0.0, y, size.x, height)


func _set_value(new_value: float) -> void:
	new_value = snappedf(new_value, STEP)
	if is_equal_approx(new_value, value):
		return
	value = new_value
	queue_redraw()
	value_changed.emit(value)


func _gui_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null:
		_on_button(button)
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		var over: bool = _handle_rect().has_point(motion.position)
		if over != _hover:
			_hover = over
			queue_redraw()
		if _dragging:
			_set_value(_y_to_db(motion.position.y - _grab_offset))
			accept_event()


func _on_button(button: InputEventMouseButton) -> void:
	match button.button_index:
		MOUSE_BUTTON_LEFT:
			if button.pressed and button.double_click:
				_end_drag()
				_set_value(0.0)
			elif button.pressed:
				var handle: Rect2 = _handle_rect()
				if handle.has_point(button.position):
					_grab_offset = button.position.y - handle.get_center().y
				else:
					_grab_offset = 0.0
					_set_value(_y_to_db(button.position.y))
				_dragging = true
				drag_started.emit()
			else:
				_end_drag()
			accept_event()
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if button.pressed:
				var step: float = WHEEL_STEP_FINE if button.shift_pressed else WHEEL_STEP
				var direction: float = 1.0 if button.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
				_set_value(clampf(maxf(value, MIN_DB) + step * direction, MIN_DB, MAX_DB))
			accept_event()


func _end_drag() -> void:
	if _dragging:
		_dragging = false
		drag_ended.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT_SELF and not _dragging:
		_hover = false
		queue_redraw()


func _draw() -> void:
	var span: Vector2 = _span()
	var track_width: float = roundf(TRACK_WIDTH * _scale)
	var track_x: float = roundf((size.x - track_width) * 0.5)
	draw_rect(Rect2(track_x, span.x, track_width, span.y), COLOR_TRACK)
	# Lighter fill below the handle, like a level.
	var handle_y: float = _db_to_y(value)
	draw_rect(Rect2(track_x, handle_y, track_width, span.x + span.y - handle_y), COLOR_FILL)
	# A notch at unity gain, matching the meter's 0 tick.
	var unity_y: float = roundf(_db_to_y(0.0))
	draw_rect(Rect2(track_x - 2.0 * _scale, unity_y, track_width + 4.0 * _scale, maxf(1.0, roundf(_scale))), COLOR_UNITY)

	var handle: Rect2 = _handle_rect()
	draw_style_box(_handle_style(), handle)
	# Centre line marks the exact value.
	var line_y: float = roundf(handle_y)
	draw_rect(Rect2(handle.position.x + 2.0 * _scale, line_y, handle.size.x - 4.0 * _scale, maxf(1.0, roundf(_scale))), COLOR_HANDLE_LINE)


func _handle_style() -> StyleBoxFlat:
	_style.bg_color = COLOR_HANDLE_HOVER if (_hover or _dragging) else COLOR_HANDLE
	return _style
