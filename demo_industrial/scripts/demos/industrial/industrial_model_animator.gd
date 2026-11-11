class_name IndustrialModelAnimator
extends Node

@export var play_model_animations := true

var current_animation_player: AnimationPlayer


func clear() -> void:
	current_animation_player = null


func bind_and_play(root_node: Node, animation_name: String) -> void:
	current_animation_player = _find_animation_player(root_node)
	play(animation_name)


func play(animation_name: String) -> void:
	if current_animation_player == null or not play_model_animations:
		return

	var animation_list: PackedStringArray = current_animation_player.get_animation_list()
	if animation_list.is_empty():
		return

	var selected_animation := animation_name
	if selected_animation == "" or not current_animation_player.has_animation(selected_animation):
		selected_animation = animation_list[0]

	var animation: Animation = current_animation_player.get_animation(selected_animation)
	if animation != null:
		animation.loop_mode = Animation.LOOP_LINEAR

	current_animation_player.play(selected_animation)


func _find_animation_player(node: Node) -> AnimationPlayer:
	var players: Array[Node] = node.find_children("*", "AnimationPlayer", true, false)
	return players[0] as AnimationPlayer if not players.is_empty() else null
