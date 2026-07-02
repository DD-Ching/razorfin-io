class_name Fighter
extends CharacterBody2D
## A predator fish — the player and every rival share this. It owns the heavy,
## momentum-based swimming (slow to surge, keeps gliding), a health pool + the boost
## stamina, the growth that drives the whole .io hook (absorb morsels / KO rivals to
## gain MASS, which makes you bigger, tankier and longer-reaching, but slower and
## laggier to turn), the two wounds (bleed / venom), and death that spills most of
## your mass back as loot.
##
## Subclasses only implement `_control(delta)`: set `move_dir` and `boosting`.
## The fish FACES where it swims, and the weapon part follows the facing — so
## steering IS aiming, and the whole game fits one thumb and one button.

signal died(who: Fighter)

const ENV_DRAG := 3.6             ## proportional drag on environmental (current/terrain) velocity
const GHOST_SPEED := 235.0        ## speed above which a motion afterimage is shed
const GHOST_LIFE := 0.26
const PIERCE_KNOCK := 850.0       ## a hit harder than this PIERCES a cushion's protection
const CUSHION_KNOCK_MULT := 0.3   ## fraction of knockback kept while buffered by an air cushion
const TURN_RATE := 7.0            ## rad/s facing turn at mass 1 (scales down as you grow)

var mass := Game.START_MASS
var health := 60.0
var max_health := 60.0
var stamina := Game.STAMINA_MAX
var color := Color("d9c24a")
var display_name := "Fish"
var is_player := false
var stamina_regen_mult := 1.0     ## bots run a mild 1.25 — they manage a real bar, just clumsily
var body_radius := Game.BASE_BODY_RADIUS
var is_king := false              ## wearing the crown (set by Main's leaderboard pass)
var wet := 1.0                    ## steering-speed multiplier from terrain shoals (1 = open water)
var facing := 0.0                 ## which way the fish points — steering IS aiming

var move_dir := Vector2.ZERO      ## set by the subclass each frame
var boosting := false             ## set by the subclass each frame — the ONE button

var _steer := Vector2.ZERO        ## momentum-carrying input velocity
var _impulse := Vector2.ZERO      ## knockback + lunge burst, decays on its own
var _env := Vector2.ZERO          ## velocity from currents + terrain gradient (drag-damped)
var _invuln := 0.0
var _hurt := 0.0
var _cushion := 0.0               ## >0 while sheltered in an air cushion (soft armor)
var _stamina_delay := 0.0
var _dead := false
var _boost_ok := true             ## hysteresis: an empty bar must refill to BOOST_MIN to re-fire
var _bubble_cd := 0.0
var _bleed_t := 0.0               ## the saw's wound — damage over time
var _bleed_dps := 0.0
var _venom_t := 0.0               ## the ray's barb — slow + light damage over time
var _blink := 0.0                 ## >0 while mid-blink — no mechanic, they just blink (可愛)
var _blink_cd := 2.0              ## seconds until the next blink
var _drip_cd := 0.0
var _hitter: Fighter = null       ## who wounded us last (credits a wound-death)
var _last_facing := 0.0
var _ghosts: Array = []           ## recent positions for the speed afterimage
var _wet_drawn := 1.0             ## shoal-drag at last redraw (ripple appears/vanishes)
var _last_health_i := -1          ## quantized health at last redraw (drives the bar)
var _milestone := 0               ## last size-doubling celebrated (player fanfare)
var _name_line: TextLine          ## cached shaped nameplate — re-shaped only when the text changes
var _label_val := -1
var _chime_step := 0              ## the morsel-vacuum pitch ladder
var _chime_time := 0.0

var weapon: Weapon
var _shape: CollisionShape2D
var _circle: CircleShape2D
var _collector: Area2D
var _collector_shape: CollisionShape2D
var _collector_circle: CircleShape2D

func _ready() -> void:
	add_to_group("fighter")
	collision_layer = Game.L_FIGHTER
	# Solid: collide with other fish (no overlap), the reef, and enemy weapon parts (which
	# physically shove us). Our OWN weapon adds a collision exception, so it never blocks us.
	# These solid bounces are where the beloved rebound-acceleration lives — momentum
	# stacking off collisions until you're FLYING is a feature, never to be damped away.
	collision_mask = Game.L_FIGHTER | Game.L_WALL | Game.L_WEAPON_SOLID

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
	_update_ghosts(delta)
	# Redraw only when something VISIBLE changed. The facing epsilon is coarse on purpose
	# (0.045 rad ≈ the silhouette turning ~1px) — a wound tint or bar change always repaints.
	var health_i := int(health)
	if _hurt > 0.0 or _invuln > 0.0 or _ghosts.size() > 0 \
			or _bleed_t > 0.0 or _venom_t > 0.0 \
			or absf(facing - _last_facing) > 0.045 \
			or health_i != _last_health_i or wet != _wet_drawn:
		_last_facing = facing
		_last_health_i = health_i
		queue_redraw()

## Subclass hook: set `move_dir` (unit-ish) and `boosting`.
func _control(_delta: float) -> void:
	pass

func _integrate(delta: float) -> void:
	# The fish turns toward where it's steered — heavier fish turn slower, and the turn
	# is what whips the weapon part (the pendulum follows the facing).
	if move_dir != Vector2.ZERO:
		var turn := TURN_RATE * pow(mass, -0.1)
		facing = lerp_angle(facing, move_dir.angle(), clampf(turn * delta, 0.0, 1.0))
	if weapon:
		weapon.aim_at(facing)

	# Boost: the one button. Stamina is boost fuel and nothing else; an emptied bar
	# must refill a little before it re-fires (no 1-frame stutter-boosts).
	if stamina <= 0.0:
		_boost_ok = false
	elif stamina >= Game.BOOST_MIN:
		_boost_ok = true
	var surging := boosting and _boost_ok and move_dir != Vector2.ZERO
	# STREAMLINED species (劍魚 above all): growing doesn't fatten them into slowness —
	# the mass-speed penalty is softened, so a big one slowly builds to a frightening
	# cruise. The trade: a longer runway (lower accel) and TURNS scrub the speed off —
	# it swims like a lance, not a dancer.
	var stream: float = weapon.streamline() if weapon else 0.0
	var accel := Game.ACCEL * (1.0 - 0.45 * stream)
	# Shoal drag at your fins only (steering) — knockback and currents still carry in
	# full, so ramming a rival ONTO a sandbank remains a legitimate setup. Venom slow
	# works the same way: your muscles are poisoned, physics isn't.
	var spd := Game.BASE_MAX_SPEED * pow(mass, Game.SPEED_MASS_EXP * (1.0 - 0.55 * stream)) * wet
	if _venom_t > 0.0:
		spd *= Game.VENOM_SLOW
	if stream > 0.0 and move_dir != Vector2.ZERO and _steer.length() > 60.0:
		var mis := clampf(absf(_steer.angle_to(move_dir)) / PI, 0.0, 1.0)
		spd *= 1.0 - 0.45 * stream * mis
	if surging:
		stamina = maxf(0.0, stamina - Game.BOOST_DRAIN * delta)
		_stamina_delay = 0.5
		spd *= Game.BOOST_SPEED_MULT * weapon.boost_mult()
		accel *= Game.BOOST_ACCEL_MULT
		_boost_fx(delta)
	if move_dir != Vector2.ZERO:
		_steer = _steer.move_toward(move_dir.limit_length(1.0) * spd, accel * delta)
	else:
		_steer = _steer.move_toward(Vector2.ZERO, Game.FRICTION * delta)
	_impulse = _impulse.move_toward(Vector2.ZERO, Game.KNOCK_FRICTION * delta)
	# Environmental velocity (currents + terrain) bleeds off with proportional drag, so a
	# steady force settles at a sane terminal speed instead of running away.
	_env *= maxf(0.0, 1.0 - ENV_DRAG * delta)
	velocity = _steer + _impulse + _env
	move_and_slide()

## The boost wake: bubbles for everyone — INK for the squid (its whole jet-propulsion bit).
func _boost_fx(delta: float) -> void:
	_bubble_cd -= delta
	if _bubble_cd > 0.0 or Game.fx == null:
		return
	var tail := global_position - Vector2.RIGHT.rotated(facing) * body_radius
	if weapon.type == Weapon.Type.SQUID:
		_bubble_cd = 0.14
		Game.fx.burst(tail, Color(0.10, 0.09, 0.16), 4, 110.0, 4.5)
	else:
		_bubble_cd = 0.09
		Game.fx.burst(tail, Color(0.85, 0.95, 1.0, 0.8), 2, 90.0, 2.2)

## Accumulate an environmental acceleration this frame (currents, terrain gradient).
## Ignored while frozen (dead / picking a species) so it can't pile up and fling us on unfreeze.
func apply_env_force(accel: Vector2, delta: float) -> void:
	if _dead or not is_physics_processing():
		return
	_env += accel * delta

## A counter/cushion zone flings this body's momentum back (reflect), plus a shove out.
func env_reflect(factor: float, outward: Vector2) -> void:
	var v := velocity
	_steer *= -0.3
	_env = Vector2.ZERO
	_impulse = (-v * factor + outward).limit_length(2000.0)

## An air cushion is currently sheltering us — soft armor for a short window.
func mark_cushioned() -> void:
	_cushion = 0.15

## Terrain tells us how draggy the water is each physics frame. Hitting a shoal splashes.
func set_wetness(w: float) -> void:
	if w < 0.99 and wet >= 0.99 and not _dead:
		Sfx.play(&"splash", global_position, -6.0, Game.rng().randf_range(0.9, 1.1))
	wet = w

func _update_ghosts(delta: float) -> void:
	# Only a FAST body sheds afterimages (boost, knockback, rebound momentum) — plain
	# cruising is below the bar, so a wandering fish doesn't force redraws every frame.
	if velocity.length() > maxf(GHOST_SPEED, Game.speed_for_mass(mass) * 1.15):
		_ghosts.push_back({"pos": global_position, "age": 0.0})
	for g in _ghosts:
		g.age += delta
	while _ghosts.size() > 0 and _ghosts[0].age > GHOST_LIFE:
		_ghosts.pop_front()

func _tick(delta: float) -> void:
	if _invuln > 0.0:
		_invuln = maxf(0.0, _invuln - delta)
	if _hurt > 0.0:
		_hurt = maxf(0.0, _hurt - delta)
	if _cushion > 0.0:
		_cushion = maxf(0.0, _cushion - delta)
	if health < max_health:
		health = minf(max_health, health + Game.HEALTH_REGEN * delta)
	if _stamina_delay > 0.0:
		_stamina_delay = maxf(0.0, _stamina_delay - delta)
	elif stamina < Game.STAMINA_MAX:
		stamina = minf(Game.STAMINA_MAX, stamina + Game.STAMINA_REGEN * stamina_regen_mult * delta)
	# The two wounds tick here: no knockback, no i-frames — just the clock running out.
	if _bleed_t > 0.0:
		_bleed_t = maxf(0.0, _bleed_t - delta)
		_drip_cd -= delta
		if _drip_cd <= 0.0 and Game.fx:
			_drip_cd = 0.22
			Game.fx.burst(global_position, Color(0.85, 0.15, 0.12, 0.8), 2, 70.0, 2.6)
		_wound(_bleed_dps * delta)
	if _venom_t > 0.0:
		_venom_t = maxf(0.0, _venom_t - delta)
		_wound(Game.VENOM_DPS * delta)
	# The blink: every few seconds the eyes close for a beat. No mechanic — just alive.
	# Two explicit redraws per blink (close + open); the closed frames repaint nothing.
	_blink_cd -= delta
	if _blink_cd <= 0.0:
		_blink_cd = Game.rng().randf_range(2.2, 5.5)
		_blink = 0.13
		queue_redraw()
	elif _blink > 0.0:
		_blink = maxf(0.0, _blink - delta)
		if _blink == 0.0:
			queue_redraw()
	if _chime_time > 0.0:
		_chime_time = maxf(0.0, _chime_time - delta)
		if _chime_time == 0.0:
			_chime_step = 0   # the morsel-vacuum combo ladder resets when you stop eating

# --- combat ------------------------------------------------------------------------

## Returns true if this hit KILLED the fish (so the attacker can claim the kill).
func take_damage(amount: float, dir: Vector2, knockback: float) -> bool:
	if _dead or _invuln > 0.0:
		return false
	# Soft armor: an air cushion buffers the blow — UNLESS it's hard enough to pierce,
	# in which case the full impact lands.
	if _cushion > 0.0 and knockback < PIERCE_KNOCK:
		knockback *= CUSHION_KNOCK_MULT
		amount *= 0.65
	health -= amount
	_invuln = Game.INVULN
	_hurt = 0.32
	_impulse = (_impulse + dir * knockback).limit_length(1400.0)
	queue_redraw()
	if health <= 0.0:
		_die()
		return true
	return false

## The saw's wound: damage over time, refreshed (not stacked) by re-hits.
func apply_bleed(dps: float, from: Fighter) -> void:
	if _dead:
		return
	_bleed_dps = maxf(dps, _bleed_dps if _bleed_t > 0.0 else 0.0)
	_bleed_t = Game.BLEED_TIME
	_hitter = from

## The ray's barb: slow + light damage over time.
func apply_venom(from: Fighter) -> void:
	if _dead:
		return
	_venom_t = Game.VENOM_TIME
	_hitter = from

## Wound damage (bleed/venom): silent chip that still credits the hunter on a kill.
func _wound(amount: float) -> void:
	if _dead:
		return
	health -= amount
	if health <= 0.0:
		_die()
		if _hitter != null and is_instance_valid(_hitter) and not _hitter._dead:
			_hitter.on_scored_kill(self)

func lunge(v: Vector2) -> void:
	_impulse = (_impulse + v).limit_length(1400.0)

## Grant/extend i-frames (used to shield the player while the species picker is up).
func make_invulnerable(t: float) -> void:
	_invuln = maxf(_invuln, t)

## True if the reef wall is right behind us in the given direction — i.e. we can't be
## knocked back, so a hit lands with extra force (reef-pin). A real physics raycast.
func is_pinned(dir: Vector2) -> bool:
	if dir == Vector2.ZERO:
		return false
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var q := PhysicsRayQueryParameters2D.create(global_position, global_position + dir.normalized() * (body_radius + 26.0))
	q.collision_mask = Game.L_WALL
	return not space.intersect_ray(q).is_empty()

## The collector Area2D touched a loose pickup — eat a morsel to grow, or absorb a
## mutation orb to change species. Guarded so two fish can't both claim the same one.
func _on_pickup_touched(body: Node) -> void:
	if _dead:
		return
	var p := body as Pickup
	if p == null or p.consumed:
		return
	if p.kind == Pickup.Kind.GEM:
		grow(p.value)
		if is_player:
			# The vacuum combo: each morsel within 0.8s rings one semitone higher.
			var pitch := pow(2.0, float(mini(_chime_step, 14)) / 12.0)
			_chime_step += 1
			_chime_time = 0.8
			Sfx.play(&"chime", global_position, -8.0, pitch)
	else:
		weapon.set_type(p.weapon_type)
		Sfx.play(&"chime", global_position, -4.0, 0.65)
		Game.popup(weapon.type_name() + "!", global_position + Vector2(0, -body_radius - 22.0), Color(1, 0.9, 0.5), 1.2)
	p.consume()

func on_hit_feedback(_shake: float, _dir: Vector2, _big: bool) -> void:
	pass   # player overrides to shake the camera

## The hunter just felled `victim` — claim a chunk of its mass outright.
## Felling the CROWN holder pays a bounty (0.5 of their mass instead of 0.4) — a soft
## comeback valve that keeps "kill the king" worth the risk.
func on_scored_kill(victim: Fighter) -> void:
	grow(victim.mass * (0.5 if victim.is_king else Game.KILL_ABSORB))
	Game.feed_event.emit("%s  >  %s" % [display_name, victim.display_name], is_player or victim.is_player)
	if is_player or victim.is_player:
		Sfx.play(&"gong", victim.global_position, 0.0, clampf(1.2 / sqrt(maxf(victim.mass, 0.5)), 0.5, 1.2))
	if is_player:
		Game.hitstop(0.05, 0.08)   # the payoff moment gets a real beat
		Game.popup("KO!", global_position + Vector2(0, -body_radius - 20.0), Color(1.0, 0.85, 0.3), 1.4)
		Game.add_kill()

func grow(amount: float) -> void:
	mass = clampf(mass + amount, Game.START_MASS, Game.MAX_MASS)
	_apply_mass()
	if is_player:
		Game.player_mass = mass
		Game.set_player_score(int(round(mass * 100.0)))
		# Size-doubling fanfare: growth costs double each time, so celebrate each doubling —
		# frequent hooks early, rare punctuation late, can never spam.
		var lvl := int(floor(log(maxf(mass, 1.0)) / log(2.0)))
		if lvl > _milestone:
			_milestone = lvl
			Game.popup("SIZE %d!" % int(round(mass * 100.0)), global_position + Vector2(0, -body_radius - 34.0), Color(1.0, 0.9, 0.4), 1.5)
			Sfx.play(&"fanfare", global_position, -2.0)
			if Game.fx:
				Game.fx.ring(global_position, Color(1.0, 0.88, 0.45))

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

## Place + (re)initialise this fish for a fresh life. Used at spawn and respawn.
func spawn_setup(pos: Vector2, m: float, nm: String, col: Color) -> void:
	position = pos
	display_name = nm
	color = col
	mass = m
	_dead = false
	_steer = Vector2.ZERO
	_impulse = Vector2.ZERO
	_env = Vector2.ZERO
	# Spawn shield: a fresh life can't be shredded the instant it appears in a feeding
	# frenzy. The player's shield cancels early on their first boost (an invulnerable
	# aggressor would be uncounterable).
	_invuln = 1.5 if is_player else 1.0
	_hurt = 0.0
	_cushion = 0.0
	_bleed_t = 0.0
	_venom_t = 0.0
	_blink = 0.0
	_blink_cd = Game.rng().randf_range(0.5, 4.0)   # desync the school's blinks
	_hitter = null
	_boost_ok = true
	boosting = false
	wet = 1.0
	is_king = false
	facing = Game.rng().randf() * TAU
	_ghosts.clear()
	_name_line = null
	_label_val = -1
	_milestone = int(floor(log(maxf(m, 1.0)) / log(2.0)))
	_apply_mass()
	health = max_health
	stamina = Game.STAMINA_MAX
	if is_player:
		Game.player_mass = m
	if weapon:
		weapon.aim_at(facing)
		weapon.reset()
		weapon.set_solid_active(true)
		weapon.set_physics_process(true)          # _die() paused it; bring it back
	show()
	set_physics_process(true)
	if is_player:
		Game.set_player_score(int(round(mass * 100.0)))
	queue_redraw()

func is_dead() -> bool:
	return _dead

## Main's leaderboard pass crowns / uncrowns the ocean's #1.
func set_king(k: bool) -> void:
	if is_king != k:
		is_king = k
		queue_redraw()

func _die() -> void:
	if _dead:
		return
	_dead = true
	if weapon:
		weapon.reset()                   # settle the part so it can't hit while dead
		weapon.set_solid_active(false)   # a corpse's saw shouldn't keep blocking the living
		weapon.set_physics_process(false)
	# The death reads as THIS fish bursting — a cloud in their own color.
	if Game.fx:
		Game.fx.burst(global_position, color, 26, 420.0, 4.0)
	if is_player:
		Sfx.play(&"gong", global_position, 0.0, 0.7)
		Game.hitstop(0.05, 0.12)         # let the death land
	_spill_loot()
	died.emit(self)

func _spill_loot() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var spill := mass * Game.SPILL_FRACTION
	# Fewer, RICHER morsels (each worth ~2 baseline) — and scattered on a ring around the
	# corpse rather than stacked at one point, so the physics solver never sees the
	# N²/2-pair contact island that a same-point pile of RigidBodies creates.
	var count := clampi(int(spill / (Game.GEM_MASS * 2.0)), 3, 24)
	var per := spill / float(count)
	var r := Game.rng()
	for i in range(count):
		var g := Pickup.new()
		scene.add_child(g)
		var a := r.randf() * TAU
		var off := Vector2(cos(a), sin(a)) * (body_radius * 0.6 + r.randf_range(0.0, body_radius * 0.8))
		g.setup(global_position + off, per, Pickup.Kind.GEM, color)
		g.fling(Vector2(cos(a), sin(a)) * r.randf_range(120.0, 340.0))

# --- drawing (placeholder art, in code) --------------------------------------------

func _draw() -> void:
	_wet_drawn = wet
	var col := color
	if _hurt > 0.0:
		col = col.lerp(Color(1, 0.3, 0.3), clampf(_hurt / 0.32, 0.0, 1.0))
	if _venom_t > 0.0:
		col = col.lerp(Color(0.45, 0.9, 0.35), 0.35)   # poisoned flesh reads green
	if _invuln > 0.0 and int(_invuln * 30.0) % 2 == 0:
		col = col.darkened(0.25)
	# Shoal ripple — the visual half of the sandbank slow (the feel half is the splash).
	if wet < 0.99:
		draw_arc(Vector2.ZERO, body_radius + 5.0, 0.0, TAU, 24, Color(0.85, 0.92, 1.0, 0.4), 2.0)
		draw_arc(Vector2.ZERO, body_radius + 10.0, 0.0, TAU, 24, Color(0.85, 0.92, 1.0, 0.18), 2.0)
	# Speed afterimage — fading ghosts trailing a fast mover.
	for g in _ghosts:
		var ga: float = (1.0 - float(g.age) / GHOST_LIFE) * 0.32
		draw_circle(to_local(g.pos), body_radius * 0.92, Color(color.r, color.g, color.b, ga))
	_draw_fish(col)

	# Health bar (only when hurt) — a thin bar above the body.
	if health < max_health - 0.5:
		var w := body_radius * 1.8
		var y := -body_radius - 12.0
		draw_rect(Rect2(-w * 0.5, y, w, 5.0), Color(0, 0, 0, 0.5))
		var frac := clampf(health / max_health, 0.0, 1.0)
		draw_rect(Rect2(-w * 0.5, y, w * frac, 5.0), Color(0.4, 0.85, 0.4).lerp(Color(0.9, 0.4, 0.3), 1.0 - frac))

	# The crown — the ocean's #1 wears it, everyone hunts it.
	if is_king:
		var cy := -body_radius - 26.0
		var cw := 11.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(-cw, cy), Vector2(-cw, cy - 9.0), Vector2(-cw * 0.5, cy - 4.0),
			Vector2(0, cy - 11.0), Vector2(cw * 0.5, cy - 4.0), Vector2(cw, cy - 9.0),
			Vector2(cw, cy),
		]), Color(1.0, 0.85, 0.25))

	# Nameplate: shaped ONCE per label change (TextLine cache), tinted by the food chain —
	# red will hunt you, green will flee you, white is an even fight. The tint uses the
	# bots' own decision thresholds, so the color IS their intent.
	var val := int(round(mass * 100.0))
	if _name_line == null or val != _label_val:
		_label_val = val
		_name_line = TextLine.new()
		_name_line.add_string("%s  %d" % [display_name, val], ThemeDB.fallback_font, 15)
	var tint := Color(1, 1, 1, 0.9)
	if is_player:
		tint = Color(1, 0.92, 0.6, 0.95)
	else:
		var ratio := mass / maxf(Game.player_mass, 0.01)
		if ratio > 1.18:
			tint = Color(1.0, 0.55, 0.5, 0.95)
		elif ratio < 0.92:
			tint = Color(0.6, 0.95, 0.6, 0.9)
	var ts := _name_line.get_size()
	var tpos := Vector2(-ts.x * 0.5, body_radius + 8.0)
	_name_line.draw(get_canvas_item(), tpos + Vector2(1.5, 1.5), Color(0, 0, 0, 0.6))
	_name_line.draw(get_canvas_item(), tpos, tint)

# --- the fish silhouettes (top-down, nose = facing) ---------------------------------

## Unit-space point (nose at +X) → local space: rotated to the facing, scaled to size.
func _pt(x: float, y: float) -> Vector2:
	return Vector2(x, y).rotated(facing) * body_radius

func _poly(unit_pts: Array, col: Color) -> void:
	var pts := PackedVector2Array()
	for p in unit_pts:
		pts.push_back(_pt(p.x, p.y))
	draw_colored_polygon(pts, col)
	pts.push_back(pts[0])
	draw_polyline(pts, col.darkened(0.4), 2.0)

func _draw_fish(col: Color) -> void:
	var sp: int = weapon.type if weapon else Weapon.Type.HAMMERHEAD
	match sp:
		Weapon.Type.STINGRAY:
			_draw_ray_body(col)
		Weapon.Type.SQUID:
			_draw_squid_body(col)
		_:
			_draw_shark_body(col, sp)

## The shark plan: torpedo body + pectoral fins + two-lobed tail. Hammerhead's eyes
## live on its hammer (the weapon draws them); the others get eyes here.
func _draw_shark_body(col: Color, sp: int) -> void:
	# Tail fin first (under the body).
	_poly([Vector2(-0.85, 0.0), Vector2(-1.45, -0.55), Vector2(-1.2, 0.0), Vector2(-1.45, 0.55)], col.darkened(0.18))
	# Pectoral fins sweeping back.
	_poly([Vector2(0.25, -0.35), Vector2(-0.45, -1.05), Vector2(-0.35, -0.3)], col.darkened(0.12))
	_poly([Vector2(0.25, 0.35), Vector2(-0.45, 1.05), Vector2(-0.35, 0.3)], col.darkened(0.12))
	# The body.
	_poly([Vector2(1.1, 0.0), Vector2(0.6, -0.42), Vector2(0.05, -0.58), Vector2(-0.6, -0.38),
		Vector2(-0.95, -0.12), Vector2(-0.95, 0.12), Vector2(-0.6, 0.38), Vector2(0.05, 0.58),
		Vector2(0.6, 0.42)], col)
	if sp != Weapon.Type.HAMMERHEAD:
		for s in [-1.0, 1.0]:
			_draw_eye(_pt(0.62, s * 0.28), body_radius * 0.13)

## The ray plan: swept wings — a convex leading edge, a concave trailing edge — so it
## reads as a gliding ray, not a square. The tail is the weapon, drawn behind.
func _draw_ray_body(col: Color) -> void:
	_poly([Vector2(1.05, 0.0), Vector2(0.5, -0.42), Vector2(0.0, -1.35), Vector2(-0.3, -0.6),
		Vector2(-0.55, -0.25), Vector2(-0.72, 0.0), Vector2(-0.55, 0.25), Vector2(-0.3, 0.6),
		Vector2(0.0, 1.35), Vector2(0.5, 0.42)], col)
	# The ocellated wing spots — the ray's signature, one per wing.
	for s in [-1.0, 1.0]:
		draw_circle(_pt(-0.02, s * 0.55), body_radius * 0.19, col.darkened(0.35))
	for s in [-1.0, 1.0]:
		_draw_eye(_pt(0.55, s * 0.2), body_radius * 0.12)

## The squid plan: mantle cone pointing BACK, big eyes up front, fins at the rear —
## the tentacle club out front is the weapon.
func _draw_squid_body(col: Color) -> void:
	# Rear fins.
	_poly([Vector2(-0.75, 0.0), Vector2(-1.5, -0.6), Vector2(-1.35, 0.0), Vector2(-1.5, 0.6)], col.darkened(0.15))
	# The mantle.
	_poly([Vector2(0.5, -0.5), Vector2(0.72, 0.0), Vector2(0.5, 0.5), Vector2(-1.35, 0.14),
		Vector2(-1.45, 0.0), Vector2(-1.35, -0.14)], col)
	# The famous giant eyes.
	for s in [-1.0, 1.0]:
		_draw_eye(_pt(0.45, s * 0.3), body_radius * 0.16)

## One eye, top-down — a white ball with a forward-looking pupil (readable + cute);
## every few seconds it closes into a soft line. Blink.
func _draw_eye(p: Vector2, r: float) -> void:
	if _blink > 0.0:
		var d := Vector2.RIGHT.rotated(facing) * r * 1.5
		draw_line(p - d, p + d, Color(0.12, 0.1, 0.12), maxf(2.0, r * 0.6))
	else:
		draw_circle(p, r * 1.45, Color(0.97, 0.96, 0.9))
		draw_circle(p + Vector2.RIGHT.rotated(facing) * r * 0.35, r * 0.8, Color(0.09, 0.09, 0.12))
