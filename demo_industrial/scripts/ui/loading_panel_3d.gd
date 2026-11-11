extends Node3D
class_name LoadingPanel3D

const FittedLabel := preload("res://scripts/ui/fitted_label_3d.gd")

@onready var message_label: Node = $MessageLabel

var message := ""


func _ready() -> void:
	if message == "":
		message = (message_label as Label3D).text
	set_message(message)


func set_message(new_message: String) -> void:
	message = new_message
	if is_node_ready():
		FittedLabel.apply_text(message_label as Label3D, message)
