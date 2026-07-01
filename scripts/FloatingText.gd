class_name FloatingText
extends Node2D
## A tiny self-drawing, self-freeing pop label ("SMASH!", "+3", "KO!") that floats
## up and fades. Built entirely in code so the project runs from a clean checkout
## with no font/scene imports.

var _text := ""
var _color := Color.WHITE
var _scale := 1.0
var _age := 0.0
var _life := 0.9
var _vel := Vector2(0.0, -46.0)
var _font: Font

func setup(text: String, color: Color, scale := 1.0) -> void:
	_text = text
	_color = color
	_scale = scale
	z_index = 100
	_font = ThemeDB.fallback_font
	queue_redraw()

func _process(delta: float) -> void:
	_age += delta
	position += _vel * delta
	_vel.y += 40.0 * delta   # ease the rise
	if _age >= _life:
		queue_free()
	else:
		queue_redraw()

func _draw() -> void:
	if _font == null:
		return
	var t := clampf(_age / _life, 0.0, 1.0)
	var a := 1.0 - t * t
	var size := int(round(22.0 * _scale))
	var width := _font.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var origin := Vector2(-width * 0.5, 0.0)
	# Cheap outline for readability over any background.
	draw_string(_font, origin + Vector2(1.5, 1.5), _text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.6 * a))
	draw_string(_font, origin, _text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(_color.r, _color.g, _color.b, a))
