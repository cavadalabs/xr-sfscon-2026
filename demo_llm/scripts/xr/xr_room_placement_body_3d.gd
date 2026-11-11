extends CharacterBody3D
class_name XRRoomPlacementBody3D

# A swept box uses the actual scanned wall shapes, including finite walls and
# concave rooms. The box is deliberately conservative for irregular furniture.
const WALL_LAYER := 1 << 24
## Distanza minima (metri) mantenuta dal muro quando il body si riallinea.
@export var min_clearance := 0.03
@export var wall_clearance := 0.018
var box: BoxShape3D
var initialized := false
var last_valid_pose := Transform3D.IDENTITY
var has_valid_pose := false


func _ready() -> void:
	# The Shape child (and its BoxShape3D) come from XRRoomPlacementBody3D.tscn.
	box = $Shape.shape as BoxShape3D


func reset_box(size: Vector3, pose: Transform3D) -> void:
	box.size = size.max(Vector3.ONE * 0.01)
	global_transform = pose.orthonormalized()
	initialized = true
	has_valid_pose = is_clear(global_transform)
	last_valid_pose = global_transform


func is_clear(pose: Transform3D) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = pose.orthonormalized()
	query.collision_mask = WALL_LAYER
	query.margin = wall_clearance * 0.5
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func solve(desired: Transform3D, align_to_wall := false) -> Dictionary:
	if not initialized:
		return {"valid": false, "pose": desired, "wall_contact": false}
	# A refreshed scan can overlap a previously valid pose. Prefer the last clear
	# pose, or escape towards a clear target without crossing another wall.
	if not is_clear(global_transform):
		if has_valid_pose and is_clear(last_valid_pose):
			global_transform = last_valid_pose
		elif is_clear(desired) and _can_escape_to(desired):
			global_transform = desired.orthonormalized()
			return _result(false)
	# Small numerical overlaps still benefit from the physics engine's recovery.
	for _recovery in range(3):
		if is_clear(global_transform):
			break
		move_and_collide(Vector3.ZERO, false, wall_clearance, true)
	if not is_clear(global_transform):
		# The invalid ghost follows the requested point; it never becomes the
		# next collision origin, so successive frames cannot tunnel through a wall.
		return {"valid": false, "pose": desired, "wall_contact": true}
	var contact := false
	var wall_normal := Vector3.ZERO
	var from := global_basis.get_rotation_quaternion()
	var to := desired.basis.orthonormalized().get_rotation_quaternion()
	# Check the swept rotation as well as its endpoint (a long shelf can hit a corner).
	var steps := maxi(1, ceili(from.angle_to(to) / deg_to_rad(3.0)))
	for i in range(1, steps + 1):
		var candidate := Transform3D(Basis(from.slerp(to, float(i) / steps)), global_position)
		if not is_clear(candidate):
			contact = true
			break
		global_basis = candidate.basis
	var motion := desired.origin - global_position
	for _i in range(4):
		if motion.length_squared() < 0.000001:
			break
		var collision := move_and_collide(motion, false, wall_clearance)
		if collision == null:
			break
		contact = true
		wall_normal = collision.get_normal()
		# Jolt's safe margin is recovery tolerance, not a maintained contact gap.
		move_and_collide(collision.get_normal() * wall_clearance)
		motion = collision.get_remainder().slide(collision.get_normal())
	if align_to_wall and wall_normal.length_squared() > 0.5:
		wall_normal.y = 0
		wall_normal = wall_normal.normalized()
		var aligned := wall_aligned_basis(global_basis, wall_normal)
		if not global_basis.is_equal_approx(aligned):
			# Make room for the swept rotation before sliding back to contact.
			var clearance := maxf(min_clearance, projected_radius(aligned, wall_normal) - projected_radius(global_basis, wall_normal) + min_clearance)
			move_and_collide(wall_normal * clearance, false, wall_clearance)
			var snapped := solve(Transform3D(aligned, desired.origin))
			snapped.wall_contact = true
			return snapped
	return _result(contact)


func _result(contact: bool) -> Dictionary:
	var valid := is_clear(global_transform)
	if valid:
		last_valid_pose = global_transform
		has_valid_pose = true
	elif has_valid_pose and is_clear(last_valid_pose):
		global_transform = last_valid_pose
		valid = true
	return {"valid": valid, "pose": global_transform, "wall_contact": contact}


func _can_escape_to(desired: Transform3D) -> bool:
	var space := get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(global_position, desired.origin, WALL_LAYER)
	ray.hit_from_inside = true
	if not space.intersect_ray(ray).is_empty():
		return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = global_transform
	query.collision_mask = WALL_LAYER
	query.margin = wall_clearance
	var excluded: Array[RID] = []
	for overlap in space.intersect_shape(query, 32):
		excluded.append(overlap.rid)
	query.exclude = excluded
	query.motion = desired.origin - global_position
	var fractions := space.cast_motion(query)
	return not fractions.is_empty() and fractions[0] >= 0.9999


func projected_radius(basis: Basis, normal: Vector3) -> float:
	return absf(normal.dot(basis.x)) * box.size.x * 0.5 + absf(normal.dot(basis.y)) * box.size.y * 0.5 + absf(normal.dot(basis.z)) * box.size.z * 0.5


static func wall_aligned_basis(basis: Basis, normal: Vector3) -> Basis:
	var wall_yaw := atan2(normal.x, normal.z)
	var yaw := basis.get_euler().y
	return Basis(Vector3.UP, wall_yaw + roundf(wrapf(yaw - wall_yaw, -PI, PI) / (PI * 0.5)) * PI * 0.5)
