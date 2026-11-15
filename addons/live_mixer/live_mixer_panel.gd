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
## Nothing forces the dock's size: the strips scroll both ways when they
## don't fit, and the header and loudness rows wrap onto more lines when
## the dock is narrow.
##
## EFFECTS: one accordion opens or closes every bus's effect list together.
## Closed, it's a slim "▾ Effects" line tucked under the dB boxes. Open, the
## lists sit under their strips with a narrow tab at their left holding just
## "▴", which closes it again, so the open state spends no height on a title
## row. The strips row starts with a gap the tab's width so each list stays
## under its strip. Each list is as tall as the bus with the
## most effects needs, so nothing in it scrolls. Remembered per project.
##
## Strips sit on faint cards. Master is last, at the far right after a gap,
## with a tinted card, like the master section of a desk.
##
## Edits survive the game stopping, so you can tune, quit, then Commit.
## Starting a new run drops any edits that weren't committed, with a
## warning in the Output panel.

const LiveMixerStrip: GDScript = preload("live_mixer_strip.gd")
const LiveMixerDebugger: GDScript = preload("live_mixer_debugger.gd")
const LiveMixerLoudnessBar: GDScript = preload("live_mixer_loudness_bar.gd")

const SILENT_THRESHOLD_DB: float = -199.0
## Shown on the open Effects tab; the closed line reads "▾ Effects".
const FX_OPEN_ARROW: String = "▴"
## Space between the last bus and Master, at 100% display scale.
const MASTER_GAP: float = 10.0

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
## The sideways tab shown at the left of the open Effects lists.
var _fx_tab: Button = null
var _fx_open_box: HBoxContainer = null
## Matches the tab's width at the start of the strips row.
var _strip_spacer: Control = null
## Gaps before Master, which sits at the far right as on a mixing desk. One in
## the strips row and one in the Effects row, so the columns stay lined up.
var _master_gap: Control = null
var _master_gap_fx: Control = null


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
	var column: VBoxContainer = VBoxContainer.new()
	add_child(column)

	# Wraps instead of forcing the dock wide.
	var header: HFlowContainer = HFlowContainer.new()
	column.add_child(header)

	_active_switch = CheckButton.new()
	_active_switch.text = "Active"
	_active_switch.button_pressed = true
	_active_switch.tooltip_text = "Off: the running game stops metering and sending audio to the editor, at no per-frame cost (e.g. while profiling). Remembered for future runs."
	_active_switch.toggled.connect(_on_active_toggled)
	header.add_child(_active_switch)

	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_status)

	var clips_button: Button = Button.new()
	clips_button.text = "Reset clips"
	clips_button.tooltip_text = "Clear every bus's clip light and peak hold."
	clips_button.pressed.connect(_on_reset_clips_pressed)
	header.add_child(clips_button)

	_discard_button = Button.new()
	_discard_button.text = "Discard"
	_discard_button.tooltip_text = "Put the running game back the way it was before your edits, and forget them."
	_discard_button.pressed.connect(_on_discard_pressed)
	header.add_child(_discard_button)

	_commit_button = Button.new()
	_commit_button.tooltip_text = "Write your edits into the project's bus layout file."
	_commit_button.pressed.connect(_on_commit_pressed)
	header.add_child(_commit_button)

	_loudness = LiveMixerLoudnessBar.new()
	column.add_child(_loudness)

	_paused_note = Label.new()
	_paused_note.text = "Paused. The game isn't metering or sending anything. Switch Active on to resume."
	_paused_note.modulate = Color(1.0, 1.0, 1.0, 0.6)
	_paused_note.visible = false
	column.add_child(_paused_note)

	# Scrolls both ways, like the stock Audio panel, instead of forcing a
	# minimum size on the dock.
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_scroll)

	var content: VBoxContainer = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# No gap between the strips and the Effects row below them.
	content.add_theme_constant_override(&"separation", 0)
	_scroll.add_child(content)

	_strip_row = HBoxContainer.new()
	_strip_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_strip_row)
	_strip_spacer = Control.new()
	_strip_row.add_child(_strip_spacer)

	# Closed: one slim line. Its pressed state is the accordion's state.
	_fx_toggle = Button.new()
	_fx_toggle.flat = true
	_fx_toggle.toggle_mode = true
	_fx_toggle.button_pressed = true
	_fx_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_fx_toggle.text = "▾ Effects"
	_fx_toggle.tooltip_text = "Show every bus's effects."
	_fx_toggle.toggled.connect(_on_effects_toggled)
	content.add_child(_fx_toggle)

	# Open: the sideways tab, then the lists.
	_fx_open_box = HBoxContainer.new()
	content.add_child(_fx_open_box)
	_fx_tab = Button.new()
	_fx_tab.flat = true
	_fx_tab.tooltip_text = "Hide every bus's effects."
	_fx_tab.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_fx_tab.size_flags_vertical = Control.SIZE_FILL
	_fx_tab.pressed.connect(func() -> void: _fx_toggle.button_pressed = false)
	_fx_tab.draw.connect(_draw_fx_tab)
	_fx_tab.resized.connect(func() -> void: _strip_spacer.custom_minimum_size = Vector2(_fx_tab.size.x, 0.0))
	_fx_tab.mouse_entered.connect(_fx_tab.queue_redraw)
	_fx_tab.mouse_exited.connect(_fx_tab.queue_redraw)
	_fx_open_box.add_child(_fx_tab)
	_fx_row = HBoxContainer.new()
	_fx_open_box.add_child(_fx_row)

	var gap: Vector2 = Vector2(MASTER_GAP * EditorInterface.get_editor_scale(), 0.0)
	_master_gap = Control.new()
	_master_gap.custom_minimum_size = gap
	_master_gap_fx = Control.new()
	_master_gap_fx.custom_minimum_size = gap

	_update_buttons()


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
	_scroll.visible = on
	_loudness.visible = on
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
	_fx_toggle.visible = not open


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# The gaps are only in the tree while there are buses to separate.
		for gap: Control in [_master_gap, _master_gap_fx]:
			if is_instance_valid(gap) and gap.get_parent() == null:
				gap.free()
	if what == NOTIFICATION_THEME_CHANGED and _fx_tab != null:
		_size_fx_tab()
		# Deferred, so the button has its own theme by then.
		_tighten_fx_toggle.call_deferred()


## Just wide enough for "▴" with a little padding either side.
func _size_fx_tab() -> void:
	var font: Font = _fx_tab.get_theme_font(&"font")
	var font_size: int = _fx_tab.get_theme_font_size(&"font_size")
	var pad: float = 3.0 * EditorInterface.get_editor_scale()
	var arrow: Vector2 = font.get_string_size(FX_OPEN_ARROW, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var width: float = ceilf(arrow.x + pad * 2.0)
	_fx_tab.custom_minimum_size = Vector2(width, ceilf(font.get_height(font_size) + pad * 2.0))
	_sync_strip_spacer.call_deferred()


## The gap at the start of the strips row matches the tab's real width (its
## own padding included), so every list sits exactly under its strip.
func _sync_strip_spacer() -> void:
	_strip_spacer.custom_minimum_size = Vector2(_fx_tab.get_combined_minimum_size().x, 0.0)


## Trims the closed "▾ Effects" line's padding top and bottom so it sits
## close under the dB boxes.
func _tighten_fx_toggle() -> void:
	var ui_scale: float = EditorInterface.get_editor_scale()
	for style_name: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled", &"focus"]:
		_fx_toggle.remove_theme_stylebox_override(style_name)
		var style: StyleBox = _fx_toggle.get_theme_stylebox(style_name).duplicate() as StyleBox
		style.content_margin_top = 1.0 * ui_scale
		style.content_margin_bottom = 1.0 * ui_scale
		_fx_toggle.add_theme_stylebox_override(style_name, style)


## "▴" at the top of the tab.
func _draw_fx_tab() -> void:
	var font: Font = _fx_tab.get_theme_font(&"font")
	var font_size: int = _fx_tab.get_theme_font_size(&"font_size")
	var pad: float = 3.0 * EditorInterface.get_editor_scale()
	var color: Color = _fx_tab.get_theme_color(&"font_hover_color" if _fx_tab.is_hovered() else &"font_color")
	var arrow_width: float = font.get_string_size(FX_OPEN_ARROW, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	_fx_tab.draw_string(font, Vector2((_fx_tab.size.x - arrow_width) * 0.5, pad + font.get_ascent(font_size)), FX_OPEN_ARROW, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)


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
		_fx_row.remove_child(effects_panel)
		effects_panel.queue_free()
		_strip_row.remove_child(strip)
		strip.queue_free()
	_strips.clear()
	if _master_gap.get_parent() != null:
		_strip_row.remove_child(_master_gap)
		_fx_row.remove_child(_master_gap_fx)
	# _strips stays in bus order (0 = Master), which is how the game reports
	# them; only the children are reordered, putting Master last.
	for bus_name: String in names:
		var strip: LiveMixerStrip = LiveMixerStrip.new()
		strip.edited.connect(_on_strip_edited)
		_strips.append(strip)
	for i: int in range(1, _strips.size()):
		_strip_row.add_child(_strips[i])
		_fx_row.add_child(_strips[i].get_effects_panel())
	if not _strips.is_empty():
		if _strips.size() > 1:
			_strip_row.add_child(_master_gap)
			_fx_row.add_child(_master_gap_fx)
		_strip_row.add_child(_strips[0])
		_fx_row.add_child(_strips[0].get_effects_panel())
		_strips[0].set_master(true)
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


func _on_reset_clips_pressed() -> void:
	for strip: LiveMixerStrip in _strips:
		strip.reset_meter()


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
	_commit_button.text = "Commit (%d)" % count if count > 0 else "Commit"
	_commit_button.disabled = count == 0
	_discard_button.disabled = count == 0
