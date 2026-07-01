class_name Bot
extends Fighter
## A rival knight. Simple, readable .io behaviour that produces the food-chain tension:
## HUNT anyone smaller, FLEE anyone bigger, and WANDER toward loose gems otherwise.
## It "swings" exactly like the player does — by rotating where it aims, which whips
## the pendulum head up to speed — so no bot uses a special combat path.

enum Mode { WANDER, HUNT, FLEE }

const SIGHT := 640.0
const FEAR := 460.0
const WHIRL_SPEED := 7.5     ## rad/s the aim is rotated while attacking (whips the head)
const GEM_SIGHT := 560.0

var _mode: int = Mode.WANDER
var _target: Fighter
var _think_cd := 0.0
var _wander_dir := Vector2.RIGHT
var _spin_sign := 1.0
var _aim := 0.0

func _ready() -> void:
	uses_stamina = false   # bots have the stamina to keep the pressure on; skill is the player's edge
	super._ready()
	_aim = Game.rng().randf() * TAU
	_spin_sign = 1.0 if Game.rng().randf() < 0.5 else -1.0
	_wander_dir = Vector2.RIGHT.rotated(Game.rng().randf() * TAU)

func _control(delta: float) -> void:
	_think_cd -= delta
	if _think_cd <= 0.0:
		_rethink()
		_think_cd = Game.rng().randf_range(0.25, 0.5)

	match _mode:
		Mode.HUNT:
			_do_hunt(delta)
		Mode.FLEE:
			_do_flee(delta)
		_:
			_do_wander(delta)

func _rethink() -> void:
	_target = null
	var threat: Fighter = null
	var threat_d := FEAR
	var prey: Fighter = null
	var prey_d := SIGHT
	for other in get_tree().get_nodes_in_group("fighter"):
		if other == self or not is_instance_valid(other):
			continue
		var f := other as Fighter
		if f == null or f._dead:
			continue
		var d := global_position.distance_to(f.global_position)
		if f.mass > mass * 1.18 and d < threat_d:
			threat = f
			threat_d = d
		elif f.mass < mass * 0.92 and d < prey_d:
			prey = f
			prey_d = d
	if threat != null:
		_mode = Mode.FLEE
		_target = threat
	elif prey != null:
		_mode = Mode.HUNT
		_target = prey
	else:
		_mode = Mode.WANDER
		if Game.rng().randf() < 0.5:
			_wander_dir = Vector2.RIGHT.rotated(Game.rng().randf() * TAU)

func _target_gone() -> bool:
	return _target == null or not is_instance_valid(_target) or _target._dead

func _do_hunt(delta: float) -> void:
	weapon.set_spin(false)   # hunting whips via aim-rotation, never the whirl — clear any leftover SPIN
	if _target_gone():
		_mode = Mode.WANDER
		weapon.set_swinging(false)
		return
	var to := _target.global_position - global_position
	var d := to.length()
	var strike := weapon.reach() + _target.body_radius + 44.0
	if d <= strike:
		# In range: whirl the head by rotating the aim, and shove in.
		_aim += _spin_sign * WHIRL_SPEED * delta
		weapon.aim_at(_aim)
		weapon.set_swinging(true)
		move_dir = to.normalized() * 0.5
	else:
		weapon.set_swinging(false)
		weapon.aim_at(to.angle())
		_aim = to.angle()
		move_dir = to.normalized()

func _do_flee(delta: float) -> void:
	if _target_gone():
		_mode = Mode.WANDER
		weapon.set_spin(false)   # don't leave the whirl running when the threat vanishes at close range
		return
	var away := (global_position - _target.global_position)
	move_dir = away.normalized()
	# Whirl defensively if the bigger fighter is right on top of us.
	if away.length() < weapon.reach() + _target.body_radius + 30.0:
		_aim += _spin_sign * WHIRL_SPEED * delta
		weapon.aim_at(_aim)
		weapon.set_spin(true)
	else:
		weapon.set_spin(false)
		weapon.aim_at(away.angle())

func _do_wander(delta: float) -> void:
	weapon.set_swinging(false)
	weapon.set_spin(false)
	# Drift toward the nearest loose gem so a wandering bot still grows.
	var gem := _nearest_gem()
	if gem != null:
		var to: Vector2 = gem.global_position - global_position
		move_dir = to.normalized()
		weapon.aim_at(to.angle())
	else:
		move_dir = _wander_dir
		_aim += delta * 0.6
		weapon.aim_at(_aim)

func _nearest_gem() -> Node2D:
	var best: Node2D = null
	var best_d := GEM_SIGHT
	for p in get_tree().get_nodes_in_group("pickup"):
		if not is_instance_valid(p):
			continue
		var n := p as Node2D
		var d := global_position.distance_to(n.global_position)
		if d < best_d:
			best = n
			best_d = d
	return best
