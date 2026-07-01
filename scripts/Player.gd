class_name Player
extends Fighter
## The human-controlled Arthur. WASD to haul yourself around (heavy, momentum-based);
## the mouse aims the stone, and DRAGGING the mouse around yourself whips it up to
## speed — a fast whip hits hard, a slow drag only shoves. Hold LMB to commit a swing,
## RMB to slam, Space to whirl.

var camera: GameCamera

func _ready() -> void:
	is_player = true
	uses_stamina = true
	display_name = "You"
	color = Color("f4e6b4")
	super._ready()
	camera = GameCamera.new()
	add_child(camera)

func _control(_delta: float) -> void:
	move_dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var to_mouse := get_global_mouse_position() - global_position
	if to_mouse.length() > 4.0:
		weapon.aim_at(to_mouse.angle())
	# Slam and whirl take priority over the swing (mirrors the reference ordering).
	if Input.is_action_just_pressed("slam"):
		weapon.do_slam()
	var whirling := Input.is_action_pressed("spin")
	weapon.set_spin(whirling)
	weapon.set_swinging(Input.is_action_pressed("attack") and not whirling and not weapon.is_busy())

func on_hit_feedback(shake: float, dir: Vector2, big: bool) -> void:
	if camera:
		camera.add_shake(shake, dir)
		if big:
			camera.kick(22.0)
