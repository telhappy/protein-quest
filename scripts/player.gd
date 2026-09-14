extends CharacterBody3D

signal respawned

## Super Mario Galaxy-style planetoid movement: gravity always pulls toward
## gravity_center (the protein's centroid) rather than a fixed world-down,
## so the player runs around on whatever part of the molecular surface
## currently faces "up" (away from that center), and can jump off it.
## The camera is a separate node (see overview_camera.gd) that watches this
## body from a distance rather than being attached to it.

@export var move_speed: float = 20.0
@export var boost_multiplier: float = 3.0
@export var mouse_sensitivity: float = 0.003
@export var probe_radius: float = 1.2
@export var gravity_strength: float = 30.0
@export var jump_speed: float = 14.0
@export var reorient_speed: float = 8.0
@export var bounce_restitution: float = 0.25
@export var bounce_speed_threshold: float = 6.0

## World-space point gravity pulls toward. Set by main.gd before the node
## enters the tree (the protein mesh's AABB center).
var gravity_center: Vector3 = Vector3.ZERO

var _vertical_speed: float = 0.0
var _jump_requested: bool = false
var _spawn_transform: Transform3D


func _ready() -> void:
	collision_layer = 2  # PLAYER_LAYER, see main.gd
	collision_mask = 1   # world geometry (the protein's trimesh collider)
	floor_snap_length = 0.5  # keep contact with the surface over small bumps

	var shape := SphereShape3D.new()
	shape.radius = probe_radius
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)

	var mesh_instance := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = probe_radius
	sphere_mesh.height = probe_radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.4, 0.3)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.3)
	mat.emission_energy_multiplier = 0.6
	sphere_mesh.material = mat
	mesh_instance.mesh = sphere_mesh
	add_child(mesh_instance)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Remember where/how we started so a stuck player (wedged into a pocket
	# or cleft in the surface) can bail out with a reset.
	_spawn_transform = transform


func _respawn() -> void:
	transform = _spawn_transform
	velocity = Vector3.ZERO
	_vertical_speed = 0.0
	_jump_requested = false
	respawned.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Yaw around the player's OWN current up axis (not the world/parent
		# Y), since that axis constantly changes as you walk around the
		# planetoid's curved surface.
		rotate_object_local(Vector3.UP, -event.relative.x * mouse_sensitivity)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.physical_keycode == KEY_SPACE:
			_jump_requested = true
		elif event.physical_keycode == KEY_R:
			_respawn()
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	var up := global_position - gravity_center
	up = up.normalized() if up.length() > 0.001 else Vector3.UP
	_align_to_up(up, delta)
	up_direction = up

	var input_dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		input_dir -= transform.basis.z
	if Input.is_physical_key_pressed(KEY_S):
		input_dir += transform.basis.z
	if Input.is_physical_key_pressed(KEY_A):
		input_dir -= transform.basis.x
	if Input.is_physical_key_pressed(KEY_D):
		input_dir += transform.basis.x
	# Keep movement in the local tangent plane even mid-reorientation.
	input_dir -= up * input_dir.dot(up)
	if input_dir.length() > 0.001:
		input_dir = input_dir.normalized()

	var speed := move_speed
	if Input.is_physical_key_pressed(KEY_SHIFT):
		speed *= boost_multiplier

	if is_on_floor():
		# A hard landing (big fall, a jump) gets a small elastic bounce;
		# gentle contact (walking over bumps) just settles, so this
		# doesn't make ordinary movement feel bouncy.
		if -_vertical_speed > bounce_speed_threshold:
			_vertical_speed = -_vertical_speed * bounce_restitution
		else:
			_vertical_speed = 0.0
		if _jump_requested:
			_vertical_speed = jump_speed
	else:
		_vertical_speed -= gravity_strength * delta
	_jump_requested = false

	velocity = input_dir * speed + up * _vertical_speed
	move_and_slide()


func _align_to_up(up: Vector3, delta: float) -> void:
	# Rebuild the body's orientation so local Y matches the current "up"
	# (radially away from gravity_center), keeping as much of the existing
	# facing direction as possible, and blend into it smoothly rather than
	# snapping -- a hard bump on this lumpy surface shouldn't spin the
	# camera instantly.
	var forward := -transform.basis.z
	forward -= up * forward.dot(up)
	if forward.length() < 0.001:
		forward = transform.basis.x - up * transform.basis.x.dot(up)
	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	forward = up.cross(right).normalized()
	var target_basis := Basis(right, up, -forward).orthonormalized()
	transform.basis = transform.basis.orthonormalized().slerp(
			target_basis, clamp(delta * reorient_speed, 0.0, 1.0))
