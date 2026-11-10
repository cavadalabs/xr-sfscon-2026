extends Node
class_name InteractiveCollisionController3D

@export var target_root_node_path: NodePath
@export var respect_node3d_visibility := true

@onready var target_root: Node = get_node_or_null(target_root_node_path)


func set_interactive(is_enabled: bool) -> void:
	if target_root == null:
		return

	set_branch_interactive(target_root, is_enabled)


func set_branch_interactive(branch_root: Node, is_enabled: bool) -> void:
	if branch_root == null:
		return

	_set_interactive_recursive(branch_root, is_enabled)


func _set_interactive_recursive(node: Node, is_enabled: bool) -> void:
	var effective_enabled := is_enabled
	if respect_node3d_visibility and node is Node3D and not (node as Node3D).visible:
		effective_enabled = false
	if not effective_enabled and node is DemoButton3D:
		(node as DemoButton3D).set_hovered(false)

	if node is CollisionObject3D:
		var collision_object := node as CollisionObject3D
		if not collision_object.has_meta("default_collision_layer"):
			collision_object.set_meta("default_collision_layer", collision_object.collision_layer)

		collision_object.input_ray_pickable = effective_enabled
		if effective_enabled:
			collision_object.collision_layer = int(collision_object.get_meta("default_collision_layer"))
		else:
			collision_object.collision_layer = 0

	for child in node.get_children():
		_set_interactive_recursive(child, effective_enabled)
