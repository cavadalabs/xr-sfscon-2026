extends Area3D


func pointer_event(event: Variant) -> void:
	if event is XRToolsPointerEvent and event.event_type == XRToolsPointerEvent.Type.PRESSED:
		get_viewport().set_meta("xr_active_hand", XRSurfacePlacement.pointer_hand(event.pointer))
	var parent_node := get_parent()
	if parent_node == null:
		return

	if event is XRToolsPointerEvent and event.event_type == XRToolsPointerEvent.Type.PRESSED and parent_node.has_method("activate"):
		parent_node.call("activate")
		return

	if parent_node.has_method("pointer_event"):
		parent_node.call("pointer_event", event)
