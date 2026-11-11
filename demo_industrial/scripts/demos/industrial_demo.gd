extends Node3D

signal back_requested

## Transient banner shown over the demo when the shared lobby is closed while
## still connected: the user must understand that "Torna alla demo" keeps them
## in the room and that the menu is one wrist-button away.
const SHARED_BANNER_TEXT := "Sei ancora in stanza · apri Sessione condivisa per il menu"
const SHARED_BANNER_MS := 6000

@onready var wrist_menu: WristMenu3D = $WristMenu3D
@onready var info_panel: InfoPanel3D = $InfoPanel3D
@onready var model_viewer: IndustrialModelViewer3D = $IndustrialModelViewer
@onready var industrial_catalog: IndustrialCatalog = $TechnicalNodes/IndustrialCatalog
@onready var qr_controller: IndustrialQRController = $TechnicalNodes/IndustrialQRController
@onready var model_placement_controller: IndustrialModelPlacementController = $TechnicalNodes/IndustrialModelPlacementController
@onready var model_loading_controller: IndustrialModelLoadingController = $TechnicalNodes/IndustrialModelLoadingController
@onready var shared_state: Node = get_tree().get_first_node_in_group("shared_state")
@onready var shared_lobby: Node = $WristMenu3D/ActionButtons/SharedLobbyPanel
var collection := "furniture"
var brand := ""
var info_model_viewer: IndustrialModelViewer3D
var initial_layout_presented := false
var _shared_banner_until := 0


func _ready() -> void:
	info_panel.drag_handle.present_on_show = true
	info_panel.drag_handle.face_camera = true
	info_panel.drag_handle.view_offset = Vector3(2.25, -0.2, -1.8)
	info_panel.visibility_changed.connect(_on_info_panel_visibility_changed)
	wrist_menu.visible_models_changed.connect(model_loading_controller.preload_visible_models)
	model_placement_controller.placement_cancelled.connect(model_loading_controller.stop)
	model_placement_controller.model_state_changed.connect(_sync_model_controls)
	model_loading_controller.feedback_changed.connect(_sync_model_controls)
	info_model_viewer = model_viewer
	qr_controller.info_viewer_selected.connect(func(viewer: IndustrialModelViewer3D): info_model_viewer = viewer)
	model_viewer.model_loading_finished.connect(model_placement_controller.on_model_loaded)
	model_viewer.model_loading_finished.connect(_sync_model_controls)
	model_viewer.model_loading_started.connect(_sync_model_controls)
	model_viewer.hotspot_selected.connect(_on_hotspot_selected)
	if shared_state != null:
		shared_state.setup_context(model_viewer, model_placement_controller, industrial_catalog)
		shared_state.status_changed.connect(func(message: String): FittedLabel3D.apply_text($PlacementStatus, message))
		shared_state.connection_changed.connect(_refresh_shared_button)
	shared_lobby.closed.connect(_close_shared_view)
	shared_lobby.view_changed.connect(_on_shared_view_changed)
	model_placement_controller.status_changed.connect(func(message: String): FittedLabel3D.apply_text($PlacementStatus, message))
	industrial_catalog.load_catalog()


func _process(_delta: float) -> void:
	if not initial_layout_presented:
		var camera := get_viewport().get_camera_3d()
		if Engine.get_process_frames() % 60 == 0:
			XrDiag.log("gate", "cam=%s xr_camera=%s head_tracked=%s" % [camera != null, camera is XRCamera3D, XRSurfacePlacement.is_head_tracked()])
		if camera != null and (not camera is XRCamera3D or XRSurfacePlacement.is_head_tracked()):
			_present_initial_layout(camera)
	$PlacementStatus.global_transform = wrist_menu.global_transform * Transform3D(Basis.IDENTITY, Vector3(0, -1.63, 0.08))
	if _shared_banner_until > 0 and Time.get_ticks_msec() > _shared_banner_until:
		_shared_banner_until = 0
		if $PlacementStatus.text == SHARED_BANNER_TEXT:
			$PlacementStatus.text = ""
	var item = model_placement_controller.selected_furniture
	var show := false
	var info_viewer := info_model_viewer if is_instance_valid(info_model_viewer) else model_viewer
	if item != null and info_viewer == model_viewer and not model_placement_controller.placement_mode:
		show = true
	elif info_viewer.visible and not info_viewer.ghost_enabled and info_viewer.current_model_path != "":
		show = true
	info_panel.visible = show and not info_panel.dismissed
	if info_panel.visible:
		info_panel.update_readability(get_viewport().get_camera_3d())


func _present_initial_layout(camera: Camera3D) -> void:
	var forward := -camera.global_basis.z
	forward.y = 0
	if forward.length_squared() < 0.001:
		return
	var facing := Basis.looking_at(forward.normalized())
	var origin := camera.global_position + facing * Vector3(1.1, 0, -2.8)
	origin.y = model_viewer.global_position.y
	model_viewer.global_transform = Transform3D(facing, origin)
	model_placement_controller.default_model_viewer_transform = model_viewer.global_transform
	# The wrist menu is driven by its follower, not by a drag handle: the
	# handle only exists on scenes that present it (e.g. the playground).
	var handle := wrist_menu.get_node_or_null("DragHandle") as XRPanelDragHandle3D
	if handle != null:
		handle.present_to(camera)
	info_panel.drag_handle.present_to(camera)
	var xr_origin := camera.get_parent() as XROrigin3D
	XrDiag.log("layout", "cam=%s parent=%s origin_ok=%s" % [camera.get_class(),
		camera.get_parent().name if camera.get_parent() != null else "none", xr_origin != null])
	if xr_origin != null and shared_state != null:
		shared_state.setup_xr(xr_origin, camera)
	initial_layout_presented = true


func _open_shared_view() -> void:
	_set_catalog_content_visible(false)
	model_placement_controller.selection_blocked = true
	shared_lobby.open()


func _close_shared_view() -> void:
	shared_lobby.visible = false
	model_placement_controller.selection_blocked = false
	_set_catalog_content_visible(true)
	# The lobby branch is hidden now: re-run the pass so the catalog buttons
	# recover their collision layers (the controller respects visibility).
	wrist_menu.interactive_controller.set_interactive(true)
	if shared_state != null and shared_state.active():
		_show_shared_banner()


func _show_shared_banner() -> void:
	FittedLabel3D.apply_text($PlacementStatus, SHARED_BANNER_TEXT)
	_shared_banner_until = Time.get_ticks_msec() + SHARED_BANNER_MS


## The wrist button doubles as the room status light: connected users see
## "In Stanza" plus the code so they know the menu is one tap away, not a
## new connection to make. The title is the whole meaning on two lines
## (the subtitle is deliberately empty: it was the unreadable part).
func _refresh_shared_button() -> void:
	var button := wrist_menu.get_node_or_null("ActionButtons/ControlButtons/Shared") as DemoButton3D
	if button == null:
		return
	var in_room: bool = shared_state != null and shared_state.active()
	if in_room:
		button.title_text = "In Stanza\n%s" % shared_state.room_code()
	else:
		button.title_text = "Esperienza\nCondivisa"
	button.subtitle_text = ""
	button._sync_view()


func _on_shared_view_changed() -> void:
	# The collision controller respects Node3D visibility: the newly visible
	# lobby branch only gets its collision layers back after a fresh pass.
	wrist_menu.interactive_controller.set_interactive(true)


func _set_catalog_content_visible(value: bool) -> void:
	for content_path in [
		"TitleLabel",
		"HintLabel",
		"ActionButtons/ModelSlots",
		"ActionButtons/ScrollControls",
		"ActionButtons/ControlButtons",
	]:
		var content := wrist_menu.get_node_or_null(NodePath(content_path))
		if content != null:
			content.visible = value


func _on_info_panel_visibility_changed() -> void:
	wrist_menu.interactive_controller.set_branch_interactive(info_panel, info_panel.is_visible_in_tree())


func _exit_tree() -> void:
	if shared_state != null:
		shared_state.detach_context()
	model_placement_controller.stop()
	model_loading_controller.stop()
	model_viewer.clear_viewer()
	wrist_menu.visible = false


func _on_back_button_pressed(_demo_id: String) -> void:
	back_requested.emit()


func _on_model_placement_back_requested() -> void:
	back_requested.emit()


func _on_wrist_menu_action_selected(action_id: String) -> void:
	if action_id.begins_with("__collection_"):
		brand = ""
		collection = action_id.trim_prefix("__collection_")
		model_placement_controller.cancel_placement()
		_update_catalog_actions()
		return
	if action_id.begins_with("__brand_"):
		brand = action_id.trim_prefix("__brand_")
		collection = "furniture" if false else "industrial"
		model_placement_controller.cancel_placement()
		_update_catalog_actions()
		return
	if action_id == "model_info":
		info_model_viewer = model_viewer
		var data := model_placement_controller.get_model_data()
		info_panel.set_content_values(industrial_catalog.get_model_title(data), industrial_catalog.get_model_info_values(data))
		return
	if action_id == "toggle_animation":
		var player := _active_animation_player()
		if player != null:
			var animation := player.assigned_animation
			if player.is_playing():
				player.pause()
				_shared_submit_anim(player, "", false)
			else:
				if animation == "" and not player.get_animation_list().is_empty():
					animation = player.get_animation_list()[0]
				if animation != "":
					player.play(animation)
					_shared_submit_anim(player, animation, true)
		return
	if action_id == "shared_session":
		_open_shared_view()
		return
	if model_placement_controller.handle_action(action_id):
		return

	industrial_catalog.select_model_id(action_id)


func _on_catalog_loaded(models: Array) -> void:
	_update_catalog_actions()
	model_placement_controller.sync_control_labels()
	var handled_pending_qr := qr_controller.set_catalog_ready()
	model_loading_controller.load_default_model_after_catalog(models, handled_pending_qr)


func _on_catalog_model_selected(model_data: Dictionary, title: String) -> void:
	info_model_viewer = model_viewer
	var selected_model_id: String = str(model_data.get("id", ""))
	if not model_placement_controller.selecting_placed:
		model_placement_controller.prepare_selection()
	else:
		model_loading_controller.stop()
	var selected_collection := str(model_data.get("collection", "industrial"))
	var selected_brand := str(model_data.get("brand", ""))
	if selected_collection != collection or selected_brand != brand:
		collection = selected_collection
		brand = selected_brand
		_update_catalog_actions()

	wrist_menu.set_selected_action(selected_model_id)
	if not model_placement_controller.selecting_placed:
		model_viewer.set_model_data(model_data)
	else:
		_sync_model_controls()
	info_panel.set_content_values(title, industrial_catalog.get_model_info_values(model_data))

	var context_provider := get_tree().get_first_node_in_group("xr_context_provider") as XRContextProvider
	if context_provider != null:
		context_provider.set_selected_model(model_data)


func _update_catalog_actions() -> void:
	wrist_menu.set_actions(industrial_catalog.models.filter(func(model: Dictionary): return model.get("brand", "") == brand if brand != "" else model.get("collection", "industrial") == collection and model.get("brand", "") == ""))
	_sync_model_controls()
	wrist_menu.get_node("TitleLabel").text = brand.to_upper() if brand != "" else ("ARREDI" if collection == "furniture" else "CATALOGO 3D")
	for button: DemoButton3D in wrist_menu.control_buttons:
		if button.demo_id.begins_with("__brand_") or button.demo_id.begins_with("__collection_"):
			var active := button.demo_id == ("__brand_" + brand if brand != "" else "__collection_" + collection)
			button.accent_mix = 0.55 if active else 0.16
			button._apply_button_color()


func _on_hotspot_selected(info: Dictionary) -> void:
	info_model_viewer = model_viewer
	info_panel.set_content(str(info.get("title", "Componente")), str(info.get("body", "")))
	FittedLabel3D.apply_text($PlacementStatus, "Dettaglio componente · Scheda per tornare alla panoramica")


func _sync_model_controls(_unused: Variant = null) -> void:
	var data := model_placement_controller.get_model_data()
	var selected := model_placement_controller.selected_furniture != null
	var loading := model_viewer.model_loader.pending_model_path != ""
	var available := not data.is_empty() and not loading and (selected or model_viewer.visible)
	var furniture := model_placement_controller.is_furniture()
	for action in ["place_model", "model_info"]:
		wrist_menu.set_control_available(action, available)
	wrist_menu.set_control_available("cancel_placement", (loading and model_loading_controller.feedback_visible) or model_placement_controller.placement_mode)
	wrist_menu.get_node("HintLabel").text = "Caricamento del modello…" if loading and model_loading_controller.feedback_visible else "Scegli un prodotto"
	for action in ["scale_down", "scale_up"]:
		wrist_menu.set_control_available(action, available and not data.get("real_scale", false))
	wrist_menu.set_control_available("reset_model", available and not furniture)
	for action in ["delete_model", "duplicate_model"]:
		wrist_menu.set_control_available(action, available and selected)
	var player := _active_animation_player()
	wrist_menu.set_control_available("toggle_animation", available and player != null and not player.get_animation_list().is_empty())


func _active_animation_player() -> AnimationPlayer:
	var item = model_placement_controller.selected_furniture
	if is_instance_valid(item) and not model_placement_controller.placement_mode:
		var players := item.find_children("*", "AnimationPlayer", true, false)
		return players[0] as AnimationPlayer if not players.is_empty() else null
	return model_viewer.model_animator.current_animation_player


func _shared_submit_anim(_player: AnimationPlayer, animation: String, playing: bool) -> void:
	if shared_state == null or not shared_state.active():
		return
	var item = model_placement_controller.selected_furniture
	if not is_instance_valid(item) or model_placement_controller.placement_mode \
			or item.net_id < 0:
		return  # The hero and its animations are local: only placed items sync.
	shared_state.submit_anim(item.net_id, animation, playing)
