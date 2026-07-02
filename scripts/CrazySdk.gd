extends Node
## CrazyGames SDK bridge (autoloaded as "CrazySdk"). Fires the platform's required
## loading / gameplay events when the game runs inside CrazyGames — the "Web-CrazyGames"
## export preset injects the SDK script plus a tiny `window.cgEvent(name)` shim that
## queues calls until the SDK finishes initialising. Everywhere else (our GitHub Pages
## build, desktop, headless) the shim doesn't exist and every call is a silent no-op.

var _web := false
var _was_picking := true   ## the species picker is the "menu"; leaving it = gameplay starts

func _ready() -> void:
	_web = OS.has_feature("web")
	# The respawn loop: death is a gameplay break, respawning resumes it.
	Game.player_spawned.connect(func(): event("gameplayStart"))
	Game.player_died.connect(func(_s, _r): event("gameplayStop"))
	# The engine is up and the first frame is about to draw — loading is over.
	call_deferred("event", "loadingStop")

func _process(_delta: float) -> void:
	if not _web:
		return
	# Gameplay starts the moment the start-of-run species picker closes (on touch there
	# is no picker, so this fires on the first frame).
	if _was_picking and not Game.picking:
		_was_picking = false
		event("gameplayStart")
	elif Game.picking:
		_was_picking = true

func event(name: String) -> void:
	if _web:
		JavaScriptBridge.eval("window.cgEvent && window.cgEvent('%s')" % name, true)
