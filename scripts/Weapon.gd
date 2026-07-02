class_name Weapon
extends Node2D
## The species' natural WEAPON — the body part that hurts. This is the game's core
## feel, inherited from the stone-pendulum ancestor: the part is a spring-damped
## pendulum that FOLLOWS the fish's facing with weight and lag (never snapping), so
## TURNING fast whips it up to real speed, and ramming carries your whole swim speed
## into it. How hard a hit lands is read straight off the part's measured speed at
## contact — brushing past only shoves, a boosted ram or a whipped tail wounds.
##
## One rule, five species: damage is WHERE you touch. The weapon part hurts; the body
## only pushes. Every species is this same pendulum with different weight/anchor:
##   HAMMERHEAD (錘頭鯊) — the wide hammer head: heavy, huge knockback.
##   SAWFISH (鋸鰩)      — the long toothed saw: reach, opens BLEEDING wounds.
##   SWORDFISH (劍魚)    — the rigid bill: only the tip, but it lands like a lance.
##   STINGRAY (魟魚)     — the tail whip, anchored BEHIND: sharp turns crack it, VENOM.
##   SQUID (大王魷魚)    — the tentacle club: balanced, loose and heavy.
##
## Built entirely in code (its Area2D hitbox is spawned in _ready), so an entity is
## just "attach Weapon as a child of a Fighter" with no scene wiring.

enum Type { HAMMERHEAD, SAWFISH, SWORDFISH, STINGRAY, SQUID }
enum State { IDLE, SWING }

# Per-species multipliers on the shared base feel. Keys: dmg, knock, reach, head,
# stiff (spring), damp, drag, avel (angular-speed cap), boost (species top-speed factor).
# "mass" is the part's relative weight: it drives knockback/momentum, inverse whip
# agility, and clash exchanges. "anchor" is +1 (front of the fish) or -1 (the tail).
const TYPES := {
	# The hammer head: heaviest — huge damage + knockback, slow to whip. Wins straight rams.
	Type.HAMMERHEAD: {"dmg": 1.45, "knock": 2.0,  "reach": 0.8,  "head": 1.3,  "stiff": 1.1,  "damp": 1.25, "drag": 0.9,  "avel": 0.75, "mass": 1.0,  "boost": 0.95, "anchor": 1, "name": "HAMMERHEAD"},
	# The saw: long and toothed — every pass opens a BLEED. Wins drive-bys and grazes.
	Type.SAWFISH:    {"dmg": 1.1,  "knock": 0.7,  "reach": 1.35, "head": 0.75, "stiff": 1.25, "damp": 0.9,  "drag": 1.25, "avel": 1.35, "mass": 0.5,  "boost": 1.0,  "anchor": 1, "name": "SAWFISH"},
	# The bill: a rigid lance — almost weightless, only the TIP hurts, but it hurts.
	# Fastest boost in the ocean: the jouster.
	Type.SWORDFISH:  {"dmg": 2.3,  "knock": 0.5,  "reach": 1.7,  "head": 0.5,  "stiff": 1.7,  "damp": 1.15, "drag": 1.3,  "avel": 1.6,  "mass": 0.25, "boost": 1.3,  "anchor": 1, "name": "SWORDFISH"},
	# The tail whip, anchored BEHIND: loose, fast, cracked by sharp turns. VENOM slows prey.
	Type.STINGRAY:   {"dmg": 1.55, "knock": 0.95, "reach": 1.35, "head": 0.6,  "stiff": 0.5,  "damp": 0.5,  "drag": 1.6,  "avel": 1.8,  "mass": 0.4,  "boost": 1.05, "anchor": -1, "name": "STINGRAY"},
	# The tentacle club: balanced and sloshy — the all-rounder (and it inks when it jets).
	Type.SQUID:      {"dmg": 1.0,  "knock": 1.0,  "reach": 1.05, "head": 0.95, "stiff": 1.0,  "damp": 1.0,  "drag": 1.0,  "avel": 1.2,  "mass": 0.7,  "boost": 1.0,  "anchor": 1, "name": "SQUID"},
}

# Shared base feel (before per-species + per-mass scaling).
const FOLLOW_STIFFNESS := 12.0
const REST_DAMPING := 4.6
const MAX_AVEL := 26.0
const DRAG_GAIN := 5.0         ## how strongly TURNING (facing drag) whips the part
const INERTIA_GAIN := 1.0
const HEAD_RADIUS_BASE := 22.0
const PICKUP_FLING := 2.4      ## impulse multiplier when the part bats a loose morsel
const CLASH_SPEED := 620.0     ## combined part speed above which two weapons CLASH and bounce apart

var type: int = Type.HAMMERHEAD
var state: int = State.IDLE

var _target_aim := 0.0
var _prev_target := 0.0
var _aim_avel := 0.0           ## how fast the facing is turning (signed) — the whip input
var _angle := 0.0             ## world angle of the part around the owner (the pendulum)
var _avel := 0.0             ## angular velocity of the part (rad/s)
var _head_dist := 0.0
var _lift := 0.0             ## 0..1 raised amount under speed (visual stretch)
var _state_time := 0.0
var _head_world := Vector2.ZERO
var _head_speed := 0.0        ## measured part speed (px/s) — the hit's "relative_speed"
var _prev_owner_vel := Vector2.ZERO
var _hit_ids := {}
var _hit_clear := 0.0
var _clash_cd := 0.0
var _trail: Array = []
var _overlap_weapons: Array = []   ## other weapons' hitboxes touching ours (event-driven, usually empty)
var _swept_bodies: Array = []      ## fighters the part CROSSED between two ticks (anti-tunneling)
var _swept_areas: Array = []       ## weapon hitboxes crossed between ticks (a block must never be skipped)
var _clashed_now := false          ## a clash resolved this tick — the parry beats any same-tick wound
var _sweep_query := PhysicsShapeQueryParameters2D.new()
var _tracking_pickups := true
var _draw_key := -999              ## quantized visual state — redraw only when it changes

# Cached derived (recomputed on mass change).
var _head_radius := HEAD_RADIUS_BASE
var _arm_length := 74.0
var _stiffness := FOLLOW_STIFFNESS
var _damping := REST_DAMPING
var _drag := DRAG_GAIN
var _max_avel := MAX_AVEL

var _owner: Fighter
var _hitbox: Area2D
var _hitshape: CollisionShape2D
var _circle: CircleShape2D
var _solid: AnimatableBody2D       ## the physical part — shoves other fish so nothing overlaps
var _solid_shape: CollisionShape2D
var _solid_circle: CircleShape2D

func _ready() -> void:
	_owner = get_parent() as Fighter
	_hitbox = Area2D.new()
	# The part lives on its OWN collision layer and is monitorable, so other weapons'
	# hitboxes can detect it — that's what makes a saw and a bill physically CLASH.
	_hitbox.collision_layer = Game.L_WEAPON
	_hitbox.collision_mask = Game.L_FIGHTER | Game.L_PICKUP | Game.L_WEAPON
	_hitbox.monitoring = true
	_hitbox.monitorable = true
	_circle = CircleShape2D.new()
	_circle.radius = _head_radius
	_hitshape = CollisionShape2D.new()
	_hitshape.shape = _circle
	_hitbox.add_child(_hitshape)
	add_child(_hitbox)
	# Weapon-vs-weapon contact is EVENT-driven: the physics server tells us when another
	# part starts/stops touching ours, so the per-frame clash check is a no-op unless a
	# clash is actually possible (polling get_overlapping_areas() allocated every frame).
	_hitbox.area_entered.connect(_on_weapon_area_entered)
	_hitbox.area_exited.connect(_on_weapon_area_exited)
	# The SOLID part: a kinematic body driven to the part position each frame. It physically
	# pushes any OTHER fish (and is pushed against by them) so nothing overlaps — but a
	# collision exception with our own wielder means our own weapon never blocks us.
	_solid = AnimatableBody2D.new()
	_solid.top_level = true
	_solid.sync_to_physics = true
	_solid.collision_layer = Game.L_WEAPON_SOLID
	_solid.collision_mask = 0
	_solid_circle = CircleShape2D.new()
	_solid_circle.radius = _head_radius
	_solid_shape = CollisionShape2D.new()
	_solid_shape.shape = _solid_circle
	_solid.add_child(_solid_shape)
	add_child(_solid)
	if _owner:
		_solid.add_collision_exception_with(_owner)
	# The anti-tunneling sweep probe: the same circle as the hitbox, fighters + weapons only.
	_sweep_query.shape = _circle
	_sweep_query.collide_with_areas = true
	_sweep_query.collide_with_bodies = true
	_sweep_query.collision_mask = Game.L_FIGHTER | Game.L_WEAPON
	refresh_scale(_owner.mass if _owner else 1.0)
	_head_dist = _arm_length
	_head_world = _head_at()

func set_type(t: int) -> void:
	type = t
	refresh_scale(_owner.mass if _owner else 1.0)
	if _owner:
		_owner.queue_redraw()   # the body silhouette is species-drawn too

func type_name() -> String:
	return TYPES[type]["name"]

func boost_mult() -> float:
	return float(TYPES[type]["boost"])

func is_rear_anchored() -> bool:
	return int(TYPES[type]["anchor"]) < 0

## Recompute part size, reach and whip feel for the owner's current mass. Bigger =
## a larger part with more reach, but a lower angular-speed cap and a softer spring
## (laggier) — the weight-vs-mobility trade the whole game turns on.
func refresh_scale(mass: float) -> void:
	var t: Dictionary = TYPES[type]
	var m := sqrt(maxf(mass, 0.001))
	var agility := Game.agility_for_mass(mass)
	_head_radius = HEAD_RADIUS_BASE * float(t["head"]) * m
	var body_r := Game.body_radius_for_mass(mass)
	_arm_length = (body_r * 1.1 + _head_radius + 22.0) * float(t["reach"])
	_stiffness = FOLLOW_STIFFNESS * float(t["stiff"]) * agility
	_damping = REST_DAMPING * float(t["damp"])
	_drag = DRAG_GAIN * float(t["drag"])
	_max_avel = MAX_AVEL * float(t["avel"]) * agility
	if _circle:
		_circle.radius = _head_radius * 0.98
	if _solid_circle:
		_solid_circle.radius = _head_radius * 0.95

# --- control API (Fighter feeds the facing; species does the rest) -----------------

## The fish's facing. Front parts rest ahead, the ray's tail rests BEHIND — so the
## same "turn to whip" physics makes a bill joust and a tail crack.
func aim_at(angle: float) -> void:
	_target_aim = angle + (PI if is_rear_anchored() else 0.0)

## Enable/disable the physical part (off while the wielder is dead so a corpse's stale
## saw can't block the living).
func set_solid_active(on: bool) -> void:
	if _solid_shape:
		_solid_shape.set_deferred("disabled", not on)

func head_speed() -> float:
	return _head_speed

func reach() -> float:
	return _arm_length + _head_radius

## Settle the part back to a clean idle — used when a fish (re)spawns. Critically,
## it re-seeds the position trackers to the CURRENT (post-teleport) position so the
## first frame after a respawn measures ~0 part speed, not a teleport-distance spike
## that would land a free full-power hit.
func reset() -> void:
	state = State.IDLE
	_avel = 0.0
	_angle = _target_aim
	_head_dist = _arm_length
	_hit_ids.clear()
	_trail.clear()
	_overlap_weapons.clear()   # a respawn teleport invalidates every tracked overlap
	_swept_bodies.clear()
	_swept_areas.clear()
	_head_speed = 0.0
	_head_world = _head_at()
	_prev_target = _target_aim
	_prev_owner_vel = _owner.velocity if _owner else Vector2.ZERO

# --- per-frame --------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_state_time += delta

	# Facing turn speed (signed) — the "how fast are you whipping the part around" input.
	_aim_avel = wrapf(_target_aim - _prev_target, -PI, PI) / maxf(delta, 0.0001)
	_prev_target = _target_aim

	# Owner acceleration this frame — what sloshes the heavy part around (a boost surge
	# snaps the tail straight back; a hard stop flings it forward).
	var ov: Vector2 = _owner.velocity if _owner else Vector2.ZERO
	var accel: Vector2 = (ov - _prev_owner_vel) / maxf(delta, 0.0001)
	accel = accel.limit_length(3000.0)
	_prev_owner_vel = ov

	_update_pendulum(delta, accel)

	rotation = _angle
	if _hitbox:
		_hitbox.position = Vector2(_head_dist, 0.0)
	if _solid:
		_solid.global_position = _head_at()   # drive the physical part (top_level) to the world pos
	var prev_head := _head_world
	_update_trail(delta)                      # measure this tick's true head travel first...
	_sweep_contacts(prev_head, _head_world)   # ...then sample the path it skipped (anti-tunneling)
	_clashed_now = false
	_check_clash(delta)                       # blocks resolve BEFORE wounds: a parry beats a same-tick hit
	_apply_hits(delta)
	var fast := _head_speed > Game.HIT_SPEED_MIN
	if fast and state == State.IDLE:
		_change_state(State.SWING)
		# The whip-up whoosh doubles as a positional danger telegraph — you HEAR
		# a part come up to speed behind you before you see it.
		Sfx.play(&"whoosh", _head_world, -6.0, Game.rng().randf_range(0.88, 1.15))
	elif not fast and state == State.SWING:
		_change_state(State.IDLE)

	# Idle parts stop pair-tracking morsels (the physics server otherwise maintains overlap
	# pairs for every morsel each of 14 drifting parts passes) — a slow part never
	# wounds or flings anything anyway, so nothing observable changes.
	var want_pickups := state != State.IDLE or _head_speed >= Game.HIT_SPEED_MIN * 0.7
	if want_pickups != _tracking_pickups:
		_tracking_pickups = want_pickups
		_hitbox.set_deferred("collision_mask",
			Game.L_FIGHTER | Game.L_WEAPON | (Game.L_PICKUP if want_pickups else 0))

	# Redraw only when the QUANTIZED visual state changes — rotation is a transform, not
	# a redraw, so a resting or steadily-carried part costs zero canvas re-recording.
	var key := state
	key = key * 16 + int(clampf(_head_speed / 1400.0, 0.0, 1.0) * 12.0)
	key = key * 32 + int(_lift * 24.0)
	key = key * 4096 + int(_head_dist * 0.25)
	key = key * 2 + (1 if (_owner and _owner._eye_poke > 0.0) else 0)   # the hammerhead's ✕✕ lives here
	if key != _draw_key or _trail.size() > 0:
		_draw_key = key
		queue_redraw()

## ADAPTIVE anti-tunneling sweep: when the part moved further than its own radius in
## one physics tick, sample the path it skipped — the faster it moved, the more samples
## — so a lethal-speed part can never jump OVER a fish it should have hit, or OVER the
## weapon that should have BLOCKED it, between two ticks. Costs nothing at cruise speed
## (zero samples); this is the "higher Hz where the action is" without a global Hz hike.
func _sweep_contacts(from: Vector2, to: Vector2) -> void:
	_swept_bodies.clear()
	_swept_areas.clear()
	if _head_speed < Game.HIT_SPEED_MIN:
		return
	var travel := from.distance_to(to)
	var step := maxf(_head_radius * 0.8, 4.0)
	if travel <= step:
		return
	var space := get_world_2d().direct_space_state
	if space == null:
		return
	var n := mini(int(ceil(travel / step)) - 1, 8)
	for i in range(n):
		var t := float(i + 1) / float(n + 1)
		_sweep_query.transform = Transform2D(0.0, from.lerp(to, t))
		for hit in space.intersect_shape(_sweep_query, 8):
			var c: Object = hit["collider"]
			if c is Area2D:
				var w := (c as Area2D).get_parent() as Weapon
				if w != null and w != self and not _swept_areas.has(c):
					_swept_areas.append(c)
			elif c is Fighter and c != _owner and not _swept_bodies.has(c):
				_swept_bodies.append(c)

## Two weapon parts colliding: if their combined speed is high enough, both bounce
## off each other (reverse whip), the fish are shoved apart, and a spark pops. Checks
## the event-tracked overlaps PLUS anything the sweep says we crossed this tick.
func _check_clash(delta: float) -> void:
	_clash_cd -= delta
	if _clash_cd > 0.0 or (_overlap_weapons.is_empty() and _swept_areas.is_empty()):
		return
	for i in range(_overlap_weapons.size() - 1, -1, -1):
		if not is_instance_valid(_overlap_weapons[i]):
			_overlap_weapons.remove_at(i)   # its wielder died and was freed mid-overlap
	for area in _overlap_weapons + _swept_areas:
		var ow := (area as Area2D).get_parent() as Weapon
		if ow == null or ow == self:
			continue
		if _try_clash(ow):
			break

## Symmetric resolution: BOTH sides react at once (the sweep may only be seen from one
## side), one shared spark. Guarded by both cooldowns so it can never double-fire.
func _try_clash(ow: Weapon) -> bool:
	if _clash_cd > 0.0 or ow._clash_cd > 0.0:
		return false
	if _head_speed + ow._head_speed < CLASH_SPEED:
		return false
	_clash_react(ow)
	ow._clash_react(self)
	var mid := (_head_at() + ow._head_at()) * 0.5
	Sfx.play(&"clash", mid, -2.0, Game.rng().randf_range(0.9, 1.12))
	if Game.fx:
		Game.fx.burst(mid, Color(0.85, 0.97, 1.0), 10, 420.0, 2.5)
	if (_owner and _owner.is_player) or (ow._owner and ow._owner.is_player):
		Game.popup("CLASH!", mid + Vector2(0, -18), Color(0.85, 0.97, 1.0), 1.15)
	return true

## This side's half of a clash — momentum transfer by effective mass (part weight ×
## wielder size). The LIGHTER part bounces back harder and its wielder is shoved
## further; a hammer head barely flinches when a feather bill glances off it.
func _clash_react(ow: Weapon) -> void:
	var my_m := _effective_mass()
	var ow_m := ow._effective_mass()
	var my_share := ow_m / (my_m + ow_m + 0.001)
	_avel = -_avel * (0.25 + 0.75 * my_share)
	_clash_cd = 0.28
	_clashed_now = true
	if _owner and ow._owner:
		var dir := (_owner.global_position - ow._owner.global_position).normalized()
		var shove := clampf(ow_m * (ow._head_speed + 200.0) / maxf(my_m, 0.05) * 0.02, 40.0, 320.0)
		_owner.lunge(dir * shove)
		_owner.on_hit_feedback(clampf(shove * 0.08, 8.0, 22.0), dir, false)

func _on_weapon_area_entered(a: Area2D) -> void:
	var w := a.get_parent() as Weapon
	if w != null and w != self:
		_overlap_weapons.append(a)

func _on_weapon_area_exited(a: Area2D) -> void:
	_overlap_weapons.erase(a)

## The part's effective mass = species part weight × wielder size (bigger fish = heavier part).
func _effective_mass() -> float:
	var wm: float = float(TYPES[type]["mass"])
	return wm * sqrt(maxf(_owner.mass, 0.001)) if _owner else wm

func _update_pendulum(delta: float, accel: Vector2) -> void:
	var diff := wrapf(_target_aim - _angle, -PI, PI)
	var torque := _stiffness * diff - _damping * _avel
	# The owner's movement sloshes the heavy part (pendulum pseudo-force).
	torque += (accel.x * sin(_angle) - accel.y * cos(_angle)) / maxf(_arm_length, 1.0) * INERTIA_GAIN
	# The turn-whip: rotating your body drags the part around, building real speed.
	# It's your own muscle — no stamina cost (stamina is boost fuel, nothing else).
	if absf(_aim_avel) > 0.2:
		torque += _aim_avel * _drag
	_avel = clampf(_avel + torque * delta, -_max_avel, _max_avel)
	_angle = wrapf(_angle + _avel * delta, -PI, PI)
	# A little stretch under speed sells the whip.
	var target_dist := _arm_length + clampf(absf(_avel) * 0.7, 0.0, 16.0)
	_head_dist = lerpf(_head_dist, target_dist, clampf(10.0 * delta, 0.0, 1.0))
	_lift = lerpf(_lift, clampf(_head_speed / 1800.0, 0.0, 0.4), clampf(8.0 * delta, 0.0, 1.0))

# --- hit resolution ---------------------------------------------------------------

func _apply_hits(delta: float) -> void:
	_hit_clear -= delta
	if _hit_clear <= 0.0:
		_hit_ids.clear()
		_hit_clear = Game.HIT_INTERVAL
	# A parry this tick beats the wound: you blocked it, so it doesn't land.
	if _head_speed < Game.HIT_SPEED_MIN or _clashed_now:
		return
	# Current overlaps PLUS everything the sweep says we crossed between ticks.
	var bodies: Array = _hitbox.get_overlapping_bodies()
	for b in _swept_bodies:
		if not bodies.has(b):
			bodies.append(b)
	for body in bodies:
		if body == _owner or not is_instance_valid(body):
			continue
		var id: int = body.get_instance_id()
		if _hit_ids.has(id):
			continue
		if body is Fighter:
			_hit_ids[id] = true
			_score_hit(body, _head_speed)
		elif body.has_method("fling"):
			_hit_ids[id] = true
			var dir: Vector2 = (body.global_position - _owner.global_position).normalized()
			body.fling(dir * _head_speed * PICKUP_FLING * 0.1)

func _score_hit(victim: Fighter, speed: float) -> void:
	var t: Dictionary = TYPES[type]
	var mass_factor := sqrt(maxf(_owner.mass, 0.001))
	var speed_factor := clampf(speed / Game.REF_HEAD_SPEED, 0.35, 2.4)
	var dmg := Game.BASE_DMG * float(t["dmg"]) * mass_factor * speed_factor
	var knock := (Game.BASE_KNOCK * float(t["knock"])) * speed_factor
	var dir: Vector2 = (victim.global_position - _owner.global_position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT.rotated(_angle)
	var show_pop: bool = _owner.is_player or victim.is_player   # skip bot-vs-bot popups (churn + clutter)
	# EYE POKE (戳眼) — the ocean's cutest crit: EVERY species' sharp bit hurts extra when
	# it lands on the victim's FACE, where the eyes are. Same one rule ("damage is where
	# you touch"), extended to where you GET touched: the front sector is the soft spot.
	var to_face := _head_world - victim.global_position
	if to_face.length() < victim.body_radius * 1.35 \
			and to_face.normalized().dot(Vector2.RIGHT.rotated(victim.facing)) > 0.55:
		dmg *= 1.5
		victim.poke_eyes()
		Sfx.play(&"chime", victim.global_position, -6.0, 1.7)
		if show_pop:
			Game.popup("EYE POKE!", victim.global_position + Vector2(0, -victim.body_radius - 40.0), Color(1.0, 0.62, 0.8), 1.05)
	# REEF-PIN: if the victim can't fly back (the reef wall behind them), the knockback that
	# would have become motion becomes DAMAGE instead — so hammering a foe into the reef hurts
	# far more than knocking them into open water. High-knockback species benefit most.
	if victim.is_pinned(dir):
		dmg += knock * Game.PIN_DAMAGE
		if show_pop:
			Game.popup("PINNED!", victim.global_position + Vector2(0, -victim.body_radius - 16.0), Color(1.0, 0.55, 0.3), 1.1)
	var vulnerable: bool = victim._invuln <= 0.0
	var died := victim.take_damage(dmg, dir, knock)
	# The two wounds — the ONLY status effects, both species-signature and readable:
	# the saw opens a bleed, the ray's barb envenoms. They respect i-frames exactly like
	# direct damage (a spawn shield the venom slips through is no shield at all), and
	# the attacker is remembered so a wound-death still credits the hunter.
	if not died and vulnerable:
		match type:
			Type.SAWFISH:
				victim.apply_bleed(dmg * 0.22, _owner)
				if show_pop:
					Game.popup("BLEED!", victim.global_position + Vector2(0, -victim.body_radius - 28.0), Color(1.0, 0.35, 0.3), 0.95)
			Type.STINGRAY:
				victim.apply_venom(_owner)
				if show_pop:
					Game.popup("VENOM!", victim.global_position + Vector2(0, -victim.body_radius - 28.0), Color(0.6, 1.0, 0.45), 0.95)
	# Impact feedback scales with how hard the hit landed: a graze taps, a full ram cracks.
	var speed_n := clampf((speed_factor - 0.35) / 2.05, 0.0, 1.0)
	Sfx.play(&"thud", victim.global_position, lerpf(-9.0, 0.0, speed_n), lerpf(0.75, 1.25, speed_n))
	if Game.fx:
		Game.fx.burst(victim.global_position, Color(1.0, 0.85, 0.5), 4 + int(speed_factor * 4.0), 260.0 * speed_factor)
	var shake := clampf(speed_factor * 26.0, 6.0, 44.0)
	_owner.on_hit_feedback(shake, dir, false)
	# A scored hit commits the attacker's mass — a capped forward lunge along the blow.
	var nudge := clampf(speed * 0.05, 0.0, 160.0)
	_owner.lunge(dir * nudge)
	if died:
		_owner.on_scored_kill(victim)
	elif show_pop:
		Game.popup("WHAM!", victim.global_position + Vector2(0, -victim.body_radius - 12.0), Color(1, 0.95, 0.7), 0.9)

func _head_at() -> Vector2:
	return global_position + Vector2(_head_dist, 0.0).rotated(rotation)

func _update_trail(delta: float) -> void:
	var head := _head_at()
	_head_speed = minf(head.distance_to(_head_world) / maxf(delta, 0.0001), 3600.0)
	_head_world = head
	if _head_speed > Game.HIT_SPEED_MIN:
		_trail.push_back({"pos": head, "age": 0.0})
	for p in _trail:
		p.age += delta
	while _trail.size() > 0 and _trail[0].age > 0.2:
		_trail.pop_front()

func _change_state(s: int) -> void:
	state = s
	_state_time = 0.0

# --- drawing (all placeholder art, in code; +X points along the arm) ----------------

func _draw() -> void:
	_draw_trail()
	var head := Vector2(_head_dist, 0.0)
	var r := _head_radius * (1.0 + 0.4 * _lift)
	var speed_t := clampf(_head_speed / 1400.0, 0.0, 1.0)
	var base_col: Color = _owner.color if _owner else Color("cfd0d8")

	match type:
		Type.HAMMERHEAD:
			_draw_hammerhead(head, r, speed_t, base_col)
		Type.SAWFISH:
			_draw_saw(head, r, speed_t, base_col)
		Type.SWORDFISH:
			_draw_bill(head, r, speed_t, base_col)
		Type.STINGRAY:
			_draw_tail(head, r, speed_t, base_col)
		_:
			_draw_tentacle(head, r, speed_t, base_col)

	# A wake ring when the part is really moving — reads momentum at a glance.
	if speed_t > 0.25 and state == State.SWING:
		draw_arc(head, r + 6.0, 0.0, TAU, 32, Color(0.7, 0.95, 1.0, speed_t * 0.9), 3.0)

## Speed-heat tint shared by every part: flesh at rest, hot when it would wound.
func _part_color(base_col: Color, speed_t: float) -> Color:
	return base_col.darkened(0.08).lerp(Color(1.0, 0.5, 0.3), speed_t * 0.6)

func _draw_hammerhead(head: Vector2, r: float, speed_t: float, base_col: Color) -> void:
	var col := _part_color(base_col, speed_t)
	# Thick neck from the body out to the head.
	draw_line(Vector2(0, 0), head, col.darkened(0.12), r * 0.9)
	# The wide hammer: a capsule PERPENDICULAR to the arm, eyes at both lobe tips.
	var half := Vector2(0, r * 1.4)
	draw_line(head - half, head + half, col, r * 1.1)
	draw_circle(head - half, r * 0.55, col)
	draw_circle(head + half, r * 0.55, col)
	for s in [-1.0, 1.0]:
		var eye := head + Vector2(r * 0.28, s * r * 1.5)
		if _owner and _owner._eye_poke > 0.0:
			# The hammerhead keeps its eyes on its hammer — so that's where the ✕✕ goes.
			var c := Color(0.12, 0.1, 0.12)
			var er := r * 0.24
			draw_line(eye + Vector2(-er, -er), eye + Vector2(er, er), c, 3.0)
			draw_line(eye + Vector2(-er, er), eye + Vector2(er, -er), c, 3.0)
		else:
			draw_circle(eye, r * 0.2, Color(0.95, 0.95, 0.9))
			draw_circle(eye + Vector2(r * 0.05, 0), r * 0.1, Color(0.1, 0.1, 0.12))

func _draw_saw(head: Vector2, r: float, speed_t: float, base_col: Color) -> void:
	var col := _part_color(base_col, speed_t)
	var blade := Color(0.82, 0.84, 0.8).lerp(Color(1.0, 0.55, 0.35), speed_t * 0.6)
	var x0 := _head_dist * 0.12
	var tip := head + Vector2(r * 1.5, 0.0)
	# The rostrum: a long flat blade...
	draw_colored_polygon(PackedVector2Array([
		Vector2(x0, -r * 0.42), Vector2(tip.x, -r * 0.16),
		Vector2(tip.x + r * 0.5, 0.0),
		Vector2(tip.x, r * 0.16), Vector2(x0, r * 0.42),
	]), blade)
	# ...with TEETH down both edges (the whole point of a sawfish).
	var n := 7
	for i in range(n):
		var t := float(i + 1) / float(n + 1)
		var x := lerpf(x0, tip.x, t)
		var w := lerpf(r * 0.42, r * 0.16, t)
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - r * 0.14, -w), Vector2(x, -w - r * 0.34), Vector2(x + r * 0.14, -w)]), blade)
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - r * 0.14, w), Vector2(x, w + r * 0.34), Vector2(x + r * 0.14, w)]), blade)
	draw_circle(Vector2(x0, 0), r * 0.5, col)   # the snout root

func _draw_bill(head: Vector2, r: float, speed_t: float, base_col: Color) -> void:
	var col := _part_color(base_col, speed_t)
	var bill := Color(0.75, 0.78, 0.85).lerp(Color(1.0, 0.6, 0.3), speed_t * 0.7)
	var tip := head + Vector2(r * 2.0, 0.0)
	# The lance: a long thin taper — the TIP is where the damage lives.
	draw_colored_polygon(PackedVector2Array([
		Vector2(_head_dist * 0.1, -r * 0.5), tip, Vector2(_head_dist * 0.1, r * 0.5),
	]), bill)
	draw_circle(Vector2(_head_dist * 0.12, 0), r * 0.55, col)   # bill root
	if speed_t > 0.3:   # the tip glints when it's lethal
		draw_circle(tip, r * 0.3, Color(1.0, 1.0, 0.9, speed_t))

func _draw_tail(head: Vector2, r: float, speed_t: float, base_col: Color) -> void:
	var col := _part_color(base_col, speed_t)
	# The whip: a tapered curve from the body to the barb, sagging against the swing.
	var sag := clampf(-_avel * 6.0, -r * 1.4, r * 1.4)
	var x0 := _head_dist * 0.05
	var prev := Vector2(x0, 0.0)
	var n := 7
	for i in range(1, n + 1):
		var t := float(i) / float(n)
		var p := Vector2(lerpf(x0, head.x, t), sag * sin(t * PI))
		draw_line(prev, p, col, lerpf(r * 0.55, r * 0.22, t))
		prev = p
	# The venom barb: a pale spike past the tail tip.
	var barb := Color(0.85, 0.95, 0.75).lerp(Color(0.6, 1.0, 0.4), speed_t)
	draw_colored_polygon(PackedVector2Array([
		head + Vector2(r * 1.3, 0), head + Vector2(-r * 0.2, -r * 0.45), head + Vector2(-r * 0.2, r * 0.45),
	]), barb)

func _draw_tentacle(head: Vector2, r: float, speed_t: float, base_col: Color) -> void:
	var col := _part_color(base_col, speed_t)
	# Two trailing side tentacles + the main club arm.
	for s in [-1.0, 1.0]:
		var mid := Vector2(head.x * 0.5, s * r * 0.9)
		draw_line(Vector2(0, s * r * 0.3), mid, col.darkened(0.15), r * 0.3)
		draw_line(mid, head * 0.82 + Vector2(0, s * r * 0.5), col.darkened(0.15), r * 0.22)
	draw_line(Vector2.ZERO, head, col, r * 0.42)
	# The club: a fat pad with suckers.
	draw_circle(head, r, col)
	draw_circle(head + Vector2(r * 0.25, 0), r * 0.28, col.lightened(0.25))
	draw_circle(head + Vector2(-r * 0.25, -r * 0.4), r * 0.2, col.lightened(0.25))
	draw_circle(head + Vector2(-r * 0.25, r * 0.4), r * 0.2, col.lightened(0.25))
	draw_arc(head, r, 0.0, TAU, 24, col.darkened(0.3), 2.0)

func _draw_trail() -> void:
	if _trail.size() < 2:
		return
	# A bubble wake, not a fire trail — we're underwater.
	for i in range(_trail.size() - 1):
		var a: float = 1.0 - _trail[i].age / 0.2
		var p0: Vector2 = to_local(_trail[i].pos)
		var p1: Vector2 = to_local(_trail[i + 1].pos)
		draw_line(p0, p1, Color(0.8, 0.94, 1.0, clampf(a, 0.0, 1.0) * 0.4), 9.0 * clampf(a, 0.2, 1.0))
