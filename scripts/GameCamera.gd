class_name GameCamera
extends Camera2D
## Follows the player (it's parented to them), shakes on impact, and — the .io touch —
## zooms OUT as the player grows, so your ever-bigger stone always stays on screen.

var _shake := 0.0
var _kick := Vector2.ZERO
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	make_current()
	position_smoothing_enabled = true
	position_smoothing_speed = 9.0
	var half := Game.ARENA_SIZE * 0.5
	var pad := Game.WALL_THICK
	limit_left = int(-half.x - pad)
	limit_right = int(half.x + pad)
	limit_top = int(-half.y - pad)
	limit_bottom = int(half.y + pad)
	_rng.randomize()

func add_shake(amount: float, dir := Vector2.ZERO) -> void:
	_shake = minf(_shake + amount, 60.0)
	if dir != Vector2.ZERO:
		_kick += dir * amount * 0.35

func kick(amount: float) -> void:
	_shake = minf(_shake + amount, 80.0)

func _process(delta: float) -> void:
	var f := get_parent() as Fighter
	if f:
		var z := clampf(pow(f.mass, -0.13), 0.52, 1.0)
		zoom = zoom.lerp(Vector2(z, z), clampf(3.0 * delta, 0.0, 1.0))
	_shake = maxf(0.0, _shake - 70.0 * delta)
	_kick = _kick.move_toward(Vector2.ZERO, 420.0 * delta)
	var off := _kick
	if _shake > 0.5:
		off += Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * _shake
	offset = off
