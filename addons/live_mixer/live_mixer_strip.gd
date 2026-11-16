@tool
extends PanelContainer
## One channel strip in the Live Mixer: name, mute / solo / bypass, send,
## meter, fader and dB field, on a faint card so strips read as columns.
##
## The fader takes its scale from the meter (see live_mixer_fader.gd), so a
## handle at 0 dB lines up with the meter's 0 tick. The dB field is a plain
## text field: type a value and press Enter (or click away); anything that
## isn't a number puts the old value back.
##
## The bus's effect list is a separate control, get_effects_panel(), which
## the dock places in its shared Effects row under all the strips, so one
## accordion opens or closes every bus's effects together. The two are kept
## the same width so they line up.
##
## Sizes are given at 100% and multiplied by the editor's display scale, so
## the strip keeps its proportions on high-DPI screens.
##
## WIDTH: the dock sets it (set_strip_width()), from STRIP_WIDTH down to
## get_compact_width() when the dock is narrow. The controls stay left-aligned
## with each other as one block, and that block is centred on the card. The
## bus name and send line start at the block's left edge but may use the
## card's spare room to the right, and end in "…" when even that's too short.
##
## Emits edited() when the user changes something. Incoming state from the
## game updates the controls without emitting, and is skipped for the fader
## while it's being dragged, so the game's echo can't fight the mouse.

signal edited(bus_name: String, key: String, value: Variant)

const LiveMixerMeter: GDScript = preload("live_mixer_meter.gd")
const LiveMixerFader: GDScript = preload("live_mixer_fader.gd")

const BOX_MIN_DB: float = -80.0
const BOX_MAX_DB: float = 24.0
const COLOR_EDITED: Color = Color(1.0, 0.75, 0.3)
const STRIP_WIDTH: float = 132.0
## The longest text the dB box can show; it's sized to fit exactly this.
const DB_BOX_WIDEST: String = "-80.0 dB"
## Mute / solo / bypass letters, as a share of the editor's font size. Smaller
## letters make smaller squares and a shorter row.
const TOGGLE_FONT_SCALE: float = 0.8
## Gap between the three squares, at 100% display scale.
const TOGGLE_GAP: float = 4.0
## Bus send line, as a share of the editor's font size.
const SEND_FONT_SCALE: float = 0.85
const CARD_COLOR: Color = Color(1.0, 1.0, 1.0, 0.04)
## Master gets a cool tint so it stands apart from the other buses.
const MASTER_CARD_COLOR: Color = Color(0.55, 0.7, 1.0, 0.08)
## Card padding and corner radius, at 100% display scale.
const CARD_MARGIN: float = 6.0
const CARD_RADIUS: float = 4.0
## Fallback if the editor theme has no dark inset colour.
const EFFECTS_BACKGROUND: Color = Color(0.0, 0.0, 0.0, 0.25)

var bus_name: String = ""

var _name_label: Label = null
var _send_label: Label = null
var _meter: Control = null
var _fader: Control = null
var _db_box: LineEdit = null
## The value the dB field last showed, put back if the user types junk.
var _db_value: float = 0.0
var _card: StyleBoxFlat = null
var _mute: Button = null
var _solo: Button = null
var _bypass: Button = null
var _effects_panel: PanelContainer = null
var _effects_box: VBoxContainer = null
## One style shared by every effect checkbox: no padding but a hair top and
## bottom, so rows sit tight like the stock Audio panel's.
var _compact_style: StyleBoxEmpty = null
var _effect_names: Array[String] = []
var _effect_rows: int = 1
## Holds the column; its left margin centres the block on the card.
var _inset: MarginContainer = null
var _toggles: HBoxContainer = null
var _meter_row: HBoxContainer = null
var _strip_width: float = 0.0


func _init() -> void:
	var ui_scale: float = EditorInterface.get_editor_scale()
	_strip_width = STRIP_WIDTH * ui_scale
	custom_minimum_size = Vector2(_strip_width, 0.0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_card = StyleBoxFlat.new()
	_card.bg_color = CARD_COLOR
	_card.set_corner_radius_all(int(round(CARD_RADIUS * ui_scale)))
	_card.set_content_margin_all(CARD_MARGIN * ui_scale)
	add_theme_stylebox_override(&"panel", _card)
	_compact_style = StyleBoxEmpty.new()
	_compact_style.content_margin_left = 2.0 * ui_scale
	_compact_style.content_margin_right = 2.0 * ui_scale
	_compact_style.content_margin_top = 1.0 * ui_scale
	_compact_style.content_margin_bottom = 1.0 * ui_scale
	_build()
	_build_effects_panel()
	resized.connect(_sync_effects_width)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _mute != null:
		# Deferred: the buttons get their own theme update after this one,
		# and measuring before that sizes them for the wrong font.
		_square_toggles.call_deferred()
		_fit_db_box.call_deferred()
		_style_labels.call_deferred()
		_centre_block.call_deferred()
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_effects_panel):
		# The effects panel lives in the dock's Effects row, not under this
		# strip, so it isn't freed with it.
		_effects_panel.queue_free()


func _build() -> void:
	_inset = MarginContainer.new()
	for side: StringName in [&"margin_left", &"margin_top", &"margin_right", &"margin_bottom"]:
		_inset.add_theme_constant_override(side, 0)
	add_child(_inset)
	var column: VBoxContainer = VBoxContainer.new()
	_inset.add_child(column)

	# Name, mute / solo / bypass and send packed together with no spacing,
	# so the top of the strip stays compact. The rest keeps normal spacing.
	var top: VBoxContainer = VBoxContainer.new()
	top.add_theme_constant_override(&"separation", 0)
	column.add_child(top)

	# No padding on the labels, so the name, the buttons and the send line
	# all start at the same left edge.
	var flush: StyleBoxEmpty = StyleBoxEmpty.new()

	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_name_label.clip_text = true
	_name_label.add_theme_stylebox_override(&"normal", flush)
	_name_label.resized.connect(_fit_label.bind(_name_label))
	top.add_child(_name_label)

	# Mute / solo / bypass straight under the name, as in the stock Audio
	# panel and Fairlight.
	var toggles: HBoxContainer = HBoxContainer.new()
	_toggles = toggles
	toggles.alignment = BoxContainer.ALIGNMENT_BEGIN
	toggles.add_theme_constant_override(&"separation", int(round(TOGGLE_GAP * EditorInterface.get_editor_scale())))
	top.add_child(toggles)
	_mute = _make_toggle("M", "Mute", "mute", toggles)
	_solo = _make_toggle("S", "Solo", "solo", toggles)
	_bypass = _make_toggle("B", "Bypass effects", "bypass", toggles)

	_send_label = Label.new()
	_send_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_send_label.modulate = Color(1.0, 1.0, 1.0, 0.5)
	_send_label.clip_text = true
	_send_label.add_theme_stylebox_override(&"normal", flush)
	_send_label.resized.connect(_fit_label.bind(_send_label))
	top.add_child(_send_label)

	var row: HBoxContainer = HBoxContainer.new()
	_meter_row = row
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	column.add_child(row)

	_meter = LiveMixerMeter.new() as Control
	row.add_child(_meter)

	_fader = LiveMixerFader.new() as Control
	_fader.set(&"meter", _meter)
	_fader.connect(&"value_changed", _on_fader_changed)
	row.add_child(_fader)

	_db_box = LineEdit.new()
	_db_box.select_all_on_focus = true
	_db_box.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_db_box.tooltip_text = "Bus volume in dB (%d to +%d). Type a value and press Enter." % [int(BOX_MIN_DB), int(BOX_MAX_DB)]
	_db_box.text_submitted.connect(func(_text: String) -> void: _db_box.release_focus())
	_db_box.focus_exited.connect(_on_box_committed)
	column.add_child(_db_box)
	_show_db(0.0)


## Bold bus name (if the editor has a bold font) and a smaller send line.
func _style_labels() -> void:
	var editor_theme: Theme = EditorInterface.get_editor_theme()
	if editor_theme.has_font(&"bold", &"EditorFonts"):
		_name_label.add_theme_font_override(&"font", editor_theme.get_font(&"bold", &"EditorFonts"))
	_send_label.remove_theme_font_size_override(&"font_size")
	var base_size: int = _send_label.get_theme_font_size(&"font_size")
	_send_label.add_theme_font_size_override(&"font_size", maxi(1, int(round(base_size * SEND_FONT_SCALE))))
	# New fonts, new widths.
	_fit_label(_name_label)
	_fit_label(_send_label)


## The narrowest the strip can be: its card padding plus the block of
## controls (the bus name and send line can shorten with "…").
func get_compact_width() -> float:
	var card: float = _card.get_margin(SIDE_LEFT) + _card.get_margin(SIDE_RIGHT)
	return ceilf(card + _block_width())


## The dock's chosen width (never below get_compact_width()).
func set_strip_width(width: float) -> void:
	_strip_width = maxf(width, get_compact_width())
	custom_minimum_size = Vector2(_strip_width, 0.0)
	_centre_block()


func _block_width() -> float:
	return maxf(_meter_row.get_combined_minimum_size().x, maxf(_toggles.get_combined_minimum_size().x, _db_box.get_combined_minimum_size().x))


## Worked out from the chosen width, never from the strip's current size, so
## the margin can't hold the strip wider than the dock asks for.
func _centre_block() -> void:
	var card: float = _card.get_margin(SIDE_LEFT) + _card.get_margin(SIDE_RIGHT)
	var spare: float = maxf(0.0, _strip_width - card - _block_width())
	_inset.add_theme_constant_override(&"margin_left", int(floor(spare * 0.5)))


## Master's card is tinted so the main output is easy to find.
func set_master(is_master: bool) -> void:
	_card.bg_color = MASTER_CARD_COLOR if is_master else CARD_COLOR


## A darker inset, like the stock Audio panel's effect list, the same width
## as the strip so the dock's Effects row lines up under the strips.
func _build_effects_panel() -> void:
	var ui_scale: float = EditorInterface.get_editor_scale()
	var editor_theme: Theme = EditorInterface.get_editor_theme()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = editor_theme.get_color(&"dark_color_2", &"Editor") if editor_theme.has_color(&"dark_color_2", &"Editor") else EFFECTS_BACKGROUND
	style.set_corner_radius_all(int(round(3.0 * ui_scale)))
	style.set_content_margin_all(3.0 * ui_scale)

	_effects_panel = PanelContainer.new()
	_effects_panel.add_theme_stylebox_override(&"panel", style)
	_effects_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_effects_panel.theme_changed.connect(_size_effects_list)
	_effects_box = VBoxContainer.new()
	_effects_box.add_theme_constant_override(&"separation", 0)
	_effects_panel.add_child(_effects_box)


## Keeps the effects panel exactly as wide as the strip, which can grow past
## STRIP_WIDTH (a wide dB box at some display scales), so columns stay lined
## up.
func _sync_effects_width() -> void:
	_effects_panel.custom_minimum_size.x = size.x


## The dock puts this in its shared Effects row.
func get_effects_panel() -> PanelContainer:
	return _effects_panel


func get_effect_count() -> int:
	return _effect_names.size()


## Every strip gets the same number of rows (the most any bus has), so the
## Effects row is even and nothing in it scrolls.
func set_effect_rows(rows: int) -> void:
	_effect_rows = maxi(rows, 1)
	_size_effects_list()


## Names are shortened by _fit_effect_name(), not by the CheckBox's own
## text_overrun_behavior: in 4.7 a ticked CheckBox clips its "…" away, so
## long names on ticked effects just stopped mid-word.
func _make_effect_box(text: String) -> CheckBox:
	var box: CheckBox = CheckBox.new()
	box.text = text
	box.clip_text = true
	for style_name: StringName in [&"normal", &"pressed", &"hover", &"hover_pressed", &"disabled", &"focus"]:
		box.add_theme_stylebox_override(style_name, _compact_style)
	return box


## The bus name or send line in full if it fits, otherwise as much as fits
## plus "…". Done here rather than with the Label's own text_overrun_behavior,
## which in 4.7 sometimes just clips the text with no "…" (seen with a bold
## name a little too long for a narrow strip).
func _fit_label(label: Label) -> void:
	var full: String = str(label.get_meta(&"full_text", label.text))
	label.text = _shorten(full, label.get_theme_font(&"font"), label.get_theme_font_size(&"font_size"), label.size.x)


## As much of full as fits room, plus "…"; full itself if it fits.
func _shorten(full: String, font: Font, font_size: int, room: float) -> String:
	if room <= 0.0 or font.get_string_size(full, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= room:
		return full
	var shown: String = full
	while shown.length() > 1:
		shown = shown.left(shown.length() - 1)
		if font.get_string_size(shown + "…", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= room:
			break
	return shown + "…"


## Shows full_name if it fits the row, otherwise as much as fits plus "…".
func _fit_effect_name(box: CheckBox, full_name: String) -> void:
	var font: Font = box.get_theme_font(&"font")
	var font_size: int = box.get_theme_font_size(&"font_size")
	var icon: Texture2D = box.get_theme_icon(&"checked")
	var icon_width: float = icon.get_width() if icon != null else 0.0
	var room: float = box.size.x - _compact_style.content_margin_left - _compact_style.content_margin_right - icon_width - box.get_theme_constant(&"h_separation")
	if font.get_string_size(full_name, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= room:
		box.text = full_name
		return
	var shown: String = full_name
	while shown.length() > 1:
		shown = shown.left(shown.length() - 1)
		if font.get_string_size(shown + "…", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= room:
			break
	box.text = shown + "…"


## Room for _effect_rows rows, measured from a real row so it's right at any
## display scale.
func _size_effects_list() -> void:
	if not _effects_panel.is_inside_tree():
		return
	var probe: CheckBox = _make_effect_box("Ag")
	_effects_box.add_child(probe)
	var row_height: float = probe.get_combined_minimum_size().y
	_effects_box.remove_child(probe)
	probe.free()
	_effects_box.custom_minimum_size = Vector2(0.0, ceilf(row_height * _effect_rows))


## Mute / solo / bypass as identical squares: a smaller font and trimmed
## padding keep the row short, and all three take the size of the widest
## letter (M), so they match without a fixed border.
func _square_toggles() -> void:
	var ui_scale: float = EditorInterface.get_editor_scale()
	var side: float = 0.0
	for button: Button in [_mute, _solo, _bypass]:
		button.remove_theme_font_size_override(&"font_size")
		var base_size: int = button.get_theme_font_size(&"font_size")
		button.add_theme_font_size_override(&"font_size", maxi(1, int(round(base_size * TOGGLE_FONT_SCALE))))
		for style_name: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled", &"focus"]:
			button.remove_theme_stylebox_override(style_name)
			var style: StyleBox = button.get_theme_stylebox(style_name).duplicate() as StyleBox
			style.set_content_margin_all(1.0 * ui_scale)
			button.add_theme_stylebox_override(style_name, style)
		button.custom_minimum_size = Vector2.ZERO
		var natural: Vector2 = button.get_minimum_size()
		side = maxf(side, maxf(natural.x, natural.y))
	for button: Button in [_mute, _solo, _bypass]:
		button.custom_minimum_size = Vector2(side, side)


## Just wide enough for DB_BOX_WIDEST in the field's own font and padding.
func _fit_db_box() -> void:
	var ui_scale: float = EditorInterface.get_editor_scale()
	var edit: LineEdit = _db_box
	# Trim the field's side padding, which is most of its width otherwise.
	for style_name: StringName in [&"normal", &"focus", &"read_only"]:
		edit.remove_theme_stylebox_override(style_name)
		var trimmed: StyleBox = edit.get_theme_stylebox(style_name).duplicate() as StyleBox
		trimmed.content_margin_left = 3.0 * ui_scale
		trimmed.content_margin_right = 3.0 * ui_scale
		edit.add_theme_stylebox_override(style_name, trimmed)
	var font: Font = edit.get_theme_font(&"font")
	var font_size: int = edit.get_theme_font_size(&"font_size")
	var style: StyleBox = edit.get_theme_stylebox(&"normal")
	var text_width: float = font.get_string_size(DB_BOX_WIDEST, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	var padding: float = style.get_margin(SIDE_LEFT) + style.get_margin(SIDE_RIGHT)
	edit.custom_minimum_size = Vector2(ceilf(text_width + padding + 2.0 * ui_scale), 0.0)
	_db_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN


func _show_db(db: float) -> void:
	_db_value = db
	_db_box.text = "%.1f dB" % db


## Reads the typed value when the field loses focus (Enter releases focus).
## Accepts "−6", "-6 dB", "-6db", "+3"; anything else restores the old value.
func _on_box_committed() -> void:
	var typed: String = _db_box.text.strip_edges().to_lower().replace("db", "").strip_edges().replace("−", "-")
	if not typed.is_valid_float():
		_show_db(_db_value)
		return
	var db: float = clampf(snappedf(typed.to_float(), 0.1), BOX_MIN_DB, BOX_MAX_DB)
	var changed: bool = not is_equal_approx(db, _db_value)
	_show_db(db)
	if changed:
		_fader.call(&"set_value_no_signal", db)
		edited.emit(bus_name, "volume_db", db)


func _make_toggle(text: String, tip: String, key: String, parent: Container) -> Button:
	var button: Button = Button.new()
	button.text = text
	button.tooltip_text = tip
	button.toggle_mode = true
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.toggled.connect(func(on: bool) -> void: edited.emit(bus_name, key, on))
	parent.add_child(button)
	return button


## Brings the controls in line with the game's state for this bus.
func apply_state(bus: Dictionary) -> void:
	bus_name = str(bus["name"])
	_name_label.set_meta(&"full_text", bus_name)
	_fit_label(_name_label)
	_name_label.tooltip_text = bus_name
	var send: String = str(bus["send"])
	_send_label.set_meta(&"full_text", ("→ " + send) if send != "" else "")
	_fit_label(_send_label)

	var volume_db: float = float(bus["volume_db"])
	if not bool(_fader.call(&"is_dragging")):
		_fader.call(&"set_value_no_signal", volume_db)
	if not _db_box.has_focus():
		_show_db(volume_db)

	_mute.set_pressed_no_signal(bool(bus["mute"]))
	_solo.set_pressed_no_signal(bool(bus["solo"]))
	_bypass.set_pressed_no_signal(bool(bus["bypass"]))

	var effects: Array = bus["effects"]
	var names: Array[String] = []
	for effect: Array in effects:
		names.append(str(effect[0]))
	if names != _effect_names:
		_rebuild_effects(names)
	for i: int in effects.size():
		var box: CheckBox = _effects_box.get_child(i) as CheckBox
		box.set_pressed_no_signal(bool((effects[i] as Array)[1]))


func _rebuild_effects(names: Array[String]) -> void:
	_effect_names = names
	for child: Node in _effects_box.get_children():
		_effects_box.remove_child(child)
		child.queue_free()
	for i: int in names.size():
		var box: CheckBox = _make_effect_box(names[i])
		box.tooltip_text = "%s: turn it on or off in the running game." % names[i]
		box.resized.connect(_fit_effect_name.bind(box, names[i]))
		box.toggled.connect(func(on: bool) -> void: edited.emit(bus_name, "fx:%d" % i, on))
		_effects_box.add_child(box)


func push_levels(left_db: float, right_db: float, active: bool) -> void:
	_meter.call("push_levels", left_db, right_db, active)


func reset_meter() -> void:
	_meter.call("reset")


## Tints the controls whose values differ from the saved layout, so it's
## clear what Commit will write.
func show_edited(keys: Dictionary) -> void:
	_tint(_fader, keys.has("volume_db"))
	_tint(_db_box, keys.has("volume_db"))
	_tint(_mute, keys.has("mute"))
	_tint(_solo, keys.has("solo"))
	_tint(_bypass, keys.has("bypass"))
	for i: int in _effects_box.get_child_count():
		_tint(_effects_box.get_child(i) as Control, keys.has("fx:%d" % i))


func _tint(control: Control, edited_now: bool) -> void:
	control.modulate = COLOR_EDITED if edited_now else Color.WHITE


func _on_fader_changed(value: float) -> void:
	if not _db_box.has_focus():
		_show_db(value)
	edited.emit(bus_name, "volume_db", value)
