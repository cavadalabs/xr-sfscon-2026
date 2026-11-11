extends SceneTree

func _initialize() -> void:
	var available := Engine.has_singleton("OpenXRFbSpatialEntitySharingExtension") \
		and ClassDB.class_has_method("OpenXRFbSpatialEntity", "share_with_group") \
		and ClassDB.class_has_signal("OpenXRFbSpatialEntity", "openxr_meta_spatial_entity_group_shared") \
		and ClassDB.class_has_method("OpenXRFbSpatialEntitySharingExtension", "is_spatial_entity_group_sharing_supported") \
		and ClassDB.class_has_method("OpenXRFbSpatialEntityQuery", "query_by_group") \
		and ClassDB.class_has_signal("OpenXRFbSpatialEntityQuery", "openxr_fb_spatial_entity_query_completed_with_result")
	if not available:
		push_error("Rebuild the native group-sharing addon before running this check")
		quit(1)
		return
	var extension := Engine.get_singleton("OpenXRFbSpatialEntitySharingExtension")
	if extension.call("is_spatial_entity_group_sharing_supported"):
		push_error("Run native API check with --xr-mode off")
		quit(1)
		return
	Engine.print_error_messages = false # Invalid input must fail before reaching OpenXR.
	var query := OpenXRFbSpatialEntityQuery.new()
	query.call("query_by_group", "invalid-uuid")
	var valid := query.get_storage_location() == OpenXRFbSpatialEntity.STORAGE_CLOUD
	valid = query.execute() != OK and valid
	valid = query.execute() == ERR_ALREADY_IN_USE and valid
	var entity := OpenXRFbSpatialEntity.new()
	valid = not entity.call("share_with_group", "invalid-uuid") and valid
	Engine.print_error_messages = true
	if valid:
		print("Native group API and invalid UUID checks passed")
	else:
		push_error("Native group API input validation failed")
	quit(0 if valid else 1)
