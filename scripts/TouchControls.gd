class_name TouchControls
extends Control
## On-screen controls so the game is fully playable on a phone (landscape) — and as
## SIMPLE as the game itself: the RIGHT half of the screen is a dynamic steering stick
## (touch anywhere, drag to swim), and holding ANYWHERE on the LEFT half is the BOOST.
## Right thumb steers, left thumb accelerates — two thumbs, zero buttons to find.
## Multi-touch is tracked by finger index so both thumbs work at once. Hidden on
## desktop; shown when a touchscreen is present (or with ?touch=1 for testing).

const STICK_RADIUS := 96.0

var enabled := false
var move_vec := Vector2.ZERO
var boost_held := false

var _tapped := false

var _move_touch := -1
var _move_origin := Vector2.ZERO
var _move_pos := Vector2.ZERO
var _boost_touch := -1
var _boost_pos := Vector2.ZERO

var _font: Font
var _labels := {}        ## label -> cached TextLine (shaped once, drawn forever)
var _redraw_once := true ## one redraw queued by a press/release while both thumbs are idle

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("touch_controls")
	_font = ThemeDB.fallback_font
	enabled = _detect_touch()
	visible = enabled
	set_process_input(enabled)
	set_process(enabled)

## Show the on-screen controls only on genuine TOUCH-FIRST devices (phones/tablets), never
## on a desktop that merely has a touchscreen + mouse. On the web that's the `(pointer: coarse)`
## media query (true for phones, false for a mouse-driven laptop) plus a `?touch=1` override
## for testing; on native we require an actual mobile OS.
func _detect_touch() -> bool:
	if OS.has_feature("web"):
		var force = JavaScriptBridge.eval("(new URLSearchParams(location.search).get('touch')==='1')?1:0", true)
		if force != null and int(force) == 1:
			return true
		var coarse = JavaScriptBridge.eval("(window.matchMedia && matchMedia('(pointer: coarse)').matches)?1:0", true)
		return coarse != null and int(coarse) == 1
	return DisplayServer.is_touchscreen_available() and (OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios"))

## One-shot "screen was tapped" — used by the respawn prompt. Flushed on death.
func consume_tap() -> bool:
	var t := _tapped
	_tapped = false
	return t

func _process(_delta: float) -> void:
	# Redraw while a thumb is down (the stick/boost ring track it); when idle the hint
	# labels are a static image — one final redraw after the last release, then nothing.
	if _move_touch != -1 or _boost_touch != -1 or _redraw_once:
		_redraw_once = false
		queue_redraw()

func _input(event: InputEvent) -> void:
	if not enabled:
		return
	var vp := get_viewport_rect().size
	if event is InputEventScreenTouch:
		_redraw_once = true   # a press/release always repaints once
		var pos: Vector2 = event.position
		if event.pressed:
			_tapped = true
			if pos.x >= vp.x * 0.5 and _move_touch == -1:
				_move_touch = event.index
				_move_origin = pos
				_move_pos = pos
			elif pos.x < vp.x * 0.5 and _boost_touch == -1:
				_boost_touch = event.index
				_boost_pos = pos
				boost_held = true
		else:
			if event.index == _move_touch:
				_move_touch = -1
				move_vec = Vector2.ZERO
			elif event.index == _boost_touch:
				_boost_touch = -1
				boost_held = false
	elif event is InputEventScreenDrag:
		if event.index == _move_touch:
			_move_pos = event.position
			move_vec = ((_move_pos - _move_origin) / STICK_RADIUS).limit_length(1.0)
		elif event.index == _boost_touch:
			_boost_pos = event.position

func _draw() -> void:
	if not enabled:
		return
	var vp := get_viewport_rect().size
	# The steering stick (only while held).
	if _move_touch != -1:
		_draw_stick(_move_origin, _move_pos, Color(0.6, 0.85, 1.0))
	# The boost ring under the left thumb.
	if _boost_touch != -1:
		draw_circle(_boost_pos, 52.0, Color(1.0, 0.75, 0.35, 0.25))
		draw_arc(_boost_pos, 52.0, 0.0, TAU, 32, Color(1.0, 0.75, 0.35, 0.9), 5.0)
	# Idle hints so a new player knows the halves.
	_hint("BOOST", Vector2(vp.x * 0.14, vp.y - 40.0), _boost_touch != -1)
	_hint("STEER", Vector2(vp.x * 0.86, vp.y - 40.0), _move_touch != -1)

func _draw_stick(origin: Vector2, pos: Vector2, col: Color) -> void:
	draw_arc(origin, STICK_RADIUS, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.35), 4.0)
	draw_circle(origin, STICK_RADIUS, Color(1, 1, 1, 0.04))
	var knob := origin + (pos - origin).limit_length(STICK_RADIUS)
	draw_circle(knob, 34.0, Color(col.r, col.g, col.b, 0.5))
	draw_arc(knob, 34.0, 0.0, TAU, 24, Color(col.r, col.g, col.b, 0.9), 3.0)

func _hint(label: String, center: Vector2, held: bool) -> void:
	if _font == null:
		return
	var tl: TextLine = _labels.get(label)
	if tl == null:
		tl = TextLine.new()
		tl.add_string(label, _font, 15)
		_labels[label] = tl
	var s := tl.get_size()
	tl.draw(get_canvas_item(), center - s * 0.5, Color(1, 1, 1, 0.85 if held else 0.35))
