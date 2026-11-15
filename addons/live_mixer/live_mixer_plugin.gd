@tool
extends EditorPlugin
## Live Mixer: an audio mixer dock that meters and edits the running
## game's buses, which the stock Audio panel can't do because the game runs
## in its own process with its own AudioServer.
##
## Enabling the plugin adds the LiveMixerBridge autoload (the game side).
## Disabling it removes the autoload again.

const AUTOLOAD_NAME: String = "LiveMixerBridge"
const LiveMixerDebugger: GDScript = preload("live_mixer_debugger.gd")
const LiveMixerPanel: GDScript = preload("live_mixer_panel.gd")

var _debugger: LiveMixerDebugger = null
var _dock: LiveMixerPanel = null


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, _bridge_path())


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)


func _enter_tree() -> void:
	_debugger = LiveMixerDebugger.new()
	add_debugger_plugin(_debugger)
	_dock = LiveMixerPanel.new()
	_dock.setup(_debugger)
	add_dock(_dock)


func _exit_tree() -> void:
	if _dock != null:
		remove_dock(_dock)
		_dock.queue_free()
		_dock = null
	if _debugger != null:
		remove_debugger_plugin(_debugger)
		_debugger = null


func _bridge_path() -> String:
	var script: Script = get_script() as Script
	return script.resource_path.get_base_dir().path_join("live_mixer_bridge.gd")
