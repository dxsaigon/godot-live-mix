@tool
extends VBoxContainer
## The Live Mixer's loudness block: target picker and M / S / I / TP
## readouts for what comes out of Master. It also builds the reference pink noise
## controls, but the dock places those itself, above Master
## (get_noise_controls()), and the dock's Reset calls reset_measurement().
##
## The audio is captured at the end of Master's effects (after the limiter)
## but before Master's fader, so the fader's gain is applied to the audio as
## it arrives. The readings show what actually leaves the game.
##
## The target is saved per project in the editor's project metadata, not in
## project.godot, so it never shows up in a commit.
##
## "Ref noise" is a hold button: press for Solo, release to go back to the
## dropdown's previous setting. The game's own hold key (P) does the same,
## and the dropdown follows it. While any noise plays, the button and the
## dropdown get a pink fill, so noise left on by accident is hard to miss.
##
## LAYOUT: row 1 is the dock's Active switch and status (get_header_cell())
## followed by the target picker. Under it, a two-column grid: column A holds
## the readouts, column B the dock's Reset (get_reset_cell()). When there's
## room, all four readouts sit on one row with Reset at its end. When there
## isn't, they split: M and S with Reset after them, I and TP on a third row
## directly under M and S, so the readouts never get separated. The dock
## tells it how much width there is (fit_width()), because its own size
## can't shrink below what the one-row arrangement needs. The target dropdown is only as
## wide as the option shown.
##
## The noise modes are Off, Both (noise and game together) and Solo.
##
## Readouts never change width: they use the editor's monospace font, every
## value (and the "—" placeholder) is padded to the same number of
## characters, and each box is sized to that, re-measured whenever the
## editor theme changes (e.g. display scale).

const LiveMixerLoudness: GDScript = preload("live_mixer_loudness.gd")
const LiveMixerDebugger: GDScript = preload("live_mixer_debugger.gd")

const META_SECTION: String = "live_mixer"
const PRESETS: Array[Array] = [
	["PC / Steam  -18 LUFS", -18.0],
	["Console  -24 LUFS", -24.0],
	["Custom", 0.0],
]
const CUSTOM_PRESET: int = 2
const DEFAULT_CUSTOM_LUFS: float = -16.0
## How far from the target still counts as on target (the standards' ±2 LU).
const TOLERANCE_LU: float = 2.0
const TRUE_PEAK_LIMIT_DB: float = -1.0
const REFRESH_SEC: float = 0.1
## After the noise is switched off, audio already on its way from the game
## still has noise in it. Integrated stays paused this long to let it pass.
const NOISE_TAIL_SEC: float = 1.0

const NOISE_OFF: int = 0
const NOISE_WITH_GAME: int = 1
const NOISE_SOLO: int = 2

const COLOR_ON_TARGET: Color = Color(0.55, 1.0, 0.6)
const COLOR_QUIET: Color = Color(1.0, 0.8, 0.4)
const COLOR_LOUD: Color = Color(1.0, 0.45, 0.4)
const COLOR_IDLE: Color = Color(1.0, 1.0, 1.0, 0.55)
## Pink, for pink noise: no other colour in the dock means "noise playing".
const COLOR_NOISE: Color = Color("#e86aa6")
## The edge of the pink buttons, in place of the theme's grey one.
const COLOR_NOISE_EDGE: Color = Color("#8d5e75")
## How much of COLOR_NOISE is mixed into the buttons' own background.
const NOISE_FILL: float = 0.35
const NOISE_STYLES: Array[StringName] = [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled"]
## Side padding of Ref noise and the mode dropdown, at 100% display scale,
## so they fit the column above Master.
const COMPACT_PAD: float = 4.0
## Widest text each readout can show; sets its fixed width.
const WIDEST_VALUE: String = "-99.9"
const WIDEST_WITH_DELTA: String = "-99.9 (+99.9)"
## Quieter than this shows as "—", so the text can't outgrow its box.
const DISPLAY_FLOOR: float = -99.9

var _debugger: LiveMixerDebugger = null
var _meter: LiveMixerLoudness = LiveMixerLoudness.new()
var _noise_tail: float = 0.0
var _target_menu: OptionButton = null
var _custom_box: SpinBox = null
var _noise_menu: OptionButton = null
var _hold: Button = null
## Ref noise and the mode dropdown, side by side. Not a child of this row:
## the dock puts it in the column above Master.
var _noise_row: HBoxContainer = null
## Row 1: the dock's Active switch and status, then the target picker.
var _header_cell: HBoxContainer = null
var _target_group: HBoxContainer = null
## The grid under it. A1 and A2 are the readouts, B1 Reset, B2 empty.
var _grid: GridContainer = null
var _reset_cell: HBoxContainer = null
var _top_readouts: HBoxContainer = null
var _under_reset: Control = null
var _bottom_readouts: HBoxContainer = null
## Each readout's caption and value, moved between B1 and B2 as one piece.
var _pairs: Array[HBoxContainer] = []
var _wide: bool = true
var _available: float = -1.0
var _fit_queued: bool = false
var _m_label: Label = null
var _s_label: Label = null
var _i_label: Label = null
var _tp_label: Label = null
var _refresh: float = 0.0
var _mode_before_hold: int = NOISE_OFF


func _init() -> void:
	_build()


func setup(debugger: LiveMixerDebugger) -> void:
	_debugger = debugger
	_debugger.audio_received.connect(_on_audio)
	_debugger.silence_received.connect(_on_silence)
	_debugger.noise_mode_received.connect(_on_game_noise_mode)
	_load_target()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _m_label != null:
		_fix_readout_widths()
		# The readouts' widths just changed, so one row may no longer fit.
		_queue_fit()
		# Deferred: the buttons get their own theme update after this one.
		_tint_noise_controls.call_deferred()


func _build() -> void:
	var row_1: HBoxContainer = HBoxContainer.new()
	row_1.add_theme_constant_override(&"separation", _gap())
	add_child(row_1)
	_header_cell = HBoxContainer.new()
	row_1.add_child(_header_cell)
	_target_group = HBoxContainer.new()
	row_1.add_child(_target_group)
	var target_group: HBoxContainer = _target_group

	# Hidden cells drop out of a grid's layout, so hiding A2 and B2 removes
	# the third row entirely.
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override(&"h_separation", _gap())
	add_child(_grid)
	_top_readouts = _readout_row()
	_reset_cell = HBoxContainer.new()
	_grid.add_child(_reset_cell)
	_bottom_readouts = _readout_row()
	_under_reset = Control.new()
	_grid.add_child(_under_reset)
	target_group.add_child(_caption("Target"))
	_target_menu = OptionButton.new()
	for preset: Array in PRESETS:
		_target_menu.add_item(str(preset[0]))
	_target_menu.tooltip_text = "Integrated loudness to aim for at the player's default volume.\n-18: PC and handheld. -24: console (Sony / GANG home spec)."
	_target_menu.item_selected.connect(_on_target_selected)
	_target_menu.fit_to_longest_item = false
	target_group.add_child(_target_menu)

	_custom_box = SpinBox.new()
	_custom_box.min_value = -40.0
	_custom_box.max_value = -5.0
	_custom_box.step = 0.5
	_custom_box.suffix = "LUFS"
	_custom_box.value = DEFAULT_CUSTOM_LUFS
	_custom_box.custom_minimum_size = Vector2(130.0 * EditorInterface.get_editor_scale(), 0.0)
	_custom_box.value_changed.connect(_on_custom_changed)
	_custom_box.visible = false
	target_group.add_child(_custom_box)

	_m_label = _readout("M", "Momentary: last 0.4 s.")
	_s_label = _readout("S", "Short-term: last 3 s.")
	_i_label = _readout("I", "Integrated: whole session since the last reset, gated per BS.1770. This is the number to match to the target; the bracket shows how far off it is.\nPaused while reference noise plays.")
	_tp_label = _readout("TP", "True peak since the last reset, in dBTP. Should stay at or below -1.")
	for label: Label in [_m_label, _s_label, _i_label, _tp_label]:
		_set_readout(label, "—")
	_place_readouts()
	_reset_cell.minimum_size_changed.connect(_queue_fit)

	_noise_row = HBoxContainer.new()
	_hold = Button.new()
	_hold.text = "Ref noise"
	_hold.tooltip_text = "Hold for Solo noise; let go to go back. In the game window, hold P for the same."
	_hold.button_down.connect(_on_hold_down)
	_hold.button_up.connect(_on_hold_up)
	_hold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_noise_row.add_child(_hold)
	_noise_menu = OptionButton.new()
	_noise_menu.add_item("Off")
	_noise_menu.add_item("Both")
	_noise_menu.add_item("Solo")
	_noise_menu.tooltip_text = "Pink noise at exactly the target loudness.\nBoth: the noise plays with the game, both turned down 3 dB so a game on target plus the noise still totals the target.\nSolo: silences every bus that feeds Master so only the noise plays; switch back and forth to compare by ear.\n(Sounds playing straight into Master, not through a bus, aren't silenced.)"
	_noise_menu.item_selected.connect(_on_noise_selected)
	_noise_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Sized to the shown text, not the longest item: the longest-item size
	# adds a lot of slack, and the dropdown stretches to the column anyway.
	_noise_menu.fit_to_longest_item = false
	_noise_row.add_child(_noise_menu)


## Ref noise and the mode dropdown, for the dock to place.
func get_noise_controls() -> HBoxContainer:
	return _noise_row


## Start of row 1: the dock puts its Active switch and status here.
func get_header_cell() -> HBoxContainer:
	return _header_cell


## After the readouts: the dock puts its Reset here.
func get_reset_cell() -> HBoxContainer:
	return _reset_cell


## Hides the target, Reset and readouts (Active and the status stay).
func set_meters_visible(on: bool) -> void:
	_target_group.visible = on
	_grid.visible = on


## The width the grid may use. Picks the wide or split arrangement to fit.
func fit_width(available: float) -> void:
	_available = available
	_queue_fit()


func _gap() -> int:
	return int(round(12.0 * EditorInterface.get_editor_scale()))


func _readout_row() -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override(&"separation", _gap())
	_grid.add_child(row)
	return row


func _queue_fit() -> void:
	if _fit_queued:
		return
	_fit_queued = true
	_fit.call_deferred()


## One row if Reset plus all four readouts fit; otherwise split. Worked out
## from the pieces' own sizes, which don't depend on where they sit, so the
## choice can't flip back and forth.
func _fit() -> void:
	_fit_queued = false
	if _available < 0.0:
		return
	var column_a: float = _reset_cell.get_combined_minimum_size().x
	var readouts: float = float(_gap() * (_pairs.size() - 1))
	for pair: HBoxContainer in _pairs:
		readouts += pair.get_combined_minimum_size().x
	var wide: bool = column_a + float(_gap()) + readouts <= _available
	if wide != _wide:
		_wide = wide
		_place_readouts()


func _place_readouts() -> void:
	for i: int in _pairs.size():
		var pair: HBoxContainer = _pairs[i]
		var row: HBoxContainer = _top_readouts if _wide or i < 2 else _bottom_readouts
		if pair.get_parent() != row:
			if pair.get_parent() != null:
				pair.get_parent().remove_child(pair)
			row.add_child(pair)
	# Keep M, S, I, TP order within the top row.
	for i: int in _pairs.size():
		if _pairs[i].get_parent() == _top_readouts:
			_top_readouts.move_child(_pairs[i], -1)
	_under_reset.visible = not _wide
	_bottom_readouts.visible = not _wide


func _caption(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.modulate = COLOR_IDLE
	return label


func _readout(caption: String, tip: String) -> Label:
	var group: HBoxContainer = HBoxContainer.new()
	_pairs.append(group)
	var cap: Label = _caption(caption)
	cap.tooltip_text = tip
	cap.mouse_filter = Control.MOUSE_FILTER_PASS
	group.add_child(cap)
	var value: Label = Label.new()
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.tooltip_text = tip
	value.mouse_filter = Control.MOUSE_FILTER_PASS
	group.add_child(value)
	return value


## The longest text a readout can show. Worked out from which readout it is,
## not stored on the label, so labels made by an earlier version of this
## script (the plugin updated while the editor is open) still work.
func _widest_for(label: Label) -> String:
	return WIDEST_WITH_DELTA if label == _i_label else WIDEST_VALUE


## Pads to the readout's fixed character count. In a monospace font that
## makes every value, and the placeholder, exactly the same width.
func _set_readout(label: Label, text: String) -> void:
	label.text = text.lpad(_widest_for(label).length())


## Monospace digits, and a fixed width per readout: the label is measured
## with its widest text in place (so its own padding counts too), and that
## width is locked in.
func _fix_readout_widths() -> void:
	var font: Font = EditorInterface.get_editor_theme().get_font(&"source", &"EditorFonts")
	for label: Label in [_m_label, _s_label, _i_label, _tp_label]:
		if font != null:
			label.add_theme_font_override(&"font", font)
		var shown: String = label.text
		label.custom_minimum_size = Vector2.ZERO
		label.text = _widest_for(label)
		label.custom_minimum_size = Vector2(ceilf(label.get_minimum_size().x) + 2.0, 0.0)
		label.text = shown


## Master's fader level, which sits after the capture point.
func set_master_db(db: float) -> void:
	_meter.set_input_gain_db(db)


## A new run started: measure it from scratch.
func on_run_started() -> void:
	_meter.reset()
	# Tell the game the target now, so its hold key plays the right level
	# before the dropdown is ever touched.
	_send_noise()


## The game stopped, which also stops its noise.
func on_run_stopped() -> void:
	_noise_menu.select(NOISE_OFF)
	_noise_tail = 0.0
	_meter.set_integrating(true)
	_tint_noise_controls()


func target_lufs() -> float:
	var preset: int = _target_menu.selected
	if preset == CUSTOM_PRESET:
		return _custom_box.value
	return float(PRESETS[preset][1])


func _process(delta: float) -> void:
	if _noise_tail > 0.0:
		_noise_tail -= delta
		if _noise_tail <= 0.0 and _noise_menu.selected == NOISE_OFF:
			_meter.set_integrating(true)
	_refresh += delta
	if _refresh < REFRESH_SEC:
		return
	_refresh = 0.0
	var target: float = target_lufs()
	var m: float = _meter.momentary
	var s: float = _meter.short_term
	var i: float = _meter.integrated
	var tp: float = _meter.true_peak
	_show_loudness(_m_label, m, target, false)
	_show_loudness(_s_label, s, target, false)
	_show_loudness(_i_label, i, target, true)
	if tp < DISPLAY_FLOOR:
		_set_readout(_tp_label, "—")
		_tp_label.modulate = COLOR_IDLE
	else:
		_set_readout(_tp_label, "%.1f" % tp)
		_tp_label.modulate = COLOR_LOUD if tp > TRUE_PEAK_LIMIT_DB else Color.WHITE


func _show_loudness(label: Label, value: float, target: float, with_delta: bool) -> void:
	if value < DISPLAY_FLOOR:
		_set_readout(label, "—")
		label.modulate = COLOR_IDLE
		return
	var off: float = value - target
	_set_readout(label, ("%.1f (%+.1f)" % [value, off]) if with_delta else ("%.1f" % value))
	if absf(off) <= TOLERANCE_LU:
		label.modulate = COLOR_ON_TARGET
	elif off < 0.0:
		label.modulate = COLOR_QUIET
	else:
		label.modulate = COLOR_LOUD


func _on_audio(rate: float, frames: PackedVector2Array) -> void:
	_meter.set_rate(rate)
	_meter.push(frames)


func _on_silence(rate: float, frame_count: int) -> void:
	_meter.set_rate(rate)
	_meter.push_silence(frame_count)


## Starts a new integrated and true-peak measurement. Called by the dock's
## Reset, which also clears the clip lights.
func reset_measurement() -> void:
	_meter.reset()


func _on_target_selected(index: int) -> void:
	_custom_box.visible = index == CUSTOM_PRESET
	_save_target()
	_send_noise()


func _on_custom_changed(_value: float) -> void:
	_save_target()
	_send_noise()


func _on_noise_selected(index: int) -> void:
	_select_noise(index, true)


func _on_hold_down() -> void:
	_mode_before_hold = _noise_menu.selected
	_select_noise(NOISE_SOLO, true)


func _on_hold_up() -> void:
	_select_noise(_mode_before_hold, true)


## The game's hold key changed the mode; mirror it without sending it back.
func _on_game_noise_mode(mode: int) -> void:
	_select_noise(mode, false)


func _select_noise(mode: int, send: bool) -> void:
	_noise_menu.select(mode)
	if mode == NOISE_OFF:
		_noise_tail = NOISE_TAIL_SEC
	else:
		_noise_tail = 0.0
		_meter.set_integrating(false)
	if send:
		_send_noise()
	_tint_noise_controls()


## Pink fill on the Ref noise button and the dropdown while noise
## plays; the theme's own look when it's off. Either way, built from the
## theme's own styles with narrower side padding, so corners and height
## stay the same at any display scale.
func _tint_noise_controls() -> void:
	var on: bool = _noise_menu.selected != NOISE_OFF
	var pad: float = COMPACT_PAD * EditorInterface.get_editor_scale()
	for control: Button in [_hold, _noise_menu]:
		for style_name: StringName in NOISE_STYLES:
			control.remove_theme_stylebox_override(style_name)
			var base: StyleBox = control.get_theme_stylebox(style_name)
			var style: StyleBox = base.duplicate() as StyleBox
			if on:
				var tinted: StyleBoxFlat = style as StyleBoxFlat
				if tinted == null:
					# The theme doesn't use flat boxes; build one with its padding.
					tinted = StyleBoxFlat.new()
					tinted.bg_color = Color(0.2, 0.2, 0.22)
					for side: int in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
						tinted.set_content_margin(side, base.get_content_margin(side))
				tinted.bg_color = tinted.bg_color.lerp(COLOR_NOISE, NOISE_FILL)
				tinted.border_color = COLOR_NOISE_EDGE
				style = tinted
			style.content_margin_left = pad
			style.content_margin_right = pad
			control.add_theme_stylebox_override(style_name, style)


func _send_noise() -> void:
	if _debugger == null:
		return
	_debugger.send("set_noise", [_noise_menu.selected, target_lufs()])


func _load_target() -> void:
	var settings: EditorSettings = EditorInterface.get_editor_settings()
	var preset: int = int(settings.get_project_metadata(META_SECTION, "target_preset", 0))
	var custom: float = float(settings.get_project_metadata(META_SECTION, "custom_lufs", DEFAULT_CUSTOM_LUFS))
	_custom_box.set_value_no_signal(custom)
	_target_menu.select(clampi(preset, 0, PRESETS.size() - 1))
	_custom_box.visible = _target_menu.selected == CUSTOM_PRESET


func _save_target() -> void:
	var settings: EditorSettings = EditorInterface.get_editor_settings()
	settings.set_project_metadata(META_SECTION, "target_preset", _target_menu.selected)
	settings.set_project_metadata(META_SECTION, "custom_lufs", _custom_box.value)
