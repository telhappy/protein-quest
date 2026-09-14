extends Camera3D

## Watches the player from outside the planet rather than riding behind it:
## sits near the radial line from gravity_center through the player (so it
## automatically swings around to the far side, or dips in closer, as the
## player moves across the surface), but tilted toward "behind" the
## player's current facing rather than sitting straight overhead. Purely
## radial gives zero parallax on a jump (it's motion straight along the
## view axis); the tilt is what makes jumps and turns actually readable.
## The tilt tracking the player's mouse-controlled facing also means
## turning the mouse visibly swings the camera, even standing still.

@export var follow_speed: float = 3.5
@export var distance: float = 150.0
@export var min_distance: float = 20.0
@export var max_distance: float = 600.0
@export var zoom_step: float = 0.15
@export var tilt_ratio: float = 0.6  # 0 = straight overhead, higher = more angled/behind

var player: Node3D
var gravity_center: Vector3 = Vector3.ZERO
var _back_dir := Vector3.FORWARD


func _ready() -> void:
	near = 0.1
	far = distance * 20.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clamp(distance * (1.0 - zoom_step), min_distance, max_distance)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clamp(distance * (1.0 + zoom_step), min_distance, max_distance)


func _process(delta: float) -> void:
	if player == null:
		return

	var out_dir := player.global_position - gravity_center
	out_dir = out_dir.normalized() if out_dir.length() > 0.001 else Vector3.UP

	var player_forward: Vector3 = -player.transform.basis.z
	var back := player_forward - out_dir * player_forward.dot(out_dir)
	if back.length() > 0.001:
		_back_dir = -back.normalized()

	var offset_dir := (out_dir + _back_dir * tilt_ratio).normalized()
	var target_pos := _clear_of_occlusion(gravity_center + offset_dir * distance, out_dir)
	var t := 1.0 - exp(-follow_speed * delta)
	global_position = global_position.lerp(target_pos, t)

	# A fixed world-up hint gimbal-locks when looking straight down at a
	# pole; project it onto the tangent plane at the camera instead so the
	# horizon stays stable as the camera orbits.
	var up_hint := Vector3.UP - offset_dir * Vector3.UP.dot(offset_dir)
	if up_hint.length() < 0.1:
		up_hint = Vector3.FORWARD
	look_at(player.global_position, up_hint.normalized())


func _clear_of_occlusion(target_pos: Vector3, out_dir: Vector3) -> Vector3:
	# If the player has ducked into a pocket/overhang, the straight radial
	# camera spot can end up behind protein geometry; pull the camera in
	# along the same line until it has a clear line of sight instead.
	# The ray must start lifted off the surface -- the player is normally
	# resting right on the mesh, so a ray from its exact position immediately
	# self-intersects the ground it's standing on and collapses the camera
	# onto the player.
	var origin := player.global_position + out_dir * 2.0
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, target_pos)
	query.collision_mask = 1  # the protein's static trimesh collider
	var result := space_state.intersect_ray(query)
	if result:
		return origin + (result.position - origin) * 0.85
	return target_pos
