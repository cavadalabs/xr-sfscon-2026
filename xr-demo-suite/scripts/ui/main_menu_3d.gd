extends Node3D
class_name MainMenu3D

signal demo_selected(demo_id: String)

@onready var interactive_controller: Node = $InteractiveCollisionController


func _on_demo_button_pressed(demo_id: String) -> void:
	demo_selected.emit(demo_id)


func set_interactive(is_enabled: bool) -> void:
	interactive_controller.set_interactive(is_enabled)
