extends Node3D
class_name InfoPanel3D

const FittedLabel := preload("res://scripts/ui/fitted_label_3d.gd")

@export_range(1.0, 4.0, 0.1) var reading_distance := 2.5
@export_range(1.0, 4.0, 0.1) var max_distance_scale := 3.0

@onready var title_label: Label3D = $TitleLabel
@onready var body_label: Label3D = $BodyLabel
@onready var presentation_scale := global_basis.get_scale()

var title_text := ""
var body_text := ""
var dismissed := false
var value_lines_root: Node3D
var value_line_labels: Array[Label3D] = []
var value_line_templates: Array[String] = []
var drag_handle: XRPanelDragHandle3D
const DRAG_HANDLE_SCENE := preload("res://scenes/ui/XRPanelDragHandle3D.tscn")


func _ready() -> void:
	var bounds: AABB = $GlassPanel.mesh.get_aabb()
	drag_handle = DRAG_HANDLE_SCENE.instantiate() as XRPanelDragHandle3D
	drag_handle.name = "DragHandle"
	drag_handle.position = Vector3(0, bounds.position.y - 0.16, 0.07)
	drag_handle.panel_size = Vector2(bounds.size.x, bounds.size.y + 0.4)
	drag_handle.present_on_show = false
	drag_handle.face_camera = false
	add_child(drag_handle)
	value_lines_root = get_node_or_null("ValueLines") as Node3D
	_collect_value_line_labels()
	if title_text == "":
		title_text = title_label.text
	if body_text == "":
		body_text = body_label.text
	set_content(title_text, body_text)


func set_content(new_title: String, new_body: String) -> void:
	dismissed = false
	title_text = new_title
	body_text = new_body

	if not is_node_ready():
		return

	_show_body_label()
	FittedLabel.apply_text(title_label, title_text)
	FittedLabel.apply_text(body_label, body_text)


func dismiss(_action_id: String = "") -> void:
	dismissed = true
	hide()


func update_readability(camera: Camera3D) -> void:
	if camera == null or (drag_handle != null and drag_handle.user_positioned):
		return
	var factor := clampf(camera.global_position.distance_to(global_position) / reading_distance, 1.0, max_distance_scale)
	global_basis = global_basis.orthonormalized().scaled(presentation_scale * factor)


func set_content_values(new_title: String, values: Dictionary) -> void:
	dismissed = false
	title_text = new_title

	if not is_node_ready():
		return

	FittedLabel.apply_text(title_label, title_text)
	if value_lines_root == null or value_line_labels.is_empty():
		_show_body_label()
		FittedLabel.apply_text(body_label, str(values))
		return

	body_label.visible = false
	value_lines_root.visible = true
	for index in range(value_line_labels.size()):
		var label := value_line_labels[index]
		var rendered := TemplateText.render(value_line_templates[index], values)
		label.visible = rendered != ""
		if label.visible:
			FittedLabel.apply_text(label, rendered)


func _show_body_label() -> void:
	body_label.visible = true
	if value_lines_root != null:
		value_lines_root.visible = false


func _collect_value_line_labels() -> void:
	value_line_labels.clear()
	value_line_templates.clear()
	if value_lines_root == null:
		return

	for child in value_lines_root.get_children():
		if child is Label3D:
			var label := child as Label3D
			value_line_labels.append(label)
			value_line_templates.append(label.fitted_text if label is FittedLabel3D else label.text)
