class_name DataCard
extends Node3D

signal selected(item: Dictionary)

const BAR_BOTTOM := -0.10

@export_group("Quick Style")
## Expand this material to change the card background color.
@export var background_material: StandardMaterial3D
## These colors are applied to both the bar and the status label.
@export var available_color := Color("57d68d")
@export var limited_color := Color("f2b84b")
@export var full_color := Color("f06464")
## Controls the tallest possible data bar.
@export_range(0.05, 0.24, 0.01, "suffix:m") var maximum_bar_height := 0.24

@onready var name_label: Label3D = %NameLabel
@onready var value_label: Label3D = %ValueLabel
@onready var status_label: Label3D = %StatusLabel
@onready var background: MeshInstance3D = %Background
@onready var value_bar: MeshInstance3D = %ValueBar

var item: Dictionary


func _ready() -> void:
	# The root Inspector exposes the fastest visual changes in one place.
	background.material_override = background_material


func configure(new_item: Dictionary) -> void:
	item = new_item
	var value := float(item.get("value", 0))
	var capacity := maxf(0.01, float(item.get("capacity", 1)))
	var unit := str(item.get("unit", ""))
	var status := str(item.get("status", "unknown")).to_lower()

	name_label.text = str(item.get("name", "Unnamed item"))
	value_label.text = "%s %s" % [str(item.get("value", 0)), unit]
	status_label.text = "%s · MAX %s" % [status.to_upper(), str(item.get("capacity", 1))]
	var status_color := _color_for_status(status)
	var bar_material := value_bar.material_override.duplicate() as StandardMaterial3D
	bar_material.albedo_color = status_color
	value_bar.material_override = bar_material
	status_label.modulate = status_color

	var height := maximum_bar_height * clampf(value / capacity, 0.0, 1.0)
	value_bar.scale.y = height
	value_bar.position.y = BAR_BOTTOM + height * 0.5


func select() -> void:
	selected.emit(item)


func _on_select_area_input_event(
		_camera: Node,
		event: InputEvent,
		_event_position: Vector3,
		_normal: Vector3,
		_shape_idx: int,
) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		select()


func _color_for_status(status: String) -> Color:
	match status:
		"full":
			return full_color
		"limited":
			return limited_color
		_:
			return available_color
