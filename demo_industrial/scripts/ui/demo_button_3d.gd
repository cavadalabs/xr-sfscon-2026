extends Node3D
class_name DemoButton3D

signal pressed(demo_id: String)

const FittedLabel := preload("res://scripts/ui/fitted_label_3d.gd")

@export var demo_id := ""
@export var title_text := "Demo"
@export_multiline var subtitle_text := ""
@export var accent_color := Color(0.16, 0.45, 0.85, 1.0)
@export_group("Visual Style")
@export var title_color := Color(0.96, 0.99, 1.0, 1.0)
@export var subtitle_color := Color(0.84, 0.9, 0.96, 1.0)
@export var base_color := Color(0.08, 0.16, 0.19, 1.0)
@export_range(0.0, 1.0, 0.01) var accent_mix := 0.2
@export_range(0.0, 1.0, 0.01) var surface_alpha := 0.98
@export_range(0.0, 0.8, 0.01) var hover_lighten := 0.12
@export_range(0.0, 1.0, 0.01) var idle_emission := 0.025
@export_range(0.0, 1.0, 0.01) var hover_emission := 0.075

@onready var body: MeshInstance3D = $Body
@onready var title_label: Label3D = $TitleLabel
@onready var subtitle_label: Label3D = $SubtitleLabel
@onready var focus_indicator: Sprite3D = get_node_or_null("FocusIndicator") as Sprite3D

var material: StandardMaterial3D
var is_hovered := false
var focus_tween: Tween


func _ready() -> void:
	material = RuntimeMaterials.duplicate_for_mesh(body)
	_sync_view()


func activate() -> void:
	pressed.emit(demo_id)


func configure(new_demo_id: String, new_title: String, new_subtitle: String, new_accent_color: Color) -> void:
	demo_id = new_demo_id
	title_text = new_title
	subtitle_text = new_subtitle
	accent_color = new_accent_color
	if is_node_ready():
		_sync_view()


func pointer_event(event: Variant) -> void:
	if not event is XRToolsPointerEvent:
		return

	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			set_hovered(true)
		XRToolsPointerEvent.Type.EXITED:
			set_hovered(false)
		XRToolsPointerEvent.Type.PRESSED:
			activate()


func _sync_view() -> void:
	# Buttons use nonuniform scale for their hit area; keep glyphs proportional.
	var text_scale := minf(absf(scale.x), absf(scale.y))
	for label in [title_label, subtitle_label]:
		label.scale = Vector3(text_scale / maxf(absf(scale.x), 0.001), text_scale / maxf(absf(scale.y), 0.001), 1)
	FittedLabel.apply_text(title_label, title_text)
	FittedLabel.apply_text(subtitle_label, subtitle_text)
	title_label.modulate = title_color
	subtitle_label.modulate = subtitle_color
	_apply_button_color()


func set_hovered(hovered: bool) -> void:
	if is_hovered == hovered:
		return
	is_hovered = hovered
	_apply_button_color()
	var illustration := get_node_or_null("Illustration") as Node3D
	if illustration != null:
		if focus_tween != null:
			focus_tween.kill()
		focus_tween = create_tween()
		focus_tween.tween_property(illustration, "position:z", 0.04 if hovered else 0.028, 0.12)


func _apply_button_color() -> void:
	var accent: Color = accent_color
	var base: Color = Color(
		lerpf(base_color.r, accent.r, accent_mix),
		lerpf(base_color.g, accent.g, accent_mix),
		lerpf(base_color.b, accent.b, accent_mix),
		surface_alpha
	)
	if is_hovered:
		base = base.lightened(hover_lighten)
	material.albedo_color = base
	material.emission = accent
	material.emission_energy_multiplier = hover_emission if is_hovered else idle_emission
	if focus_indicator != null:
		focus_indicator.visible = is_hovered
		focus_indicator.modulate = accent_color.lightened(0.25)
