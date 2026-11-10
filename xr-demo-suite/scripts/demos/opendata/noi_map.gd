extends Node3D
class_name NoiMap3D

signal room_selected(room_data: Dictionary)

const BUTTON := preload("res://scenes/ui/DemoButton3D.tscn")

@export_group("Comportamento")
## Larghezza della mappa in scala (metri): il modello viene rimpicciolito a questa misura.
@export var map_width := 1.8
## Sollevamento del modello rispetto alla base della mappa (metri).
@export var model_lift := 0.025
@export_range(1.0, 12.0, 0.5) var label_follow_speed := 5.0
@export_range(0.05, 0.6, 0.01) var marker_label_gap := 0.45
@export var minimum_zoom := 0.5
@export var maximum_zoom := 2.0
@export_range(0.1, 1.0, 0.05) var architecture_lod_bias := 0.5

@export_group("Colori")
## Colore del beacon quando le misure della stanza sono recenti.
@export var live_color := Color(0.22, 0.88, 0.68)
## Colore neutro: misure non recenti o nessun dato.
@export var muted_color := Color(0.42, 0.53, 0.62)
## Colore delle etichette edificio non selezionate (chiaro per contrasto sul plastico).
@export var building_label_unselected_color := Color(0.82, 0.88, 0.95)
## Colore del bottone stanza senza stato (azzurro base).
@export var room_button_color := Color(0.3, 0.65, 0.85)
## Colore del campus in modalità "trasparente" (semitrasparente).
@export var ghost_color := Color(0.45, 0.65, 0.74, 0.28)
## Colore dei piani in modalità stanza.
@export var zone_color := Color(0.48, 0.64, 0.70)
## Colore della stanza selezionata.
@export var selected_zone_color := Color(0.5, 0.76, 1.0)
## Emissione della stanza selezionata.
@export var selected_zone_emission := Color(0.1, 0.25, 0.4)
## Colore del volume semitrasparente dell'area selezionata.
@export var region_fill_color := Color(0.18, 0.62, 1.0, 0.18)
## Opacità del contorno dell'area selezionata (0-1).
@export_range(0.0, 1.0, 0.05) var region_outline_alpha := 0.9

@export_group("Beacon e marker")
## Quanto sporge il beacon sopra il volume selezionato (metri).
@export var beacon_height_offset := 0.025
## Raggio della sfera del beacon (metri).
@export var beacon_radius := 0.012
## Dimensione fisica del testo delle etichette edificio (metri per pixel).
@export var building_label_pixel_size := 0.25
## Dimensione del font delle etichette edificio (punti).
@export var building_label_font_size := 34
## Sollevamento dell'etichetta sopra l'edificio (unità del modello campus).
@export var building_label_lift := 6.0
## Dimensione fisica del testo del beacon (metri per pixel).
@export var beacon_label_pixel_size := 0.0013
## Colore del testo del beacon quando le misure non sono recenti.
@export var beacon_label_muted_color := Color(0.65, 0.82, 0.94)

@export_group("Bottoni stanza")
## Posizione del primo bottone stanza (metri, nella mappa).
@export var room_buttons_start := Vector3(-1.07, 0.28, 0.05)
## Distanza verticale fra due bottoni stanza (metri).
@export var room_buttons_step := 0.34
## Dimensione dei bottoni stanza.
@export var room_button_size := Vector3(0.84, 0.82, 0.7)

@onready var title: Label3D = $MapTitleLabel
@onready var legend: Label3D = $LegendLabel
@onready var controls: Node3D = $Controls
@onready var base: MeshInstance3D = $MapBase

var selected_room_id := ""
var selected_building := "A1"
var selected_floor := 1
var architecture := false
var floor_view := false
var rooms: Array = []
var manifest: Dictionary = {}
var building_descriptions: Dictionary = {}
var campus: Node3D
var campus_details: Node3D
var floor_model: Node3D
var building_buttons: Dictionary = {}
var data_buttons: Dictionary = {}
var nav_buttons: Dictionary = {}
var zone_buttons: Array[DemoButton3D] = []
var failed_paths: Dictionary = {}
var pending_path := ""
var pending_started := 0
var wanted_floor_path := ""
var current_floor_path := ""
var load_timings: Dictionary = {}
var bounds_helper := IndustrialModelBounds.new()
var interaction: InteractiveCollisionController3D
const InteractiveCollisionControllerScene := preload("res://scenes/ui/InteractiveCollisionController3D.tscn")
const DataBeaconScene := preload("res://scenes/demos/opendata/DataBeacon.tscn")
var ghost := StandardMaterial3D.new()
var zone_material := StandardMaterial3D.new()
var selected_zone_material := StandardMaterial3D.new()
var data_beacon: MeshInstance3D
var data_beacon_label: Label3D
var data_beacon_root: Node3D
@onready var selection_root: Node3D = $SelectionRoot
var selection_regions: Dictionary = {}
var region_nodes: Dictionary = {}
var gestures: XRModelRotationController3D
var pending_selection: Callable
var selection_hand := "right"
var facing_labels: Array[Label3D] = []


func _ready() -> void:
	facing_labels.append(title)
	manifest = ApiClient.load_json_file("res://assets/models/noi/manifest.json")
	building_descriptions = ApiClient.load_json_file("res://data/noi_buildings.json")
	add_child(bounds_helper)
	interaction = InteractiveCollisionControllerScene.instantiate()
	add_child(interaction)
	selection_regions = ApiClient.load_json_file("res://data/noi_selection_regions.json").get("regions", {})
	ghost.albedo_color = ghost_color
	ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost.roughness = 0.95
	ghost.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	zone_material.albedo_color = zone_color
	zone_material.roughness = 1.0
	selected_zone_material.albedo_color = selected_zone_color
	selected_zone_material.emission_enabled = true
	selected_zone_material.emission = selected_zone_emission
	# The five nav buttons live in NoiMap.tscn under Controls; here we only wire them.
	for button: DemoButton3D in controls.get_children():
		button.pressed.connect(_on_action)
		nav_buttons[button.demo_id] = button
	visibility_changed.connect(_sync_interaction)
	_request_load(str(manifest.ghost.path))
	_sync_controls()


func set_rooms(new_rooms: Array) -> void:
	rooms = new_rooms.duplicate(true)
	for i in rooms.size():
		var room: Dictionary = rooms[i]
		var id := str(room.id)
		if not data_buttons.has(id):
			var button := _button(controls, id, str(room.name), "", room_buttons_start + Vector3(0, -i * room_buttons_step, 0), room_button_size)
			button.pressed.connect(_select_data)
			data_buttons[id] = button
		var fresh := not (room.get("measurements", {}) as Dictionary).is_empty()
		data_buttons[id].configure(id, str(room.name), "Apri misure", live_color if fresh else room_button_color)
	_sync_controls()


func set_selected_room_id(room_id: String) -> void:
	selected_room_id = room_id
	_apply_materials()
	_sync_controls()


func _select_data(id: String) -> void:
	for room: Dictionary in rooms:
		if str(room.id) == id:
			selected_room_id = id
			if not floor_view:
				selected_building = str(room.building)
				selected_floor = int(room.floor)
			room_selected.emit(room)
			_sync_controls()
			return


func _on_action(id: String) -> void:
	match id:
		"campus":
			failed_paths.clear()
			if campus == null:
				_request_load(str(manifest.ghost.path))
			floor_view = false
			wanted_floor_path = ""
			if floor_model != null:
				floor_model.queue_free()
				floor_model = null
				current_floor_path = ""
				zone_buttons.clear()
		"open":
			show_floor()
		"colors":
			failed_paths.erase(str(manifest.campus.path))
			architecture = not architecture
			_apply_materials()
		"previous", "next":
			var floors: Array = manifest.buildings[selected_building].floors.keys()
			floors.sort_custom(func(a, b): return int(a) < int(b))
			if not floors.is_empty():
				var index := floors.find(str(selected_floor))
				selected_floor = int(floors[clampi(index + (-1 if id == "previous" else 1), 0, floors.size() - 1)])
				show_floor()
	_sync_controls()


func select_building(code: String) -> void:
	selected_building = code
	var floors: Dictionary = manifest.buildings[code].floors
	selected_floor = 1 if floors.has("1") else (int(floors.keys()[0]) if not floors.is_empty() else 0)
	_show_building_description()
	_sync_controls()


func show_floor() -> void:
	var floors: Dictionary = manifest.buildings[selected_building].floors
	if not floors.has(str(selected_floor)):
		return
	floor_view = true
	_clear_unrelated_selection()
	wanted_floor_path = str(floors[str(selected_floor)].path)
	failed_paths.erase(wanted_floor_path)
	# Remove the previous level immediately: never label it as the newly selected floor.
	if floor_model != null and wanted_floor_path != current_floor_path:
		floor_model.queue_free()
		floor_model = null
		zone_buttons.clear()
		current_floor_path = ""
	_sync_controls()


func _request_load(path: String) -> void:
	if not pending_path.is_empty() or failed_paths.has(path):
		return
	if ResourceLoader.load_threaded_request(path, "PackedScene", true) != OK:
		failed_paths[path] = true
		title.text = "Modello non disponibile · torna al campus"
		return
	pending_path = path
	pending_started = Time.get_ticks_msec()


func _process(delta: float) -> void:
	_face_labels(delta)
	if pending_selection.is_valid():
		var sample := XRModelRotationController3D.hand_sample(selection_hand)
		if not XRModelRotationController3D.usable(sample) or (gestures != null and (gestures.dragging or gestures.rotating or gestures.consumed)):
			pending_selection = Callable()
		elif XRModelRotationController3D.pinch_open(sample):
			pending_selection.call()
			pending_selection = Callable()
	if not pending_path.is_empty():
		var progress := []
		var state := ResourceLoader.load_threaded_get_status(pending_path, progress)
		if state == ResourceLoader.THREAD_LOAD_LOADED:
			var path := pending_path
			var packed := ResourceLoader.load_threaded_get(path) as PackedScene
			pending_path = ""
			if packed == null:
				title.text = "Modello non disponibile"
				return
			if path == str(manifest.ghost.path):
				campus = packed.instantiate()
				add_child(campus)
				_fit_model(campus)
				_build_building_targets()
				_build_selection_regions()
			elif path == str(manifest.campus.path) and architecture and not floor_view:
				campus_details = packed.instantiate()
				add_child(campus_details)
				campus_details.transform = campus.transform
			elif floor_view and path == wanted_floor_path:
				floor_model = packed.instantiate()
				add_child(floor_model)
				current_floor_path = path
				_fit_model(floor_model)
				_build_zone_targets()
			load_timings[path] = Time.get_ticks_msec() - pending_started
			_apply_materials()
			_sync_controls()
		elif state == ResourceLoader.THREAD_LOAD_FAILED or state == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			failed_paths[pending_path] = true
			pending_path = ""
			wanted_floor_path = ""
			title.text = "Caricamento non riuscito · torna al campus"
		else:
			title.text = "Caricamento %s · %d%%" % ["campus" if campus == null else "piano", int((progress[0] if not progress.is_empty() else 0.0) * 100)]
	if pending_path.is_empty() and campus != null and floor_view and not wanted_floor_path.is_empty() and current_floor_path != wanted_floor_path:
		_request_load(wanted_floor_path)
	elif pending_path.is_empty() and campus != null and not floor_view and architecture and campus_details == null:
		_request_load(str(manifest.campus.path))


func set_zoom(value: float) -> void:
	if not is_finite(value):
		return
	scale = Vector3.ONE * clampf(value, minimum_zoom, maximum_zoom)
	_sync_selection()


func _face_labels(delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	var alpha := 1.0 - exp(-label_follow_speed * minf(delta, 0.1))
	title.pixel_size = 0.0018 / global_basis.get_scale().x
	for label: Label3D in facing_labels:
		if not label.is_visible_in_tree():
			continue
		var previous := label.global_basis.orthonormalized()
		# Face the head's position about this label's own vertical axis. Turning
		# the headset in place must not spin world-space text with its view plane.
		XRSurfacePlacement.orient_node_to_camera_yaw(label, camera)
		label.global_basis = previous.slerp(label.global_basis.orthonormalized(), alpha).scaled(label.global_basis.get_scale())


func _fit_model(model: Node3D) -> void:
	var bounds := bounds_helper.get_cached_bounds({}, str(model.name), model, model)
	var factor := map_width / maxf(bounds.size.x, bounds.size.z)
	model.scale = Vector3.ONE * factor
	model.position = -bounds.get_center() * factor
	model.position.y = -bounds.position.y * factor + model_lift


func _build_building_targets() -> void:
	for code: String in manifest.buildings:
		var entry: Dictionary = manifest.buildings[code]
		var lo := Vector3(entry.min[0], entry.min[1], entry.min[2])
		var hi := Vector3(entry.max[0], entry.max[1], entry.max[2])
		var center := (lo + hi) * 0.5
		var button := _button(campus, code, code, "", center, Vector3.ONE)
		button.get_node("Body").hide()
		button.get_node("SubtitleLabel").hide()
		var label := button.get_node("TitleLabel") as Label3D
		label.position = Vector3(0, (hi.y - lo.y) * 0.5 + building_label_lift, 0)
		label.pixel_size = building_label_pixel_size
		label.font_size = building_label_font_size
		label.outline_size = 12  # contorno nero di default (outline_modulate) per contrasto
		facing_labels.append(label)
		var shape := BoxShape3D.new()
		shape.size = hi - lo
		button.get_node("HitArea/HitShape").shape = shape
		button.add_to_group("xr_manipulable")
		button.pressed.connect(func(id: String): _select_or_grab(select_building.bind(id)))
		building_buttons[code] = button


func _build_zone_targets() -> void:
	for mesh: MeshInstance3D in floor_model.find_children("*", "MeshInstance3D", true, false):
		var extras: Dictionary = mesh.get_meta("extras", {})
		if not extras.has("room_id"):
			continue
		var bounds := mesh.get_aabb()
		var button := _button(mesh, str(extras.room_id), "", "", bounds.get_center(), Vector3.ONE)
		button.get_node("Body").hide()
		button.get_node("TitleLabel").hide()
		button.get_node("SubtitleLabel").hide()
		# Actual floor polygon, not a box extending across neighbouring rooms.
		var shape := mesh.mesh.create_trimesh_shape()
		button.get_node("HitArea/HitShape").shape = shape
		button.get_node("HitArea/HitShape").position = -bounds.get_center()
		button.add_to_group("xr_manipulable")
		button.pressed.connect(func(id: String): _select_or_grab(_select_zone.bind(id)))
		zone_buttons.append(button)


func _select_zone(id: String) -> void:
	# The Lab has a public place reference; the A1 sensor has no room mapping.
	if id == "A1-1-33-B":
		_select_data("noi_free_software_lab")
		return
	selected_room_id = id
	var description := _building_data()
	description["id"] = id
	description["room_id"] = id
	room_selected.emit(description)
	_apply_materials()
	_sync_controls()


func _select_or_grab(action: Callable) -> void:
	selection_hand = str(get_viewport().get_meta("xr_active_hand", "right"))
	if XRModelRotationController3D.is_hand_input(selection_hand):
		pending_selection = action # A short pinch selects on release; a grab keeps the selection.
	else:
		action.call()


func _build_selection_regions() -> void:
	for id: String in selection_regions:
		var region: Dictionary = selection_regions[id]
		var fill := SurfaceTool.new()
		fill.begin(Mesh.PRIMITIVE_TRIANGLES)
		var edges := ImmediateMesh.new()
		edges.surface_begin(Mesh.PRIMITIVE_LINES)
		for volume: Dictionary in region.volumes:
			var points: Array = volume.v
			var vertices: Array[Vector3] = []
			for height: float in [volume.bottom, volume.top]:
				for point: Array in points:
					vertices.append(Vector3(point[0], height, -point[1]))
			for face: Array in volume.f:
				for index: int in face:
					fill.add_vertex(vertices[index])
				for index: int in face:
					fill.add_vertex(vertices[index + points.size()])
			for ring: Array in volume.rings:
				for i in ring.size():
					var a := int(ring[i])
					var b := int(ring[(i + 1) % ring.size()])
					var c := a + points.size()
					var d := b + points.size()
					for index: int in [a, b, c, b, d, c]:
						fill.add_vertex(vertices[index])
					for index: int in [a, b, c, d, a, c]:
						edges.surface_add_vertex(vertices[index])
		edges.surface_end()
		var mesh := MeshInstance3D.new()
		mesh.mesh = fill.commit()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.no_depth_test = true
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = region_fill_color
		material.render_priority = 2
		mesh.material_override = material
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		selection_root.add_child(mesh)
		var outline := MeshInstance3D.new()
		outline.mesh = edges
		outline.material_override = material.duplicate()
		outline.material_override.albedo_color.a = region_outline_alpha
		outline.material_override.render_priority = 3
		mesh.add_child(outline)
		region_nodes[id] = mesh
		# Le due stanze con dati live non hanno un marker fluttuante: il
		# plastico mostra solo le etichette edificio, la selezione avviene
		# dal menu (i pulsanti in data_buttons).
	data_beacon_root = DataBeaconScene.instantiate()
	data_beacon = data_beacon_root.get_node("Beacon") as MeshInstance3D
	data_beacon_label = data_beacon_root.get_node("Label") as Label3D
	selection_root.add_child(data_beacon_root)
	facing_labels.append(data_beacon_label)


func _sync_selection() -> void:
	if campus == null or data_beacon == null:
		return
	selection_root.transform = floor_model.transform if floor_view and floor_model != null else campus.transform
	var active: MeshInstance3D
	for id: String in region_nodes:
		var region: Dictionary = selection_regions[id]
		var in_view: bool = not floor_view or (floor_model != null and current_floor_path == wanted_floor_path and region.building == selected_building and int(region.floor) == selected_floor)
		region_nodes[id].visible = id == selected_room_id and in_view
		if region_nodes[id].visible:
			active = region_nodes[id]
	data_beacon.visible = active != null
	data_beacon_label.visible = active != null
	if active == null:
		return
	var bounds := active.get_aabb()
	var factor := selection_root.global_basis.get_scale().x
	data_beacon.position = Vector3(bounds.get_center().x, bounds.end.y + beacon_height_offset / factor, bounds.get_center().z)
	data_beacon.scale = Vector3.ONE * beacon_radius / factor
	data_beacon_label.position = data_beacon.position + Vector3.UP * marker_label_gap / factor
	data_beacon_label.pixel_size = beacon_label_pixel_size / factor
	data_beacon_label.text = "Area del Lab" if selected_room_id == "noi_free_software_lab" else "Piano 1"
	var fresh := false
	for room: Dictionary in rooms:
		if str(room.id) == selected_room_id:
			fresh = not (room.get("measurements", {}) as Dictionary).is_empty()
	data_beacon.material_override.albedo_color = live_color if fresh else muted_color
	data_beacon_label.modulate = live_color if fresh else beacon_label_muted_color


func _apply_materials() -> void:
	for model in [campus, campus_details, floor_model]:
		if model == null:
			continue
		for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
			if mesh.get_parent() is DemoButton3D:
				continue
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if model == campus:
				mesh.visible = not (architecture and campus_details != null)
				mesh.material_override = ghost
			elif model == campus_details:
				mesh.lod_bias = architecture_lod_bias
			elif model == floor_model:
				var extras: Dictionary = mesh.get_meta("extras", {})
				mesh.material_override = selected_zone_material if extras.get("room_id", "") == selected_room_id else (null if architecture else zone_material)


func _sync_controls() -> void:
	if not is_node_ready():
		return
	get_viewport().set_meta("xr_profile_model", "noi_%s_%s" % ["floor" if floor_view else "campus", "colors" if architecture else "ghost"])
	_sync_selection()
	for id: String in data_buttons:
		var button: DemoButton3D = data_buttons[id]
		button.subtitle_text = "✓ Selezionato" if id == selected_room_id else "Apri misure"
		button.accent_mix = 0.6 if id == selected_room_id else 0.18
		button._sync_view()
	if pending_path.is_empty():
		title.text = ""
	if campus != null:
		campus.visible = not floor_view
	if campus_details != null:
		campus_details.visible = not floor_view and architecture
	if floor_model != null:
		floor_model.visible = floor_view
	nav_buttons.open.configure("open", "Apri " + selected_building, "", muted_color)
	nav_buttons.colors.configure("colors", "Trasparente" if architecture else "Colori", "", muted_color)
	var floors: Array = manifest.buildings[selected_building].floors.keys()
	floors.sort_custom(func(a, b): return int(a) < int(b))
	nav_buttons.open.visible = not floors.is_empty()
	var floor_index := floors.find(str(selected_floor))
	nav_buttons.previous.visible = floor_view and floor_index > 0
	nav_buttons.next.visible = floor_view and floor_index < floors.size() - 1
	for code: String in building_buttons:
		building_buttons[code].get_node("TitleLabel").modulate = Color.WHITE if code == selected_building else building_label_unselected_color
	_sync_interaction()


func _sync_interaction() -> void:
	if interaction.is_inside_tree():
		interaction.set_branch_interactive(self, is_visible_in_tree())
		interaction.set_branch_interactive(controls, controls.is_visible_in_tree())


func _button(parent: Node3D, id: String, heading: String, subtitle: String, location: Vector3, size: Vector3) -> DemoButton3D:
	var button := BUTTON.instantiate() as DemoButton3D
	button.name = "Select_" + id.validate_node_name()
	button.demo_id = id
	button.title_text = heading
	button.subtitle_text = subtitle
	button.position = location
	button.scale = size
	parent.add_child(button)
	button.title_label.max_chars_per_line = 22
	button.subtitle_label.max_chars_per_line = 26
	button._sync_view()
	return button


func _clear_unrelated_selection() -> void:
	for room: Dictionary in rooms:
		if str(room.id) == selected_room_id and room.building == selected_building and int(room.floor) == selected_floor:
			return
	_show_building_description()


func _building_data() -> Dictionary:
	var data: Dictionary = building_descriptions.get(selected_building, {}).duplicate(true)
	data.merge({"id": "%s-floor-%d" % [selected_building, selected_floor], "building": selected_building, "floor": selected_floor})
	return data


func _show_building_description() -> void:
	var data := _building_data()
	selected_room_id = str(data.id)
	room_selected.emit(data)
