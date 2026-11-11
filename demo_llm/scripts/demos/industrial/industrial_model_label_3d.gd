class_name IndustrialModelLabel3D
extends Node3D

const FittedLabel := preload("res://scripts/ui/fitted_label_3d.gd")

@export var loading_template := "%s\nLoading..."
@export var unavailable_template := "%s\nModel unavailable"

@onready var label: Node = $ModelNameLabel


func get_text() -> String:
	return (label as Label3D).text


func set_text(text: String) -> void:
	FittedLabel.apply_text(label as Label3D, text)


func set_loading(title: String) -> void:
	set_text(loading_template % title)


func set_unavailable(title: String) -> void:
	set_text(unavailable_template % title)


func clear() -> void:
	set_text("")
