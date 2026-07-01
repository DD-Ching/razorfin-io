class_name Fighter
extends CharacterBody2D
## A combatant body — the player and every rival bot share this. It owns Arthur's
## heavy, momentum-based movement (slow to start, keeps drifting), a health + stamina
## pool, the growth that drives the whole Snake.io hook (absorb gems / KO rivals to
## gain MASS, which makes you bigger, tankier and reach further, but slower and
## laggier to swing), and death that spills most of your mass back as loot.
##
## Subclasses only implement `_control(delta)`: set `move_dir` and drive `weapon`.
## Everything physical happens here so the two control schemes scale identically.

signal died(who: Fighter)

var mass := Game.START_MASS
var health := 60.0
var max_health := 60.0
var stamina := Game.STAMINA_MAX
var color := Color("d9c24a")
var display_name := "Knight"
var is_player := false
var uses_stamina := true
var body_radius := Game.BASE_BODY_RADIUS

var move_dir := Vector2.ZERO      ## set by the subclass each frame

var _steer := Vector2.ZERO        ## momentum-carrying input velocity
var _impulse := Vector2.ZERO      ## knockback + swing-lunge burst, decays on its own
var _invuln := 0.0
var _hurt := 0.0
var _stamina_delay := 0.0
var _dead := false
var _last_aim := 0.0

var weapon: Weapon
var _shape: CollisionShape2D
var _circle: CircleShape2D
var _collector: Area2D
var _collector_shape: CollisionShape2D
var _collector_circle: CircleShape2D

func _ready() -> void:
	add_to_group("fighter")
	collision_layer = Game.L_FIGHTER
	collision_mask = Game.L_WALL            # slide on walls only; fighters pass through each other

	_circle = CircleShape2D.new()
	_shape = CollisionShape2D.new()
	_shape.shape = _circle
	add_child(_shape)

	_collector_circle = CircleShape2D.new()
	_collector = Area2D.new()
	_collector.collision_layer = 0
	_collector.collision_mask = Game.L_PICKUP
	_collector.monitoring = true
	_collector_shape = CollisionShape2D.new()
	_collector_shape.shape = _collector_circle
	_collector.add_child(_collector_shape)
	add_child(_collector)
	_collector.body_entered.connect(_on_pickup_touched)

	weapon = Weapon.new()
	add_child(weapon)

	max_health = Game.health_for_mass(mass)
	health = max_health
	stamina = Game.STAMINA_MAX
	_apply_mass()

func _physics_process(delta: float) -> void:
	if _dead:
		return
	_control(delta)
	_integrate(delta)
	_tick(delta)
	if _hurt > 0.0 or _invuln > 0.0 or absf(weapon.aim_angle - _last_aim) > 0.01:
		_last_aim = weapon.aim_angle
		queue_redraw()

## Subclass hook: set `move_dir` (unit-ish) and drive `weapon`.
func _control(_delta: float) -> void:
	pass

func _integrate(delta: float) -> void:
	var spd := Game.speed_for_mass(mass) * _weapon_speed_mult()
	if move_dir != Vector2.ZERO:
		_steer = _steer.move_toward(move_dir.limit_length(1.0) * spd, Game.ACCEL * delta)
	else:
		_steer = _steer.move_toward(Vector2.ZERO, Game.FRICTION * delta)
	_impulse = _impulse.move_toward(Vector2.ZERO, Game.KNOCK_FRICTION * delta)
	velocity = _steer + _impulse
	move_and_slide()

## While the weapon is committed you are far less mobile — the cost of power.
func _weapon_speed_mult() -> float:
	match weapon.state:
		Weapon.State.SLAM:
			return 0.4
		Weapon.State.SPIN:
			return 0.78
		_:
			return 1.0

func _tick(delta: float) -> void:
	if _invuln > 0.0:
		_invuln = maxf(0.0, _invuln - delta)
	if _hurt > 0.0:
		_hurt = maxf(0.0, _hurt - delta)
	if health < max_health:
		health = minf(max_health, health + Game.HEALTH_REGEN * delta)
	if _stamina_delay > 0.0:
		_stamina_delay = maxf(0.0, _stamina_delay - delta)
	elif stamina < Game.STAMINA_MAX:
		stamina = minf(Game.STAMINA_MAX, stamina + Game.STAMINA_REGEN * delta)

# --- combat ------------------------------------------------------------------------

## Returns true if this hit KILLED the fighter (so the attacker can claim the kill).
func take_damage(amount: float, dir: Vector2, knockback: float) -> bool:
	if _dead or _invuln > 0.0:
		return false
	health -= amount
	_invuln = Game.INVULN
	_hurt = 0.32
	_impulse = (_impulse + dir * knockback).limit_length(1400.0)
	queue_redraw()
	if health <= 0.0:
		_die()
		return true
	return false

func lunge(v: Vector2) -> void:
	_impulse = (_impulse + v).limit_length(1400.0)

func try_spend_stamina(cost: float) -> bool:
	if not uses_stamina:
		return true
	if stamina < cost:
		return false
	stamina -= cost
	_stamina_delay = 0.5
	return true

func on_too_tired() -> void:
	pass   # overridable feedback hook

## The collector Area2D touched a loose pickup — eat a gem to grow, or grab a crate
## to swap weapon head. Guarded so two fighters can't both claim the same gem.
func _on_pickup_touched(body: Node) -> void:
	if _dead:
		return
	var p := body as Pickup
	if p == null or p.consumed:
		return
	if p.kind == Pickup.Kind.GEM:
		grow(p.value)
	else:
		weapon.set_type(p.weapon_type)
		Game.popup(weapon.type_name() + "!", global_position + Vector2(0, -body_radius - 22.0), Color(1, 0.9, 0.5), 1.2)
	p.consume()

func on_hit_feedback(_shake: float, _dir: Vector2, _big: bool) -> void:
	pass   # player overrides to shake the camera

## The wielder just felled `victim` — claim a chunk of its mass outright.
func on_scored_kill(victim: Fighter) -> void:
	grow(victim.mass * Game.KILL_ABSORB)
	Game.popup("KO!", global_position + Vector2(0, -body_radius - 20.0), Color(1.0, 0.85, 0.3), 1.4)
	if is_player:
		Game.add_kill()

func grow(amount: float) -> void:
	mass = clampf(mass + amount, Game.START_MASS, Game.MAX_MASS)
	_apply_mass()
	if is_player:
		Game.set_player_score(int(round(mass * 100.0)))

## Re-derive body size, reach, health cap and collector range from the current mass.
func _apply_mass() -> void:
	body_radius = Game.body_radius_for_mass(mass)
	_circle.radius = body_radius
	_collector_circle.radius = body_radius + 34.0
	var ratio := 1.0 if max_health <= 0.0 else clampf(health / max_health, 0.0, 1.0)
	max_health = Game.health_for_mass(mass)
	health = max_health * ratio if not is_equal_approx(ratio, 1.0) else max_health
	if weapon:
		weapon.refresh_scale(mass)
	queue_redraw()

## Place + (re)initialise this fighter for a fresh life. Used at spawn and respawn.
func spawn_setup(pos: Vector2, m: float, nm: String, col: Color) -> void:
	position = pos
	display_name = nm
	color = col
	mass = m
	_dead = false
	_steer = Vector2.ZERO
	_impulse = Vector2.ZERO
	_invuln = 0.0
	_hurt = 0.0
	_apply_mass()
	health = max_health
	stamina = Game.STAMINA_MAX
	if weapon:
		if is_player:
			weapon.set_type(Weapon.Type.STONE)   # every life starts fresh with the boulder
		weapon.reset()
		weapon.set_physics_process(true)          # _die() paused it; bring it back
	show()
	set_physics_process(true)
	if is_player:
		Game.set_player_score(int(round(mass * 100.0)))
	queue_redraw()

func is_dead() -> bool:
	return _dead

func _die() -> void:
	if _dead:
		return
	_dead = true
	if weapon:
		weapon.reset()                   # settle it out of SPIN/SWING so it can't hit while dead
		weapon.set_physics_process(false)
	_spill_loot()
	died.emit(self)

func _spill_loot() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var spill := mass * Game.SPILL_FRACTION
	var count := clampi(int(spill / Game.GEM_MASS), 3, 40)
	var per := spill / float(count)
	var r := Game.rng()
	for i in range(count):
		var g := Pickup.new()
		scene.add_child(g)
		g.setup(global_position, per, Pickup.Kind.GEM, color)
		var a := r.randf() * TAU
		g.fling(Vector2(cos(a), sin(a)) * r.randf_range(120.0, 340.0))

# --- drawing (placeholder art, in code) --------------------------------------------

func _draw() -> void:
	var col := color
	if _hurt > 0.0:
		col = col.lerp(Color(1, 0.3, 0.3), clampf(_hurt / 0.32, 0.0, 1.0))
	if _invuln > 0.0 and int(_invuln * 30.0) % 2 == 0:
		col = col.darkened(0.25)
	draw_circle(Vector2.ZERO, body_radius, col)
	draw_arc(Vector2.ZERO, body_radius, 0.0, TAU, 26, col.darkened(0.4), 3.0)
	# Facing dot toward the aim.
	var face := Vector2.RIGHT.rotated(weapon.aim_angle) * body_radius * 0.55 if weapon else Vector2.ZERO
	draw_circle(face, body_radius * 0.28, Color(0.15, 0.13, 0.12))

	# Health bar (only when hurt) — a thin bar above the body.
	if health < max_health - 0.5:
		var w := body_radius * 1.8
		var y := -body_radius - 12.0
		draw_rect(Rect2(-w * 0.5, y, w, 5.0), Color(0, 0, 0, 0.5))
		var frac := clampf(health / max_health, 0.0, 1.0)
		draw_rect(Rect2(-w * 0.5, y, w * frac, 5.0), Color(0.4, 0.85, 0.4).lerp(Color(0.9, 0.4, 0.3), 1.0 - frac))

	# Name + size, agar.io-style.
	var font := ThemeDB.fallback_font
	if font:
		var label := "%s  %d" % [display_name, int(round(mass * 100.0))]
		var fs := 15
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos := Vector2(-tw * 0.5, body_radius + 20.0)
		draw_string(font, pos + Vector2(1, 1), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.6))
		draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.9))
