class_name Player
extends Fighter
## The human-controlled predator. One-finger simple: the fish swims TOWARD the mouse
## (or the touch stick), and holding LMB / SPACE (or the left thumb) BOOSTS. That's
## the whole scheme — steering is aiming, the boost is the attack, and your species'
## weapon part does the rest through physics.

var camera: GameCamera
var _tc: TouchControls

func _ready() -> void:
	is_player = true
	display_name = "You"
	color = Color("f4e6b4")
	super._ready()
	camera = GameCamera.new()
	add_child(camera)

func spawn_setup(pos: Vector2, m: float, nm: String, col: Color) -> void:
	super.spawn_setup(pos, m, nm, col)
	if camera:
		camera.snap()   # don't let the smoothed camera glide across the map after a respawn teleport

func _control(_delta: float) -> void:
	var tc := _touch()
	var on_touch: bool = tc != null and tc.enabled

	# Steering: WASD/gamepad always works; on touch the steer thumb drives; otherwise
	# the fish follows the MOUSE — stop by bringing the cursor onto your own body.
	move_dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if on_touch:
		move_dir = (move_dir + tc.move_vec).limit_length(1.0)
	elif move_dir == Vector2.ZERO:
		var to_mouse := get_global_mouse_position() - global_position
		if to_mouse.length() > body_radius * 0.9:
			# Ease off near the cursor so you can hover instead of orbiting it.
			move_dir = to_mouse.normalized() * clampf(to_mouse.length() / (body_radius * 3.0), 0.25, 1.0)

	# The one button.
	boosting = Input.is_action_pressed("attack") or Input.is_action_pressed("spin") \
		or (on_touch and tc.boost_held)

	# The spawn shield drops the moment you turn aggressor — an invulnerable attacker
	# would be uncounterable. (Post-hit i-frames are 0.18s, so >0.4s can only be a shield.)
	if boosting and _invuln > 0.4 and not Game.picking:
		_invuln = 0.4

func _touch() -> TouchControls:
	if _tc == null or not is_instance_valid(_tc):
		_tc = get_tree().get_first_node_in_group("touch_controls") as TouchControls
	return _tc

func on_hit_feedback(shake: float, dir: Vector2, big: bool) -> void:
	if camera:
		camera.add_shake(shake, dir)
		if big:
			camera.kick(22.0)
