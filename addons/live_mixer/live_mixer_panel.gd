@tool
extends EditorDock
## The Live Mixer dock. Shows one strip per bus of the running game, with
## live meters, and sends fader and toggle changes to the game as they
## happen.
##
## Changes only live in the running game until you press Commit, which
## writes them into the project's bus layout file. Only what you touched in
## this dock is committed, so volumes the game set at runtime (e.g. from a
## settings menu) never leak into the layout.
##
## The Active switch pauses everything: the game stops sending, takes its
## capture off Master and stops its per-frame work, and the dock hides its
## meters. Remembered per project, and applied to each new run as soon as
## the game connects.
##
## LAYOUT: two columns. On the left: Active, the status and the target on
## one row; the loudness readouts and Reset on the next (split over two rows
## when the dock is narrow; see live_mixer_loudness_bar.gd); then the bus
## strips, which narrow and then scroll sideways when they don't fit. On the
## right, pinned so they never scroll away: Discard and Commit, Ref noise and
## its mode, and Master's strip below them, like the master section of a
## desk. The right column is a strip's width unless its buttons need more.
##
## The whole dock scrolls up and down when it's short.
##
## EFFECTS: one accordion opens or closes every bus's effect list together.
## A narrow tab in a gutter at the dock's left edge, outside the scrolling
## strips, always holds the arrow: "▾" when closed, "▴" when open, and
## clicking it toggles. Closed, the word "Effects" sits beside it under the
## first strip (also clickable), and Master gets an empty space the same
## height so its bottom stays level. Open, the lists sit under their strips,
## level with the tab, so the open state spends no height on a title row.
## The top rows start after the same gutter, so everything shares one left
## edge. Neither has a tooltip: in a floating dock, a tooltip starting on
## a button that has just hidden itself made Godot fail to create windows.
##
## Each list is as tall as the bus with the most effects needs, so nothing
## in it scrolls. Open or closed is remembered per project.
##
## STRIP WIDTH: the buses share the strip area. Each is STRIP_WIDTH wide when
## there's room, narrows (down to what its controls need) when there isn't,
## and only then does the area scroll. Master keeps its column's width.
##
## Strips sit on faint cards; Master's is tinted. Master's effects sit in its
## own column, and spacers under them keep its bottom level with the other
## strips whether the accordion is open or closed and whether the
## sideways scrollbar is showing.
##
## Edits survive the game stopping, so you can tune, quit, then Commit.
## Starting a new run drops any edits that weren't committed, with a
## warning in the Output panel.

const LiveMixerStrip: GDScript = preload("live_mixer_strip.gd")
const LiveMixerDebugger: GDScript = preload("live_mixer_debugger.gd")
const LiveMixerLoudnessBar: GDScript = preload("live_mixer_loudness_bar.gd")

const SILENT_THRESHOLD_DB: float = -199.0
## The Effects tab's arrow, open and closed.
const FX_OPEN_ARROW: String = "▴"
const FX_CLOSED_ARROW: String = "▾"
## Space between the last bus and Master, at 100% display scale.
const MASTER_GAP: float = 10.0
## Side padding of Discard and Commit, at 100% display scale, so they fit
## the column above Master. Matches the loudness row's COMPACT_PAD.
const COMPACT_PAD: float = 4.0
const STATUS_TEXTS: Array[String] = ["‖ Paused", "● Live", "○ Not running", "● Stopped"]

var _debugger: LiveMixerDebugger = null
var _status: Label = null
var _commit_button: Button = null
var _discard_button: Button = null
var _strip_row: HBoxContainer = null
var _loudness: LiveMixerLoudnessBar = null
var _strips: Array[LiveMixerStrip] = []
var _bus_names: Array[String] = []
## bus name -> { key -> value before the first edit }.
var _originals: Dictionary = {}
## bus name -> { key -> value last sent to the game }.
var _current: Dictionary = {}
## The game's most recent report, one Dictionary per bus.
var _last_state: Array = []
var _was_running: bool = false
var _active_switch: CheckButton = null
var _paused_note: Label = null
var _scroll: ScrollContainer = null
var _fx_toggle: Button = null
var _fx_row: HBoxContainer = null
## The narrow tab in the left gutter holding the Effects arrow.
var _fx_tab: Button = null
var _fx_open_box: HBoxContainer = null
## The bus strips (all but Master), scrolling sideways.
var _strip_scroll: ScrollContainer = null
## Above Master: Discard and Commit, then Ref noise and its mode.
var _right_top: VBoxContainer = null
var _edit_row: HBoxContainer = null
var _noise_row: HBoxContainer = null
var _reset_button: Button = null
## Master's strip, then its effects or the spacers that stand in for the
## closed Effects line and the sideways scrollbar.
var _master_col: VBoxContainer = null
var _fx_closed_spacer: Control = null
var _tab_col: VBoxContainer = null
var _tab_scroll_spacer: Control = null
var _top_right: HBoxContainer = null
var _top_tab_spacer: Control = null
var _master_scroll_spacer: Control = null
var _width_sync_queued: bool = false
var _body: HBoxContainer = null
var _strip_content: VBoxContainer = null
var _strip_fit_queued: bool = false


func _init() -> void:
	title = "Live Mixer"
	layout_key = "live_mixer"
	icon_name = &"AudioStreamPlayer"
	default_slot = EditorDock.DOCK_SLOT_BOTTOM
	available_layouts = EditorDock.DOCK_LAYOUT_HORIZONTAL | EditorDock.DOCK_LAYOUT_FLOATING
	_build()


func setup(debugger: LiveMixerDebugger) -> void:
	_debugger = debugger
	_debugger.state_received.connect(_on_state_received)
	_debugger.peaks_received.connect(_on_peaks_received)
	_debugger.running_changed.connect(_on_running_changed)
	_loudness.setup(_debugger)
	var active: bool = bool(EditorInterface.get_editor_settings().get_project_metadata("live_mixer", "active", true))
	_active_switch.set_pressed_no_signal(active)
	var effects_open: bool = bool(EditorInterface.get_editor_settings().get_project_metadata("live_mixer", "effects_open", true))
	_fx_toggle.set_pressed_no_signal(effects_open)
	_apply_effects_open()
	_apply_active_view()
	_update_status()


func _build() -> void:
	var ui_scale: float = EditorInterface.get_editor_scale()
	var column_gap: int = int(round(MASTER_GAP * ui_scale))

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	var column: VBoxContainer = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(column)

	var top: HBoxContainer = HBoxContainer.new()
	top.add_theme_constant_override(&"separation", column_gap)
	column.add_child(top)

	# The loudness block is the left block: Active and the status start its
	# first row, and Reset heads the readouts under it.
	var left_top: HBoxContainer = HBoxContainer.new()
	left_top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_top.add_theme_constant_override(&"separation", 0)
	top.add_child(left_top)
	_top_tab_spacer = Control.new()
	left_top.add_child(_top_tab_spacer)
	_loudness = LiveMixerLoudnessBar.new()
	_loudness.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_top.add_child(_loudness)
	var header: HBoxContainer = _loudness.get_header_cell()

	_active_switch = CheckButton.new()
	_active_switch.text = "Active"
	_active_switch.button_pressed = true
	_active_switch.tooltip_text = "Off: the running game stops metering and sending audio to the editor, at no per-frame cost (e.g. while profiling). Remembered for future runs."
	_active_switch.toggled.connect(_on_active_toggled)
	header.add_child(_active_switch)

	_status = Label.new()
	header.add_child(_status)

	_reset_button = Button.new()
	_reset_button.text = "Reset"
	_reset_button.tooltip_text = "Clear every bus's clip light and peak hold, and start a new loudness measurement (integrated and true peak)."
	_reset_button.pressed.connect(_on_reset_pressed)
	_loudness.get_reset_cell().add_child(_reset_button)

	_top_right = HBoxContainer.new()
	_top_right.add_theme_constant_override(&"separation", 0)
	top.add_child(_top_right)
	_right_top = VBoxContainer.new()
	_top_right.add_child(_right_top)
	# Tells the loudness grid how much room it has, so it can split the
	# readouts over two rows instead of forcing the dock wide.
	_scroll.resized.connect(_fit_loudness)
	_top_right.resized.connect(_fit_loudness)
	_scroll.get_v_scroll_bar().visibility_changed.connect(_fit_loudness)

	_edit_row = HBoxContainer.new()
	_right_top.add_child(_edit_row)
	_discard_button = Button.new()
	_discard_button.text = "Discard"
	_discard_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_discard_button.pressed.connect(_on_discard_pressed)
	_edit_row.add_child(_discard_button)
	_commit_button = Button.new()
	_commit_button.text = "Commit"
	_commit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_commit_button.pressed.connect(_on_commit_pressed)
	_edit_row.add_child(_commit_button)

	_noise_row = _loudness.get_noise_controls()
	_right_top.add_child(_noise_row)

	for row: Control in [_edit_row, _noise_row]:
		row.minimum_size_changed.connect(_queue_width_sync)

	_paused_note = Label.new()
	_paused_note.text = "Paused. The game isn't metering or sending anything. Switch Active on to resume."
	_paused_note.modulate = Color(1.0, 1.0, 1.0, 0.6)
	_paused_note.visible = false
	column.add_child(_paused_note)

	var body: HBoxContainer = HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override(&"separation", column_gap)
	column.add_child(body)
	_body = body

	# The gutter with the Effects arrow, then the strips.
	var left_side: HBoxContainer = HBoxContainer.new()
	left_side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_side.add_theme_constant_override(&"separation", 0)
	body.add_child(left_side)
	_tab_col = VBoxContainer.new()
	_tab_col.add_theme_constant_override(&"separation", 0)
	left_side.add_child(_tab_col)

	# Sideways only; the outer scroll handles up and down for the whole dock.
	_strip_scroll = ScrollContainer.new()
	_strip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_strip_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_strip_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_side.add_child(_strip_scroll)
	var bar: HScrollBar = _strip_scroll.get_h_scroll_bar()
	bar.visibility_changed.connect(_sync_master_spacers)
	bar.resized.connect(_sync_master_spacers)

	var content: VBoxContainer = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# No gap between the strips and the Effects row below them.
	content.add_theme_constant_override(&"separation", 0)
	_strip_scroll.add_child(content)
	_strip_content = content
	content.resized.connect(_sync_master_spacers)
	_strip_scroll.resized.connect(_sync_master_spacers)
	_strip_scroll.resized.connect(_queue_strip_fit)

	_strip_row = HBoxContainer.new()
	_strip_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_strip_row)

	# Closed: the "Effects" line, under the first strip. Built here, filled
	# in below.
	_fx_toggle = Button.new()
	content.add_child(_fx_toggle)

	# Open: the lists.
	_fx_open_box = HBoxContainer.new()
	content.add_child(_fx_open_box)

	# Its pressed state is the accordion's state.
	_fx_toggle.flat = true
	_fx_toggle.toggle_mode = true
	_fx_toggle.button_pressed = true
	_fx_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_fx_toggle.text = "Effects"
	_fx_toggle.toggled.connect(_on_effects_toggled)

	_fx_tab = Button.new()
	_fx_tab.flat = true
	_fx_tab.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_fx_tab.size_flags_vertical = Control.SIZE_FILL
	_fx_tab.pressed.connect(func() -> void: _fx_toggle.button_pressed = not _fx_toggle.button_pressed)
	_fx_tab.draw.connect(_draw_fx_tab)
	_fx_tab.mouse_entered.connect(_fx_tab.queue_redraw)
	_fx_tab.mouse_exited.connect(_fx_tab.queue_redraw)
	_fx_row = HBoxContainer.new()
	_fx_open_box.add_child(_fx_row)

	# The gutter: empty space, then the tab level with the effects lists,
	# then the scrollbar's height.
	var above_tab: Control = Control.new()
	above_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_col.add_child(above_tab)
	_tab_col.add_child(_fx_tab)
	_tab_scroll_spacer = Control.new()
	_tab_col.add_child(_tab_scroll_spacer)

	# Master's column. Its strip is added when the game reports its buses.
	_master_col = VBoxContainer.new()
	_master_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_master_col.add_theme_constant_override(&"separation", 0)
	body.add_child(_master_col)
	# Closed: stands in for the "Effects" line.
	_fx_closed_spacer = Control.new()
	_master_col.add_child(_fx_closed_spacer)
	_master_scroll_spacer = Control.new()
	_master_col.add_child(_master_scroll_spacer)

	_update_buttons()
	_queue_width_sync()


func _on_running_changed(running: bool) -> void:
	if running and not _was_running and _edit_count() > 0:
		push_warning("Live Mixer: dropped %d uncommitted change(s) from the last run." % _edit_count())
		_originals.clear()
		_current.clear()
	if running and not _was_running:
		_loudness.on_run_started()
		_send_active()
	_was_running = running
	if not running:
		_loudness.on_run_stopped()
		for strip: LiveMixerStrip in _strips:
			strip.reset_meter()
	_update_status()
	_update_buttons()


func _on_active_toggled(on: bool) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("live_mixer", "active", on)
	_send_active()
	if on:
		_loudness.on_run_started()
	_apply_active_view()


func _send_active() -> void:
	if _debugger != null:
		_debugger.send("set_active", [_active_switch.button_pressed])


func _apply_active_view() -> void:
	var on: bool = _active_switch.button_pressed
	_body.visible = on
	_loudness.set_meters_visible(on)
	_noise_row.visible = on
	_paused_note.visible = not on
	if not on:
		_loudness.on_run_stopped()
		for strip: LiveMixerStrip in _strips:
			strip.reset_meter()
	_update_status()


func _on_effects_toggled(open: bool) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("live_mixer", "effects_open", open)
	_apply_effects_open()


func _apply_effects_open() -> void:
	var open: bool = _fx_toggle.button_pressed
	_fx_open_box.visible = open
	_fx_tab.queue_redraw()
	_fx_toggle.visible = not open
	_fx_closed_spacer.visible = not open
	if not _strips.is_empty():
		_strips[0].get_effects_panel().visible = open
	_sync_master_spacers()


## Keeps Master's bottom level with the other strips: Master gets an empty
## space as tall as the closed "Effects" line, the tab is as tall as whatever
## sits beside it, and under Master and the tab goes whatever space the strip
## area keeps below its content (scrollbar and theme gaps).
func _sync_master_spacers() -> void:
	if _fx_closed_spacer == null:
		return
	_fx_closed_spacer.custom_minimum_size = Vector2(0.0, _fx_toggle.get_combined_minimum_size().y)
	# As tall as whatever sits beside it: the lists, or the "Effects" line.
	var beside: float = _fx_toggle.get_combined_minimum_size().y
	if _fx_toggle.button_pressed and not _strips.is_empty():
		beside = _strips[0].get_effects_panel().get_combined_minimum_size().y
	_fx_tab.custom_minimum_size = Vector2(_fx_tab.custom_minimum_size.x, beside)
	# Measured, not worked out from the theme: whatever the scroll container
	# keeps below its content (the bar, plus any gap or margin the editor
	# theme adds) is matched under Master.
	var reserved: float = maxf(0.0, _strip_scroll.size.y - _strip_content.size.y)
	_master_scroll_spacer.custom_minimum_size = Vector2(0.0, reserved)
	_tab_scroll_spacer.custom_minimum_size = Vector2(0.0, reserved)


func _fit_loudness() -> void:
	var gap: float = float(_top_right.get_parent().get_theme_constant(&"separation"))
	var width: float = _scroll.size.x - _top_right.size.x - gap - _top_tab_spacer.size.x
	var bar: VScrollBar = _scroll.get_v_scroll_bar()
	if bar.visible:
		width -= bar.size.x
	_loudness.fit_width(width)


## The status is as wide as its longest text, so the target picker after it
## doesn't move when the status changes.
func _fix_status_width() -> void:
	var font: Font = _status.get_theme_font(&"font")
	var font_size: int = _status.get_theme_font_size(&"font_size")
	var widest: float = 0.0
	for text: String in STATUS_TEXTS:
		widest = maxf(widest, font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x)
	var style: StyleBox = _status.get_theme_stylebox(&"normal")
	var pad: float = style.get_margin(SIDE_LEFT) + style.get_margin(SIDE_RIGHT) if style != null else 0.0
	_status.custom_minimum_size = Vector2(ceilf(widest + pad), 0.0)


func _queue_width_sync() -> void:
	if _width_sync_queued:
		return
	_width_sync_queued = true
	_sync_master_width.call_deferred()


## Master's column and the controls above it share one width: a strip's
## full width, or wider if the buttons above need it. Worked out from those
## needs, not Master's current width, so the column can shrink again (e.g.
## after the display scale goes down).
func _sync_master_width() -> void:
	_width_sync_queued = false
	var width: float = maxf(_edit_row.get_combined_minimum_size().x, _noise_row.get_combined_minimum_size().x)
	width = maxf(width, LiveMixerStrip.STRIP_WIDTH * EditorInterface.get_editor_scale())
	if not _strips.is_empty():
		width = maxf(width, _strips[0].get_compact_width())
	_right_top.custom_minimum_size = Vector2(width, 0.0)
	_master_col.custom_minimum_size = Vector2(width, 0.0)
	if not _strips.is_empty():
		_strips[0].set_strip_width(width)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _fx_tab != null:
		_size_fx_tab()
		_fix_status_width.call_deferred()
		# Deferred, so the button has its own theme by then.
		_tighten_fx_toggle.call_deferred()
		_compact_edit_buttons.call_deferred()
		_flush_active_switch.call_deferred()
		_queue_strip_fit()
		_sync_master_spacers.call_deferred()
		_queue_width_sync()


## Just wide enough for the arrow with a little padding either side.
func _size_fx_tab() -> void:
	var font: Font = _fx_tab.get_theme_font(&"font")
	var font_size: int = _fx_tab.get_theme_font_size(&"font_size")
	var pad: float = 3.0 * EditorInterface.get_editor_scale()
	var arrow: Vector2 = font.get_string_size(FX_OPEN_ARROW, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var width: float = ceilf(arrow.x + pad * 2.0)
	_fx_tab.custom_minimum_size = Vector2(width, maxf(_fx_tab.custom_minimum_size.y, ceilf(font.get_height(font_size) + pad * 2.0)))
	_reserve_tab_width.call_deferred()


## The tab's full width (its own padding included) is kept even while it's
## hidden, so neither Master nor the strip area moves when it opens or closes.
func _reserve_tab_width() -> void:
	var width: float = _fx_tab.get_combined_minimum_size().x
	_tab_col.custom_minimum_size = Vector2(width, 0.0)
	_top_tab_spacer.custom_minimum_size = Vector2(width, 0.0)


## Trims the closed "Effects" line's padding top and bottom so it sits
## close under the dB boxes.
func _tighten_fx_toggle() -> void:
	var ui_scale: float = EditorInterface.get_editor_scale()
	for style_name: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled", &"focus"]:
		_fx_toggle.remove_theme_stylebox_override(style_name)
		var style: StyleBox = _fx_toggle.get_theme_stylebox(style_name).duplicate() as StyleBox
		style.content_margin_top = 1.0 * ui_scale
		style.content_margin_bottom = 1.0 * ui_scale
		_fx_toggle.add_theme_stylebox_override(style_name, style)


## Narrower side padding on Discard and Commit, from the theme's own
## styles, so they fit side by side above Master.
func _compact_edit_buttons() -> void:
	var pad: float = COMPACT_PAD * EditorInterface.get_editor_scale()
	for button: Button in [_discard_button, _commit_button]:
		for style_name: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled"]:
			button.remove_theme_stylebox_override(style_name)
			var style: StyleBox = button.get_theme_stylebox(style_name).duplicate() as StyleBox
			style.content_margin_left = pad
			style.content_margin_right = pad
			button.add_theme_stylebox_override(style_name, style)
	_queue_width_sync()


## No left padding on the Active switch, so its text starts at the same edge
## as Reset and the first strip.
func _flush_active_switch() -> void:
	for style_name: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled", &"focus"]:
		_active_switch.remove_theme_stylebox_override(style_name)
		var style: StyleBox = _active_switch.get_theme_stylebox(style_name).duplicate() as StyleBox
		style.content_margin_left = 0.0
		_active_switch.add_theme_stylebox_override(style_name, style)


func _queue_strip_fit() -> void:
	if _strip_fit_queued:
		return
	_strip_fit_queued = true
	_fit_strips.call_deferred()


## Splits the strip area between the buses: full width if they all fit,
## narrower if not, but never narrower than the widest compact strip (so
## every bus stays the same width). Past that, the area scrolls.
func _fit_strips() -> void:
	_strip_fit_queued = false
	var count: int = _strips.size() - 1
	if count <= 0:
		return
	var full: float = LiveMixerStrip.STRIP_WIDTH * EditorInterface.get_editor_scale()
	var compact: float = 0.0
	for i: int in range(1, _strips.size()):
		compact = maxf(compact, _strips[i].get_compact_width())
	var gap: float = float(_strip_row.get_theme_constant(&"separation"))
	var share: float = floorf((_strip_scroll.size.x - gap * float(count - 1)) / float(count))
	var width: float = clampf(share, compact, maxf(full, compact))
	for i: int in range(1, _strips.size()):
		_strips[i].set_strip_width(width)


## The arrow, centred on the first line beside it (the "Effects" line, or
## the lists' first row, which is the same height).
func _draw_fx_tab() -> void:
	var font: Font = _fx_tab.get_theme_font(&"font")
	var font_size: int = _fx_tab.get_theme_font_size(&"font_size")
	var pad: float = 3.0 * EditorInterface.get_editor_scale()
	var color: Color = _fx_tab.get_theme_color(&"font_hover_color" if _fx_tab.is_hovered() else &"font_color")
	var arrow: String = FX_OPEN_ARROW if _fx_toggle.button_pressed else FX_CLOSED_ARROW
	var arrow_width: float = font.get_string_size(arrow, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	var line: float = minf(_fx_tab.size.y, _fx_toggle.get_combined_minimum_size().y)
	var baseline: float = (line - font.get_height(font_size)) * 0.5 + font.get_ascent(font_size)
	_fx_tab.draw_string(font, Vector2((_fx_tab.size.x - arrow_width) * 0.5, baseline), arrow, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)


## Every list gets as many rows as the bus with the most effects.
func _size_effect_rows() -> void:
	var rows: int = 1
	for strip: LiveMixerStrip in _strips:
		rows = maxi(rows, strip.get_effect_count())
	for strip: LiveMixerStrip in _strips:
		strip.set_effect_rows(rows)


func _on_state_received(buses: Array) -> void:
	_last_state = buses
	var names: Array[String] = []
	for bus: Dictionary in buses:
		names.append(str(bus["name"]))
	if names != _bus_names:
		_rebuild_strips(names)
	for i: int in buses.size():
		_strips[i].apply_state(buses[i] as Dictionary)
	_size_effect_rows()
	_sync_master_spacers.call_deferred()
	if not buses.is_empty():
		_loudness.set_master_db(float((buses[0] as Dictionary)["volume_db"]))
	_refresh_edit_tints()


func _on_peaks_received(peaks: PackedFloat32Array) -> void:
	var count: int = mini(_strips.size(), peaks.size() / 2)
	for i: int in count:
		var left: float = peaks[i * 2]
		var right: float = peaks[i * 2 + 1]
		var active: bool = left > SILENT_THRESHOLD_DB or right > SILENT_THRESHOLD_DB
		_strips[i].push_levels(left, right, active)


func _rebuild_strips(names: Array[String]) -> void:
	_bus_names = names
	for strip: LiveMixerStrip in _strips:
		var effects_panel: PanelContainer = strip.get_effects_panel()
		effects_panel.get_parent().remove_child(effects_panel)
		effects_panel.queue_free()
		strip.get_parent().remove_child(strip)
		strip.queue_free()
	_strips.clear()
	# _strips stays in bus order (0 = Master), which is how the game reports
	# them. Master goes in its own pinned column; the rest scroll.
	for bus_name: String in names:
		var strip: LiveMixerStrip = LiveMixerStrip.new()
		strip.edited.connect(_on_strip_edited)
		_strips.append(strip)
	for i: int in range(1, _strips.size()):
		_strip_row.add_child(_strips[i])
		_fx_row.add_child(_strips[i].get_effects_panel())
	if not _strips.is_empty():
		var master: LiveMixerStrip = _strips[0]
		master.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_master_col.add_child(master)
		_master_col.move_child(master, 0)
		var panel: PanelContainer = master.get_effects_panel()
		_master_col.add_child(panel)
		_master_col.move_child(panel, 1)
		master.set_master(true)
	_apply_effects_open()
	_queue_width_sync()
	_queue_strip_fit()
	_update_status()


func _on_strip_edited(bus_name: String, key: String, value: Variant) -> void:
	var index: int = _bus_names.find(bus_name)
	if index < 0:
		return
	if not _originals.has(bus_name):
		_originals[bus_name] = {}
		_current[bus_name] = {}
	var originals: Dictionary = _originals[bus_name]
	var current: Dictionary = _current[bus_name]
	if not originals.has(key):
		originals[key] = _read_game_value(index, key)
	current[key] = value
	if _same_value(originals[key], value):
		originals.erase(key)
		current.erase(key)
		if originals.is_empty():
			_originals.erase(bus_name)
			_current.erase(bus_name)
	_send_value(bus_name, key, value)
	_refresh_edit_tints()
	_update_buttons()


## The value the game last reported for this bus and key, from the
## controls (which mirror the game's state).
func _read_game_value(index: int, key: String) -> Variant:
	var state: Dictionary = _strip_state(index)
	if key.begins_with("fx:"):
		var effects: Array = state["effects"]
		return bool((effects[int(key.trim_prefix("fx:"))] as Array)[1])
	return state[key]


func _strip_state(index: int) -> Dictionary:
	return _last_state[index] if index < _last_state.size() else {}


func _send_value(bus_name: String, key: String, value: Variant) -> void:
	if _debugger == null:
		return
	match key:
		"volume_db":
			_debugger.send("set_volume", [bus_name, value])
		"mute":
			_debugger.send("set_mute", [bus_name, value])
		"solo":
			_debugger.send("set_solo", [bus_name, value])
		"bypass":
			_debugger.send("set_bypass", [bus_name, value])
		_:
			if key.begins_with("fx:"):
				_debugger.send("set_effect_enabled", [bus_name, int(key.trim_prefix("fx:")), value])


func _on_discard_pressed() -> void:
	for bus_name: String in _originals:
		var originals: Dictionary = _originals[bus_name]
		for key: String in originals:
			_send_value(bus_name, key, originals[key])
	_originals.clear()
	_current.clear()
	_refresh_edit_tints()
	_update_buttons()


## Applies the edits to the editor's own AudioServer (which holds the
## layout the stock Audio panel edits), refreshes that panel, and saves
## the layout file.
func _on_commit_pressed() -> void:
	# The setting can hold a uid:// rather than a res:// path.
	var path: String = ResourceUID.ensure_path(str(ProjectSettings.get_setting("audio/buses/default_bus_layout", "res://default_bus_layout.tres")))
	var missing: Array[String] = []
	var applied: int = 0
	for bus_name: String in _current:
		var bus: int = AudioServer.get_bus_index(bus_name)
		if bus < 0:
			missing.append(bus_name)
			continue
		var current: Dictionary = _current[bus_name]
		for key: String in current:
			if _apply_to_editor(bus, key, current[key]):
				applied += 1

	if not missing.is_empty():
		push_error("Live Mixer: the saved layout has no bus called %s, so edits to it weren't committed. Was it added by game code at runtime?" % ", ".join(missing))

	# Re-setting the layout fires bus_layout_changed, which makes the stock
	# Audio panel rebuild and show the new values.
	AudioServer.set_bus_layout(AudioServer.generate_bus_layout())
	var err: Error = ResourceSaver.save(AudioServer.generate_bus_layout(), path)
	if err != OK:
		push_error("Live Mixer: couldn't save %s (%s). Nothing was committed to disk." % [path, error_string(err)])
		return
	EditorInterface.get_resource_filesystem().update_file(path)
	print("Live Mixer: committed %d change(s) to %s." % [applied, path])

	# Committed edits are now the saved values. Edits to missing buses stay
	# pending so they're still visible.
	var kept_originals: Dictionary = {}
	var kept_current: Dictionary = {}
	for bus_name: String in missing:
		kept_originals[bus_name] = _originals.get(bus_name, {})
		kept_current[bus_name] = _current[bus_name]
	_originals = kept_originals
	_current = kept_current
	_refresh_edit_tints()
	_update_buttons()


func _apply_to_editor(bus: int, key: String, value: Variant) -> bool:
	match key:
		"volume_db":
			AudioServer.set_bus_volume_db(bus, float(value))
		"mute":
			AudioServer.set_bus_mute(bus, bool(value))
		"solo":
			AudioServer.set_bus_solo(bus, bool(value))
		"bypass":
			AudioServer.set_bus_bypass_effects(bus, bool(value))
		_:
			if not key.begins_with("fx:"):
				return false
			var effect_index: int = int(key.trim_prefix("fx:"))
			if effect_index >= AudioServer.get_bus_effect_count(bus):
				push_error("Live Mixer: bus '%s' in the saved layout has no effect %d. Skipped." % [AudioServer.get_bus_name(bus), effect_index])
				return false
			AudioServer.set_bus_effect_enabled(bus, effect_index, bool(value))
	return true


func _on_reset_pressed() -> void:
	for strip: LiveMixerStrip in _strips:
		strip.reset_meter()
	_loudness.reset_measurement()


func _refresh_edit_tints() -> void:
	for strip: LiveMixerStrip in _strips:
		var keys: Dictionary = _originals.get(strip.bus_name, {})
		strip.show_edited(keys)


func _edit_count() -> int:
	var count: int = 0
	for bus_name: String in _originals:
		count += (_originals[bus_name] as Dictionary).size()
	return count


func _same_value(a: Variant, b: Variant) -> bool:
	if typeof(a) == TYPE_FLOAT or typeof(b) == TYPE_FLOAT:
		return absf(float(a) - float(b)) < 0.05
	return a == b


func _update_status() -> void:
	if _status == null:
		return
	var running: bool = _debugger != null and _debugger.is_running()
	# A dot and one word; the full story is in the tooltip.
	if _active_switch != null and not _active_switch.button_pressed:
		_set_status("‖ Paused", Color(1.0, 1.0, 1.0, 0.6), "Live Mixer is paused: the game sends nothing and does no extra work.")
	elif running:
		_set_status("● Live", Color(0.45, 0.95, 0.5), "Showing the running game's %d buses. Edits are heard immediately." % _bus_names.size())
	elif _strips.is_empty():
		_set_status("○ Not running", Color(1.0, 1.0, 1.0, 0.6), "Play the game to see its buses.")
	else:
		_set_status("● Stopped", Color(1.0, 0.75, 0.35), "Game stopped. Showing the last run; edits can still be committed.")


func _set_status(text: String, color: Color, tip: String) -> void:
	_status.text = text
	_status.modulate = color
	_status.tooltip_text = tip
	_status.mouse_filter = Control.MOUSE_FILTER_PASS


func _update_buttons() -> void:
	var count: int = _edit_count()
	# The count lives in the tooltips, so Commit keeps one width and the
	# column above Master stays narrow. Edited controls are tinted anyway.
	var changes: String = "%d change%s" % [count, "" if count == 1 else "s"]
	_commit_button.tooltip_text = "Write your edits into the project's bus layout file (%s)." % changes if count > 0 else "Write your edits into the project's bus layout file. Nothing to commit yet."
	_discard_button.tooltip_text = "Put the running game back the way it was before your edits, and forget them (%s)." % changes if count > 0 else "Put the running game back the way it was before your edits. Nothing to discard yet."
	_commit_button.disabled = count == 0
	_discard_button.disabled = count == 0
