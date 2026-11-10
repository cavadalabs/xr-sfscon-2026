extends SceneTree


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	assert(ProjectSettings.get_setting("xr/openxr/extensions/hand_tracking") == true)
	assert(ProjectSettings.get_setting("xr/openxr/extensions/hand_interaction_profile") == true)
	_verify_hand_action_map()
	_verify_api_mapping()

	var main: Node = load("res://scenes/main.tscn").instantiate()
	var data_source := main.get_node("DataSource") as DataSource
	assert(data_source != null)
	var use_live := "--live" in OS.get_cmdline_user_args()
	data_source.use_live_data = use_live
	root.add_child(main)

	if use_live:
		if main.source_label.text == "CONNECTING TO OPEN DATA HUB…":
			await main.data_request.request_completed
		await process_frame
		assert(main.source_label.text == "LIVE · OPEN DATA HUB")
		assert(main.cards.size() >= 5 and main.cards.size() <= 6)
	else:
		await process_frame
		assert(main.source_label.text == "LOCAL · SAMPLE")
		assert(main.cards.size() == 6)
		data_source.use_live_data = true
		main._on_data_request_completed(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())
		await process_frame
		assert(main.source_label.text == "OFFLINE · LOCAL FALLBACK")

	assert(main.detail_name.text == main.cards[0].item["name"])
	assert(main.dataset_title.text == data_source.dataset_title)

	var first_card := main.cards[0] as DataCard
	var background := first_card.get_node("Background") as MeshInstance3D
	assert(background.get_active_material(0) == first_card.background_material)
	var bar_material := first_card.value_bar.get_active_material(0) as StandardMaterial3D
	var expected_color := first_card._color_for_status(str(first_card.item["status"]).to_lower())
	assert(bar_material.albedo_color == expected_color)
	assert(first_card.status_label.modulate == expected_color)
	var expected_height := first_card.maximum_bar_height * clampf(
		float(first_card.item["value"]) / float(first_card.item["capacity"]), 0.0, 1.0
	)
	assert(is_equal_approx(first_card.value_bar.scale.y, expected_height))

	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	var mouse_target: StaticBody3D = main.cards[1].get_node("SelectArea")
	mouse_target.input_event.emit(null, click, Vector3.ZERO, Vector3.ZERO, 0)
	assert(main.detail_name.text == main.cards[1].item["name"])

	var hand_target: StaticBody3D = main.cards[2].get_node("SelectArea")
	main.xr_ray.global_position = hand_target.global_position + Vector3(0, 0, 1)
	main.xr_ray.look_at(hand_target.global_position)
	main.xr_ray.enabled = true
	main.xr_ray.force_raycast_update()
	assert(main.xr_ray.is_colliding())
	main.get_node("XROrigin3D/RightHandPointer").button_pressed.emit("select")
	assert(main.detail_name.text == main.cards[2].item["name"])
	quit()


func _verify_api_mapping() -> void:
	var source := DataSource.new()
	source.items_array_path = "results"
	source.name_path = "label"
	source.value_path = "reading.current"
	source.capacity_path = "limits.maximum"
	source.description_path = "summary"
	source.unit_text = "places"

	var body := JSON.stringify({"results": [
		{"label": "Full", "reading": {"current": 0}, "limits": {"maximum": 100}, "summary": "None free."},
		{"label": "Limited", "reading": {"current": "20"}, "limits": {"maximum": 100}, "summary": "Few free."},
		{"label": "Available", "reading": {"current": 60}, "limits": {"maximum": 100}, "summary": "Many free."},
	]}).to_utf8_buffer()
	var items := source.items_from_api(body)
	assert(items.size() == 3)
	assert(items[0]["name"] == "Full")
	assert(items[0]["unit"] == "places")
	assert(items[0]["description"] == "None free.")
	assert(items[0]["status"] == "full")
	assert(items[1]["status"] == "limited")
	assert(items[2]["status"] == "available")

	# A root JSON array and one fixed maximum also work without code changes.
	source.items_array_path = ""
	source.capacity_path = ""
	source.maximum_value = 80.0
	var fixed := source.items_from_api(JSON.stringify([
		{"label": "Fixed", "reading": {"current": 40}, "summary": "Example."},
	]).to_utf8_buffer())
	assert(fixed.size() == 1)
	assert(fixed[0]["capacity"] == 80)
	source.free()


func _verify_hand_action_map() -> void:
	var action_map: OpenXRActionMap = load("res://openxr_action_map.tres")
	var hand_bindings := {}
	for profile in action_map.interaction_profiles:
		if profile.interaction_profile_path != "/interaction_profiles/ext/hand_interaction_ext":
			continue
		for binding in profile.bindings:
			hand_bindings[binding.binding_path] = binding.action.resource_name

	assert(hand_bindings.get("/user/hand/right/input/aim/pose") == "aim")
	assert(hand_bindings.get("/user/hand/right/input/pinch_ext/value") == "select")
