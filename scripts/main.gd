extends Node3D

const MESH_SCENE := preload("res://assets/1ATP/1ATP_chainE_surface.glb")
const BINDING_SITE_JSON := "res://assets/1ATP/1ATP_binding_site.json"
const PLAYER_SCRIPT := preload("res://scripts/player.gd")
const OVERVIEW_CAMERA_SCRIPT := preload("res://scripts/overview_camera.gd")

# Collision layer for the player body. The protein's own trimesh collider
# stays on the default layer 1.
const PLAYER_LAYER := 2

@export var goal_radius: float = 3.0

var _goal_label: Control
var _goal_reached: bool = false
var _goal_visual_mat: StandardMaterial3D


func _ready() -> void:
	var mesh_instance: Node3D = MESH_SCENE.instantiate()
	add_child(mesh_instance)
	_make_double_sided(mesh_instance)
	_add_collision(mesh_instance)

	var aabb := _compute_aabb(mesh_instance)
	var center := aabb.get_center()
	var radius: float = max(aabb.size.length() * 0.5, 1.0)

	var goal_pos := _load_binding_site_centroid()
	_spawn_goal_area(goal_pos)
	_setup_environment()
	_setup_starfield(radius)
	_setup_ui()
	var player := _spawn_player(center, radius)
	_spawn_camera(center, radius, player)


func _process(_delta: float) -> void:
	if _goal_visual_mat:
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * 2.0)
		_goal_visual_mat.albedo_color.a = 0.2 + 0.3 * pulse
		_goal_visual_mat.emission_energy_multiplier = 0.5 + 1.5 * pulse


func _compute_aabb(root: Node) -> AABB:
	var aabb := AABB()
	var mesh_nodes := root.find_children("*", "MeshInstance3D", true, false)
	if mesh_nodes.size() > 0:
		var first: MeshInstance3D = mesh_nodes[0]
		aabb = first.global_transform * first.get_aabb()
		for i in range(1, mesh_nodes.size()):
			var mi: MeshInstance3D = mesh_nodes[i]
			aabb = aabb.merge(mi.global_transform * mi.get_aabb())
	return aabb


func _add_collision(root: Node) -> void:
	# Exact per-triangle collision against the actual SES surface (concave,
	# with pockets/clefts intact) rather than a convex-hull approximation --
	# a StaticBody3D + ConcavePolygonShape3D built straight from the mesh.
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		mi.create_trimesh_collision()


func _make_double_sided(root: Node) -> void:
	# The marching-cubes surface isn't watertight, so single-sided culling
	# leaves gaps where you can see through to nothing; disable it. Also
	# turn on vertex colors -- the pipeline bakes per-residue coloring into
	# the mesh's COLOR_0 attribute, but Godot doesn't use it as albedo
	# unless a material explicitly opts in.
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = mi.mesh
		for surf in range(mesh.get_surface_count()):
			var mat := mesh.surface_get_material(surf)
			if mat == null:
				continue
			var dup: Material = mat.duplicate()
			if dup is BaseMaterial3D:
				dup.cull_mode = BaseMaterial3D.CULL_DISABLED
				dup.vertex_color_use_as_albedo = true
			mi.set_surface_override_material(surf, dup)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.6

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-45, -45, 0)
	add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-135, 135, 0)
	fill_light.light_energy = 0.5
	add_child(fill_light)


func _make_hud_panel_style() -> StyleBoxFlat:
	# The protein surface is pale and fills most of the screen, so plain
	# white text on it disappears; every HUD label sits on one of these
	# semi-transparent dark panels for contrast regardless of what's behind it.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	style.set_corner_radius_all(6)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()

	var goal_panel := PanelContainer.new()
	goal_panel.add_theme_stylebox_override("panel", _make_hud_panel_style())
	goal_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	goal_panel.offset_top = 24
	goal_panel.offset_left = 200
	goal_panel.offset_right = -200
	goal_panel.visible = false

	var label := Label.new()
	label.name = "GoalLabel"
	label.text = "ATP BINDING SITE REACHED"
	label.add_theme_font_size_override("font_size", 32)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	goal_panel.add_child(label)
	canvas.add_child(goal_panel)
	_goal_label = goal_panel

	var crosshair := Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 24)
	crosshair.add_theme_color_override("font_color", Color.WHITE)
	crosshair.add_theme_color_override("font_outline_color", Color.BLACK)
	crosshair.add_theme_constant_override("outline_size", 4)
	crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	canvas.add_child(crosshair)

	var hint_panel := PanelContainer.new()
	hint_panel.add_theme_stylebox_override("panel", _make_hud_panel_style())
	hint_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint_panel.offset_top = -40
	hint_panel.offset_bottom = -8

	var hint := Label.new()
	hint.text = "WASD move / Space jump / Shift boost / mouse turn / wheel zoom camera / R reset / Esc release mouse"
	hint.add_theme_color_override("font_color", Color.WHITE)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_panel.add_child(hint)
	canvas.add_child(hint_panel)

	add_child(canvas)


func _load_binding_site_centroid() -> Vector3:
	var text := FileAccess.get_file_as_string(BINDING_SITE_JSON)
	var data: Dictionary = JSON.parse_string(text)
	var c: Array = data["binding_site"]["centroid"]
	return Vector3(c[0], c[1], c[2])


func _spawn_goal_area(pos: Vector3) -> void:
	var area := Area3D.new()
	area.name = "BindingSiteGoal"
	area.position = pos
	# The ATP pocket sits inside the protein's own surface, so the trimesh
	# collider added by _add_collision() geometrically overlaps this area.
	# Only react to the player body (layer 2), never to world geometry.
	area.collision_layer = 0
	area.collision_mask = PLAYER_LAYER

	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = goal_radius
	collision.shape = shape
	area.add_child(collision)

	var visual := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = goal_radius
	sphere_mesh.height = goal_radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.1, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.1)
	sphere_mesh.material = mat
	visual.mesh = sphere_mesh
	area.add_child(visual)
	_goal_visual_mat = mat

	area.body_entered.connect(_on_goal_entered)
	add_child(area)


func _on_goal_entered(body: Node3D) -> void:
	print("Reached binding site goal: ", body.name)
	if not _goal_reached:
		_goal_reached = true
		_goal_label.visible = true


func _on_player_respawned() -> void:
	_goal_reached = false
	_goal_label.visible = false


func _setup_starfield(radius: float) -> void:
	var star_count := 1200
	var shell_radius := radius * 12.0

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * shell_radius * 0.006

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1)
	mat.emission_enabled = true
	mat.emission = Color(1, 1, 1)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = star_count
	for i in range(star_count):
		var dir := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
		if dir.length() < 0.001:
			dir = Vector3.UP
		var scale_jitter := randf_range(0.4, 1.6)
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * scale_jitter),
				dir.normalized() * shell_radius))

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)


func _spawn_player(center: Vector3, radius: float) -> CharacterBody3D:
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(PLAYER_SCRIPT)
	player.gravity_center = center
	player.move_speed = radius * 0.4
	player.gravity_strength = radius * 0.6
	player.jump_speed = radius * 0.25
	var spawn_pos := center + Vector3(0, 0, 1) * radius * 2.5
	player.look_at_from_position(spawn_pos, center, Vector3.UP)
	# Position and rotation must both be set before entering the tree so the
	# player script's _ready() captures this as the correct respawn pose.
	add_child(player)
	player.respawned.connect(_on_player_respawned)
	return player


func _spawn_camera(center: Vector3, radius: float, player: Node3D) -> void:
	var cam := Camera3D.new()
	cam.name = "OverviewCamera"
	cam.set_script(OVERVIEW_CAMERA_SCRIPT)
	cam.gravity_center = center
	cam.distance = radius * 3.5
	cam.min_distance = radius * 1.2
	cam.max_distance = radius * 10.0
	cam.position = center + Vector3(0, 0, 1) * cam.distance
	add_child(cam)
	cam.player = player
	cam.current = true
