class_name XRImagePayload
extends RefCounted


static func prepare_jpeg_payload(frame: Image, max_side: int, jpeg_quality: float, context: Dictionary = {}) -> Dictionary:
	if frame == null:
		return {}

	var prepared_image: Image = frame.duplicate()
	if prepared_image.is_compressed() and prepared_image.decompress() != OK:
		return {}

	if prepared_image.get_format() != Image.FORMAT_RGB8:
		prepared_image.convert(Image.FORMAT_RGB8)

	var width := prepared_image.get_width()
	var height := prepared_image.get_height()
	if width <= 0 or height <= 0:
		return {}

	_resize_to_max_side(prepared_image, max_side)

	var image_bytes := prepared_image.save_jpg_to_buffer(jpeg_quality)
	if image_bytes.is_empty():
		return {}

	return {
		"base64": Marshalls.raw_to_base64(image_bytes),
		"width": prepared_image.get_width(),
		"height": prepared_image.get_height(),
		"context": context.duplicate(true),
	}


static func _resize_to_max_side(image: Image, max_side: int) -> void:
	if max_side <= 0:
		return

	var width := image.get_width()
	var height := image.get_height()
	var largest_side := maxi(width, height)
	if largest_side <= max_side:
		return

	var image_scale := float(max_side) / float(largest_side)
	image.resize(
		maxi(1, int(round(float(width) * image_scale))),
		maxi(1, int(round(float(height) * image_scale))),
		Image.INTERPOLATE_BILINEAR
	)
