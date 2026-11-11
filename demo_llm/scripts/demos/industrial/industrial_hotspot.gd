extends Area3D
class_name IndustrialHotspot

signal selected(info: Dictionary)

@export_range(0.01, 0.15, 0.005) var surface_clearance := 0.025
@export_range(1.0, 4.0, 0.1) var reading_distance := 2.5
@export var hover_color := Color("268b78")
## Raggio (metri) dell'area sensibile al puntatore del marker.
@export var hit_radius := 0.055

var info: Dictionary
var anchor: Node3D
var number := 1
var material: StandardMaterial3D
var base_color := Color("183f42")
@onready var connector: MeshInstance3D = $Connector


func _ready() -> void:
	# The shape, sphere, label and connector come from IndustrialHotspot.tscn.
	# The material is duplicated so hovering one marker does not tint them all.
	material = $Body.material_override.duplicate() as StandardMaterial3D
	base_color = material.albedo_color
	$Body.material_override = material
	$Label.text = str(number)


func update_pose(camera: Camera3D, model_pose: Transform3D, bounds: AABB, earlier: Array[Area3D] = []) -> void:
	if not is_instance_valid(anchor):
		return
	var target := anchor.global_position
	var to_camera := camera.global_position - target if camera != null else Vector3.BACK
	if to_camera.length_squared() < 0.0001:
		to_camera = Vector3.BACK
	var factor := clampf(to_camera.length() / reading_distance, 1.0, 2.5)
	var model_scale := model_pose.basis.get_scale()
	var padding := (hit_radius * factor + surface_clearance) / maxf(model_scale[model_scale.min_axis_index()], 0.001)
	var padded := bounds.grow(padding)
	# ponytail: the oriented model bounds keep every marker outside without mesh raycasts;
	# use component bounds if a future product needs tighter callouts around large empty gaps.
	var offset := Vector3.ZERO
	for _attempt in range(12):
		var local_anchor := model_pose.affine_inverse() * (anchor.global_position + offset)
		var direction := to_camera - offset
		var local_direction := (model_pose.basis.inverse() * direction).normalized()
		var outside := local_anchor + local_direction * (padded.size.length() + local_anchor.distance_to(padded.get_center()) + 1.0)
		var surface: Variant = padded.intersects_segment(outside, local_anchor)
		target = model_pose * surface if surface is Vector3 else anchor.global_position + offset
		if camera == null:
			break
		var sightline := target - camera.global_position
		var overlaps := false
		for other in earlier:
			var other_sightline := other.global_position - camera.global_position
			var separation := atan2(hit_radius * factor, sightline.length()) + atan2(hit_radius * other.global_basis.get_scale().x, other_sightline.length()) + 0.01
			if sightline.angle_to(other_sightline) < separation:
				overlaps = true
				break
		if not overlaps:
			break
		offset += camera.global_basis.x * (hit_radius * factor * 2.8 * to_camera.length() / maxf(sightline.length(), 0.1))
	global_position = target
	if camera != null and camera.global_position.distance_squared_to(target) > 0.0001:
		to_camera = camera.global_position - target
	var up := Vector3.UP if absf(to_camera.normalized().dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
	global_basis = Basis.looking_at(-to_camera, up).scaled(Vector3.ONE * factor)
	var end := to_local(anchor.global_position)
	connector.visible = end.length() > 0.045
	if connector.visible:
		connector.transform = Transform3D(Basis(Quaternion(Vector3.BACK, end.normalized())) * Basis.from_scale(Vector3(1, 1, end.length())), end * 0.5)


func pointer_event(event: Variant) -> void:
	if not event is XRToolsPointerEvent:
		return
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			material.albedo_color = hover_color
		XRToolsPointerEvent.Type.EXITED:
			material.albedo_color = base_color
		XRToolsPointerEvent.Type.PRESSED:
			selected.emit(info)
