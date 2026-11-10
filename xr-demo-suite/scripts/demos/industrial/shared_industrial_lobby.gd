extends Node3D
class_name SharedIndustrialLobby
## In-headset lobby for the shared industrial session: create a room, join
## from the LAN list or by code (numeric keypad), and a connected view with
## the permission mode toggle, host reset and leave.

signal closed()
signal view_changed()

const ButtonScene := preload("res://scenes/ui/DemoButton3D.tscn")
const MAX_ROOM_BUTTONS := 4

@export var state_path: NodePath

@onready var status_label: Label3D = $Status
@onready var info_label: Label3D = $Info
@onready var hint_label: Label3D = $Hint
@onready var lobby_view: Node3D = $LobbyView
@onready var keypad_view: Node3D = $KeypadView
@onready var room_view: Node3D = $RoomView
@onready var rename_view: Node3D = $RenameView
@onready var mode_button: DemoButton3D = $RoomView/Mode
@onready var retry_button: DemoButton3D = $RoomView/Retry
@onready var reset_button: DemoButton3D = $RoomView/Reset
@onready var rename_button: DemoButton3D = $RoomView/Rename
@onready var rooms_root: Node3D = $LobbyView/Rooms
@onready var keys_root: Node3D = $KeypadView/Keys
@onready var name_keys_root: Node3D = $RenameView/Keys

var state: Node
var room_buttons: Array[DemoButton3D] = []
var room_addresses: Array[String] = []
var entry := ""
var keypad_open := false
var renaming := false
var name_entry := ""


func _ready() -> void:
	state = get_node_or_null(state_path)
	if state == null:
		# The state is persistent (AppServices in Main.tscn): find it by group.
		state = get_tree().get_first_node_in_group("shared_state")
	if state == null:
		push_error("SharedLobbyPanel: state_path not set")
		return
	state.status_changed.connect(_on_status)
	state.connection_changed.connect(_refresh)
	state.room_list_changed.connect(_refresh)
	if state.session != null:
		state.session.state_updated.connect(_refresh)
	# Static buttons live in the .tscn and carry no connection blocks; wire
	# them before the dynamic build so none is connected twice. The flag
	# order is (pattern, type, recursive, invert): the earlier device bug
	# was passing (false, true), which searched direct children inverted.
	var wired := 0
	for node in find_children("*", "DemoButton3D", true, false):
		node.pressed.connect(_on_pressed)
		wired += 1
	print("XR_LOBBY ready wired=%d state=%s" % [
		wired, "ok" if state != null else "NULL"])
	_build_room_buttons()
	_build_keypad()
	_build_name_keyboard()
	visible = false
	_refresh()


func open() -> void:
	visible = true
	_refresh()


func close() -> void:
	visible = false
	closed.emit()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func _build_room_buttons() -> void:
	for index in range(MAX_ROOM_BUTTONS):
		var button := ButtonScene.instantiate() as DemoButton3D
		# Lobby grid: two columns at ±0.70, rows every 0.38 (#22 bigger buttons).
		button.position = Vector3(-0.70 + (index % 2) * 1.40, 0.12 - (index / 2) * 0.38, 0.04)
		button.scale = Vector3(0.85, 0.85, 0.7)
		button.configure("room_%d" % index, "In ricerca…", "", Color(0.12, 0.7, 0.62))
		button.pressed.connect(_on_pressed)
		rooms_root.add_child(button)
		room_buttons.append(button)


func _build_keypad() -> void:
	var keys := ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "<"]
	for index in range(keys.size()):
		var button := ButtonScene.instantiate() as DemoButton3D
		# Catalog grid: three columns at ±0.88/0, rows every 0.27.
		button.position = Vector3(-0.88 + (index % 3) * 0.88, 0.55 - (index / 3) * 0.27, 0.04)
		button.scale = Vector3(0.55, 0.62, 0.7)
		button.configure("key_" + keys[index], keys[index], "", Color(0.2, 0.55, 0.8))
		keys_root.add_child(button)
		button.pressed.connect(_on_pressed)


## Rename keyboard: alphabetical 5×5 grid (letters are easy to scan) plus
## space and backspace; the control row (Cancella/Salva/Indietro) lives in
## the .tscn. Keys are smaller than the keypad ones, so the title font is
## pushed to the fitter's maximum to keep single letters readable.
func _build_name_keyboard() -> void:
	var keys := ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
		"N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "␣", "<"]
	for index in range(keys.size()):
		var button := ButtonScene.instantiate() as DemoButton3D
		# Five columns at 0.5, rows every 0.24: the grid ends above the
		# control row at -0.90.
		button.position = Vector3(-1.0 + (index % 5) * 0.5, 0.62 - (index / 5) * 0.24, 0.04)
		button.scale = Vector3(0.3, 0.62, 0.7)
		button.configure("name_" + keys[index], keys[index], "", Color(0.2, 0.55, 0.8))
		name_keys_root.add_child(button)
		var title := button.get_node("TitleLabel") as FittedLabel3D
		title.max_font_size = 72
		title.min_font_size = 72
		title.refit()
		button.pressed.connect(_on_pressed)


func _on_pressed(action_id: String) -> void:
	match action_id:
		"host":
			state.host_room()
		"code":
			entry = ""
			keypad_open = true
			_refresh()
		"back":
			keypad_open = false
			_refresh()
		"cancel":
			entry = ""
			_refresh()
		"close":
			close()
		"ok":
			var target := entry.strip_edges()
			if target.contains("."):
				# A direct IP join is validated immediately: keep the keypad
				# open only when the entry is unusable.
				if state.join_room(target) == OK:
					keypad_open = false
			else:
				# Code search is async: keep the keypad open so the code
				# stays visible while the status reports progress or errors.
				state.join_room_by_code(target)
			_refresh()
		"mode":
			state.set_mode(not state.local_mode())
		"retry":
			state.retry_colocation()
		"reset":
			state.reset_world()
		"rename":
			renaming = true
			name_entry = ""
			_refresh()
		"name_back":
			renaming = false
			_refresh()
		"name_clear":
			name_entry = ""
			_refresh()
		"name_ok":
			state.rename_room(name_entry)
			renaming = false
			_refresh()
		"leave":
			state.leave_room()
			keypad_open = false
			renaming = false
			_refresh()
		_:
			if action_id.begins_with("key_"):
				_press_key(action_id.trim_prefix("key_"))
			elif action_id.begins_with("name_"):
				_press_name_key(action_id.trim_prefix("name_"))
			elif action_id.begins_with("room_"):
				var index := int(action_id.trim_prefix("room_"))
				if index < room_buttons.size() and room_buttons[index].visible:
					state.join_room(room_addresses[index])


func _press_name_key(key: String) -> void:
	if key == "<":
		name_entry = name_entry.substr(0, name_entry.length() - 1)
	elif key == "␣":
		if not name_entry.ends_with(" "):
			name_entry += " "
	elif name_entry.length() < 16:
		name_entry += key
	_refresh()


func _press_key(key: String) -> void:
	if key == "<":
		entry = entry.substr(0, entry.length() - 1)
	elif key == "." and entry.contains("."):
		return
	elif key != "." and entry.length() >= 15:
		return
	else:
		entry += key
	_refresh()


func _on_status(message: String) -> void:
	status_label.text = message
	_refresh()


func _refresh() -> void:
	if not is_node_ready() or state == null:
		return
	var connected: bool = state.active()
	lobby_view.visible = not connected and not keypad_open
	keypad_view.visible = not connected and keypad_open
	room_view.visible = connected and not renaming
	rename_view.visible = connected and renaming
	# The collision controller respects Node3D visibility: the newly visible
	# branch only gets its collision layers back after a fresh pass.
	view_changed.emit()
	if not visible:
		return
	if connected and renaming:
		_refresh_rename_view()
	elif connected:
		_refresh_room_view()
	else:
		_refresh_lobby_view()


func _refresh_lobby_view() -> void:
	if keypad_open:
		info_label.text = entry if entry != "" else "­"
		info_label.visible = true
		hint_label.text = "Codice di 4 cifre · IP con i punti · < per cancellare"
		return
	info_label.visible = false
	var rooms: Dictionary = state.rooms()
	var seen: Array = rooms.keys()
	room_addresses.clear()
	for index in range(room_buttons.size()):
		var button := room_buttons[index]
		if index < seen.size():
			var room: Dictionary = rooms[seen[index]]
			button.visible = true
			room_addresses.append(str(seen[index]))
			button.configure("room_%d" % index,
				str(room.name), "codice %s" % room.code,
				Color(0.12, 0.7, 0.62))
		else:
			button.visible = false
	hint_label.text = ("Stanze trovate: %d · toccane una per entrare" % seen.size()) \
		if not seen.is_empty() else "Nessuna stanza in ascolto · chiedi all'host di avviarla"


func _refresh_room_view() -> void:
	info_label.visible = true
	var players: Dictionary = state.players()
	info_label.text = "STANZA %s · %d/%d" % [state.room_name(), players.size(), 10]
	mode_button.title_text = "Condivisa" if state.local_mode() else "Privata"
	mode_button.subtitle_text = "I miei arredi sono muovibili da tutti" if state.local_mode() \
		else "Solo io muovo i miei arredi"
	mode_button._sync_view()
	# The retry button only appears when the shared reference is broken:
	# "Premi Riprova" in the status message must have a real destination.
	retry_button.visible = state.colocation_failed()
	retry_button._sync_view()
	reset_button.visible = state.hosting()
	rename_button.visible = state.hosting()
	hint_label.text = "Sei in stanza · il pannello è il menu · Torna alla demo ti lascia connesso"


## Rename view: the entry typed so far is echoed in the info label, the
## keyboard itself is built once in _build_name_keyboard().
func _refresh_rename_view() -> void:
	info_label.visible = true
	info_label.text = name_entry if name_entry != "" else "­"
	hint_label.text = "Tocca le lettere · Salva quando hai finito"
