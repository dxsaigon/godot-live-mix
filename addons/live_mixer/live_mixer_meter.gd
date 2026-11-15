@tool
extends Control
## A stereo VU meter: two bars with fast attack, slow release, a peak-hold
## tick that falls after a moment, and a clip light that stays lit until
## clicked.
##
## A dB scale sits to the right of the bars: a tick every 6 dB, and numbers
## placed in order of importance (SCALE_LABEL_PRIORITY), each skipped if it
## would overlap one already drawn. Numbers below 0 are shown without their
## minus sign (a tick then "6" reads cleaner than a tick then "-6"), and the
## column of numbers is right-aligned. A tall meter shows every number, a short
## one only the key ones; the ticks always show.
##
## Above the clip light, the loudest reading since the last reset is shown as
## a number (red above 0 dB). Clicking the meter clears it with the clip light.
##
## Unlit parts of the bars carry a faint copy of their colour zones, so you
## can see where yellow and red start before the signal gets there.
##
## get_bar_span() gives the bars' top and height, so the fader next to the
## meter can use exactly the same scale; span_changed fires when it moves.

signal span_changed

const MIN_DB: float = -60.0
const MAX_DB: float = 6.0
## How fast a bar falls once the signal drops, in dB per second.
const RELEASE_DB_PER_SEC: float = 30.0
const HOLD_TIME: float = 1.2
const HOLD_FALL_DB_PER_SEC: float = 15.0
## At 100% display scale; multiplied by the editor's scale when drawn.
const CLIP_HEIGHT: float = 6.0
const GAP: float = 2.0
const BARS_WIDTH: float = 22.0
const SCALE_GAP: float = 3.0
const TICK_LENGTH: float = 4.0
## Scale numbers, as a share of the editor's label font size.
const SCALE_FONT_SCALE: float = 0.75
## How strongly the unlit colour zones show (0 = off, 1 = fully lit).
const ZONE_DIM: float = 0.12
## Ticks closer together than this are skipped.
const MIN_TICK_SPACING: float = 3.0

const SCALE_MARKS: Array[int] = [6, 0, -6, -12, -18, -24, -30, -36, -42, -48, -54, -60]
## Which numbers win when there isn't room for them all.
const SCALE_LABEL_PRIORITY: Array[int] = [0, -18, 6, -6, -12, -24, -36, -48, -60, -30, -42, -54]
const COLOR_TICK: Color = Color(1.0, 1.0, 1.0, 0.3)
const COLOR_SCALE_TEXT: Color = Color(1.0, 1.0, 1.0, 0.5)

const COLOR_BACK: Color = Color(0.08, 0.08, 0.09)
const COLOR_LOW: Color = Color(0.25, 0.8, 0.35)
const COLOR_MID: Color = Color(0.95, 0.8, 0.2)
const COLOR_HIGH: Color = Color(0.95, 0.25, 0.2)
const COLOR_HOLD: Color = Color(0.9, 0.9, 0.9)
const COLOR_ZERO_LINE: Color = Color(1.0, 1.0, 1.0, 0.25)
const COLOR_CLIP_OFF: Color = Color(0.25, 0.1, 0.1)
const COLOR_INACTIVE: Color = Color(0.15, 0.2, 0.35)
const COLOR_PEAK_TEXT: Color = Color(1.0, 1.0, 1.0, 0.75)
const COLOR_PEAK_NONE: Color = Color(1.0, 1.0, 1.0, 0.3)
## Where the bar turns yellow, then red.
const MID_DB: float = -12.0
const HIGH_DB: float = -3.0

var _shown: PackedFloat32Array = PackedFloat32Array([MIN_DB, MIN_DB])
var _hold: PackedFloat32Array = PackedFloat32Array([MIN_DB, MIN_DB])
var _hold_timer: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _clipped: bool = false
## Loudest reading since the last reset, either channel.
var _peak: float = -INF
var _active: bool = false
var _scale: float = 1.0
var _scale_font: Font = null
var _scale_font_size: int = 10
## Width of the widest scale number; numbers are right-aligned within it.
var _scale_text_width: float = 0.0


func _init() -> void:
	_scale = EditorInterface.get_editor_scale()
	# Short minimum: the meter grows to fill the strip, and the dock scrolls
	# rather than forcing its own height.
	custom_minimum_size = Vector2(BARS_WIDTH * _scale, 60.0 * _scale)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	tooltip_text = "Number: loudest peak since reset.\nClick to reset it and the clip light."
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(func() -> void: span_changed.emit())


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_scale_font = get_theme_font(&"font", &"Label")
		_scale_font_size = maxi(1, int(round(get_theme_font_size(&"font_size", &"Label") * SCALE_FONT_SCALE)))
		_scale_text_width = 0.0
		for mark: int in SCALE_MARKS:
			_scale_text_width = maxf(_scale_text_width, _scale_font.get_string_size(_mark_text(mark), HORIZONTAL_ALIGNMENT_LEFT, -1.0, _scale_font_size).x)
		var width: float = ceilf((BARS_WIDTH + SCALE_GAP + TICK_LENGTH + SCALE_GAP) * _scale + _scale_text_width)
		# Wide enough for the peak number too.
		width = maxf(width, ceilf(_scale_font.get_string_size("-60.0", HORIZONTAL_ALIGNMENT_LEFT, -1.0, _scale_font_size).x))
		custom_minimum_size.x = width
		queue_redraw()
		span_changed.emit()


## The bars' top and height in this control's coordinates. Anything that
## maps dB to height the same way (the fader) lines up with the scale.
func get_bar_span() -> Vector2:
	var half_text: float = _text_height() * 0.5
	var bar_top: float = maxf(_text_height() + GAP * _scale + CLIP_HEIGHT * _scale + GAP * _scale, half_text)
	return Vector2(bar_top, maxf(0.0, size.y - bar_top - half_text))


func _text_height() -> float:
	return _scale_font.get_height(_scale_font_size) if _scale_font != null else 0.0


## "+6" above zero, "0", then plain "6", "12" … below: the minus is implied.
func _mark_text(mark: int) -> String:
	if mark > 0:
		return "+%d" % mark
	return str(absi(mark))


func _process(delta: float) -> void:
	var changed: bool = false
	for ch: int in 2:
		if _hold_timer[ch] > 0.0:
			_hold_timer[ch] -= delta
		elif _hold[ch] > MIN_DB:
			_hold[ch] = maxf(MIN_DB, _hold[ch] - HOLD_FALL_DB_PER_SEC * delta)
			changed = true
		if _shown[ch] > MIN_DB:
			_shown[ch] = maxf(MIN_DB, _shown[ch] - RELEASE_DB_PER_SEC * delta)
			changed = true
	if changed:
		queue_redraw()


## Feeds a new reading. Values above what's shown jump up at once; lower
## values are ignored and the bar falls on its own in _process().
func push_levels(left_db: float, right_db: float, active: bool) -> void:
	_active = active
	var levels: PackedFloat32Array = PackedFloat32Array([left_db, right_db])
	for ch: int in 2:
		var level: float = levels[ch]
		if active:
			_peak = maxf(_peak, level)
		if level > 0.0:
			_clipped = true
		if level > _shown[ch]:
			_shown[ch] = minf(level, MAX_DB)
		if level >= _hold[ch]:
			_hold[ch] = minf(level, MAX_DB)
			_hold_timer[ch] = HOLD_TIME
	queue_redraw()


func reset() -> void:
	for ch: int in 2:
		_shown[ch] = MIN_DB
		_hold[ch] = MIN_DB
		_hold_timer[ch] = 0.0
	_clipped = false
	_peak = -INF
	_active = false
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		_clipped = false
		_peak = -INF
		queue_redraw()
		accept_event()


func _draw() -> void:
	var gap: float = GAP * _scale
	var clip_height: float = CLIP_HEIGHT * _scale
	var bars_width: float = BARS_WIDTH * _scale
	var bar_width: float = (bars_width - gap) * 0.5
	# Peak number on top, then the clip light, then the bars. Half a line of
	# scale text is kept free above +6 and below -60, so their numbers sit
	# level with their ticks instead of being pushed inside.
	var span: Vector2 = get_bar_span()
	var bar_top: float = span.x
	var bar_height: float = span.y
	_draw_peak(bars_width)
	for ch: int in 2:
		var x: float = ch * (bar_width + gap)
		draw_rect(Rect2(x, bar_top, bar_width, bar_height), COLOR_BACK)
		_draw_bar(x, bar_top, bar_width, bar_height, MAX_DB, ZONE_DIM)
		if _active:
			_draw_bar(x, bar_top, bar_width, bar_height, _shown[ch], 1.0)
		var hold_y: float = bar_top + bar_height * (1.0 - _db_to_ratio(_hold[ch]))
		if _hold[ch] > MIN_DB:
			draw_rect(Rect2(x, hold_y, bar_width, 1.0), COLOR_HOLD)
		draw_rect(Rect2(x, bar_top - gap - clip_height, bar_width, clip_height), COLOR_HIGH if _clipped else COLOR_CLIP_OFF)
		if not _active:
			draw_rect(Rect2(x, bar_top + bar_height - 2.0, bar_width, 2.0), COLOR_INACTIVE)
	var zero_y: float = bar_top + bar_height * (1.0 - _db_to_ratio(0.0))
	draw_rect(Rect2(0.0, zero_y, bars_width, 1.0), COLOR_ZERO_LINE)
	_draw_scale(bars_width, bar_top, bar_height)


## The loudest peak since reset, centred over the bars (it may run into the
## scale column, which has nothing at that height).
func _draw_peak(bars_width: float) -> void:
	if _scale_font == null:
		return
	var text: String = "%.1f" % _peak if _peak > MIN_DB else "—"
	var color: Color = COLOR_PEAK_NONE
	if _peak > 0.0:
		color = COLOR_HIGH
	elif _peak > MIN_DB:
		color = COLOR_PEAK_TEXT
	var width: float = _scale_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, _scale_font_size).x
	var x: float = clampf((bars_width - width) * 0.5, 0.0, maxf(0.0, size.x - width))
	draw_string(_scale_font, Vector2(x, _scale_font.get_ascent(_scale_font_size)), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, _scale_font_size, color)


func _draw_scale(bars_width: float, bar_top: float, bar_height: float) -> void:
	if _scale_font == null:
		return
	var tick_x: float = bars_width + SCALE_GAP * _scale
	var tick_length: float = TICK_LENGTH * _scale
	var text_x: float = tick_x + tick_length + SCALE_GAP * _scale

	var last_tick_y: float = -INF
	for mark: int in SCALE_MARKS:
		var y: float = roundf(bar_top + bar_height * (1.0 - _db_to_ratio(mark)))
		if y - last_tick_y < MIN_TICK_SPACING * _scale:
			continue
		last_tick_y = y
		draw_rect(Rect2(tick_x, y, tick_length, maxf(1.0, roundf(_scale))), COLOR_TICK)

	var text_height: float = _scale_font.get_height(_scale_font_size)
	var ascent: float = _scale_font.get_ascent(_scale_font_size)
	var placed: Array[Rect2] = []
	for mark: int in SCALE_LABEL_PRIORITY:
		var text: String = _mark_text(mark)
		var width: float = _scale_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, _scale_font_size).x
		var y: float = bar_top + bar_height * (1.0 - _db_to_ratio(mark))
		var top: float = y - text_height * 0.5
		# Right-aligned in the column.
		var x: float = text_x + _scale_text_width - width
		var rect: Rect2 = Rect2(x, top, width, text_height)
		var fits: bool = true
		for other: Rect2 in placed:
			if rect.grow(1.0 * _scale).intersects(other):
				fits = false
				break
		if not fits:
			continue
		placed.append(rect)
		draw_string(_scale_font, Vector2(x, top + ascent), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, _scale_font_size, COLOR_SCALE_TEXT)


## Draws a bar in three colour bands so the top of a loud signal shows red
## while the bottom stays green. strength below 1 blends the colours into the
## background, for the faint unlit zones.
func _draw_bar(x: float, top: float, width: float, height: float, level_db: float, strength: float) -> void:
	var bands: Array[Array] = [
		[MIN_DB, MID_DB, COLOR_LOW],
		[MID_DB, HIGH_DB, COLOR_MID],
		[HIGH_DB, MAX_DB, COLOR_HIGH],
	]
	for band: Array in bands:
		var from_db: float = band[0]
		var to_db: float = minf(band[1], level_db)
		if to_db <= from_db:
			break
		var y_from: float = top + height * (1.0 - _db_to_ratio(from_db))
		var y_to: float = top + height * (1.0 - _db_to_ratio(to_db))
		draw_rect(Rect2(x, y_to, width, y_from - y_to), COLOR_BACK.lerp(band[2] as Color, strength))


func _db_to_ratio(db: float) -> float:
	return clampf((db - MIN_DB) / (MAX_DB - MIN_DB), 0.0, 1.0)
