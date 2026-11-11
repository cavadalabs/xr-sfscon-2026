extends Node3D
class_name WristMenu3D

signal action_selected(action_id: String)
signal visible_models_changed(models: Array)

@export var starts_open := false
@export var show_model_previews := true

@onready var action_buttons: Node3D = $ActionButtons
@onready var model_slots_root: Node = $ActionButtons/ModelSlots
@onready var scroll_controls_root: Node = $ActionButtons/ScrollControls
@onready var control_buttons_root: Node = $ActionButtons/ControlButtons
@onready var touch_interactor: XRHandTouchInteractor3D = $XRHandTouchInteractor
@onready var interactive_controller: Node = $InteractiveCollisionController

var actions: Array[Dictionary] = []
var action_slots: Array[WristMenuModelSlot3D] = []
var scroll_buttons: Array[DemoButton3D] = []
var control_buttons: Array[DemoButton3D] = []
var scroll_index := 0
var selected_action_id := ""


func _ready() -> void:
	_collect_scene_buttons()
	_connect_menu_buttons()
	set_open(starts_open)


func toggle() -> void:
	set_open(not visible)


func set_open(is_open: bool) -> void:
	visible = is_open
	interactive_controller.set_interactive(is_open)
	touch_interactor.set_menu_open(is_open)


func set_actions(new_actions: Array) -> void:
	if not is_node_ready():
		return

	self.actions.clear()
	for action in new_actions:
		if action is Dictionary:
			self.actions.append((action as Dictionary).duplicate(true))

	scroll_index = 0
	_rebuild_action_buttons()


func set_selected_action(action_id: String) -> void:
	selected_action_id = action_id
	if is_node_ready():
		_rebuild_action_buttons()


func set_control_label(action_id: String, title: String, subtitle: String) -> void:
	if not is_node_ready():
		return

	for button in control_buttons:
		if button.demo_id != action_id:
			continue

		button.configure(action_id, title, subtitle, button.accent_color)
		return


func set_control_available(action_id: String, available: bool) -> void:
	for button in control_buttons:
		if button.demo_id == action_id:
			_set_button_available(button, available)


func _rebuild_action_buttons() -> void:
	_clear_touch_target()
	var slot_count: int = action_slots.size()

	for slot_index in range(slot_count):
		var slot: WristMenuModelSlot3D = action_slots[slot_index]
		var action_index: int = scroll_index + slot_index
		var has_action: bool = action_index < actions.size()

		if has_action:
			slot.configure_model(actions[action_index], selected_action_id, show_model_previews)

		_set_button_available(slot, has_action)

	var can_scroll: bool = actions.size() > slot_count
	var page_label := scroll_controls_root.get_node_or_null("PageLabel") as Label3D
	if page_label != null:
		page_label.text = "%d–%d / %d" % [mini(scroll_index + 1, actions.size()), mini(scroll_index + slot_count, actions.size()), actions.size()]
	for button in scroll_buttons:
		_set_button_available(button, can_scroll)

	interactive_controller.set_interactive(visible)
	visible_models_changed.emit(actions.slice(scroll_index, scroll_index + slot_count))


func _set_button_available(button: DemoButton3D, is_available: bool) -> void:
	button.visible = is_available
	if not is_available:
		_set_button_hovered(button, false)
		if button is WristMenuModelSlot3D:
			(button as WristMenuModelSlot3D).clear_model_visuals()
	interactive_controller.set_branch_interactive(button, is_available and visible)


func _collect_scene_buttons() -> void:
	action_slots = _collect_model_slots(model_slots_root)
	scroll_buttons = _collect_demo_buttons(scroll_controls_root)
	control_buttons = _collect_demo_buttons(control_buttons_root)


func _collect_model_slots(root: Node) -> Array[WristMenuModelSlot3D]:
	var result: Array[WristMenuModelSlot3D] = []
	if root == null:
		return result

	for child in root.get_children():
		if child is WristMenuModelSlot3D:
			result.append(child as WristMenuModelSlot3D)

	return result


func _collect_demo_buttons(root: Node) -> Array[DemoButton3D]:
	var result: Array[DemoButton3D] = []
	if root == null:
		return result

	for child in root.get_children():
		if child is DemoButton3D:
			result.append(child as DemoButton3D)

	return result


func _connect_menu_buttons() -> void:
	for button in _get_menu_buttons():
		if not button.pressed.is_connected(_on_button_pressed):
			button.pressed.connect(_on_button_pressed)


func _get_menu_buttons() -> Array[DemoButton3D]:
	var buttons: Array[DemoButton3D] = []
	for slot in action_slots:
		buttons.append(slot)
	buttons.append_array(scroll_buttons)
	buttons.append_array(control_buttons)
	return buttons


func _on_button_pressed(action_id: String) -> void:
	if action_id == "__scroll_prev":
		_scroll_actions(-1)
		return
	if action_id == "__scroll_next":
		_scroll_actions(1)
		return

	action_selected.emit(action_id)


func _scroll_actions(direction: int) -> void:
	var max_scroll: int = maxi(0, actions.size() - action_slots.size())
	scroll_index = clampi(scroll_index + direction, 0, max_scroll)
	_clear_touch_target()
	_rebuild_action_buttons()


func _clear_touch_target() -> void:
	for child in get_children():
		if child is XRHandTouchInteractor3D:
			child.clear_touch_target()


func _set_button_hovered(button: DemoButton3D, is_hovered: bool) -> void:
	if button != null and is_instance_valid(button):
		button.set_hovered(is_hovered)
