class_name PassthroughCameraCapture
extends Node

const QUEST_CAMERA_FORMAT := 3

var camera_feed: CameraFeed
var y_texture: CameraTexture
var uv_texture: CameraTexture
var rgba_texture: CameraTexture


func initialize() -> bool:
	CameraServer.monitoring_feeds = true

	var feeds: Array = CameraServer.feeds()
	if feeds.is_empty():
		push_warning("No camera feed available. CameraServerExtension or headset permission may be missing.")
		return false

	camera_feed = feeds[1] if feeds.size() > 1 else feeds[0]
	camera_feed.set_format(QUEST_CAMERA_FORMAT, {})
	camera_feed.feed_is_active = true
	_setup_textures()
	return true


func has_valid_feed() -> bool:
	return camera_feed != null


func capture_frame(max_side: int = 0) -> Image:
	if not has_valid_feed():
		return null

	var yuv_image: Image = _compose_image_from_yuv(max_side)
	if yuv_image != null:
		return yuv_image

	if rgba_texture != null:
		var rgba_image: Image = rgba_texture.get_image()
		if rgba_image != null and rgba_image.get_width() > 0 and rgba_image.get_height() > 0:
			_resize_to_max_side(rgba_image, max_side)
			return rgba_image

	return null


func _setup_textures() -> void:
	if camera_feed == null:
		return

	y_texture = CameraTexture.new()
	y_texture.camera_feed_id = camera_feed.get_id()
	y_texture.which_feed = CameraServer.FEED_Y_IMAGE
	y_texture.camera_is_active = true

	uv_texture = CameraTexture.new()
	uv_texture.camera_feed_id = camera_feed.get_id()
	uv_texture.which_feed = CameraServer.FEED_CBCR_IMAGE
	uv_texture.camera_is_active = true

	rgba_texture = CameraTexture.new()
	rgba_texture.camera_feed_id = camera_feed.get_id()
	rgba_texture.which_feed = CameraServer.FEED_RGBA_IMAGE
	rgba_texture.camera_is_active = true


func _compose_image_from_yuv(max_side: int = 0) -> Image:
	if y_texture == null or uv_texture == null:
		return null

	var y_image: Image = y_texture.get_image()
	var uv_image: Image = uv_texture.get_image()
	if y_image == null or uv_image == null:
		return null

	var width: int = y_image.get_width()
	var height: int = y_image.get_height()
	var uv_width: int = uv_image.get_width()
	var uv_height: int = uv_image.get_height()
	if width <= 0 or height <= 0 or uv_width <= 0 or uv_height <= 0:
		return null

	var y_data: PackedByteArray = y_image.get_data()
	var uv_data: PackedByteArray = uv_image.get_data()
	if y_data.is_empty() or uv_data.is_empty():
		return null
	
	var y_stride: int = _get_image_stride(y_image)
	var uv_stride: int = _get_image_stride(uv_image)
	if y_stride <= 0 or uv_stride <= 0:
		return null

	var output_width: int = width
	var output_height: int = height
	if max_side > 0:
		var largest_side: int = width if width > height else height
		if largest_side > max_side:
			var scale_factor: float = float(max_side) / float(largest_side)
			output_width = max(1, int(round(float(width) * scale_factor)))
			output_height = max(1, int(round(float(height) * scale_factor)))

	var output: PackedByteArray = PackedByteArray()
	output.resize(output_width * output_height * 4)

	var output_index := 0
	for output_y in range(output_height):
		var source_y: int = int(float(output_y) * float(height) / float(output_height))
		var uv_y: int = int(float(source_y) * float(uv_height) / float(height))

		for output_x in range(output_width):
			var source_x: int = int(float(output_x) * float(width) / float(output_width))
			var uv_x: int = int(float(source_x) * float(uv_width) / float(width))
			var y_value: float = _sample_image_channel(y_data, width, height, y_stride, source_x, source_y, 0)
			var u_value: float = 0.5
			var v_value: float = 0.5
			if uv_stride >= 2:
				u_value = _sample_image_channel(uv_data, uv_width, uv_height, uv_stride, uv_x, uv_y, 0)
				v_value = _sample_image_channel(uv_data, uv_width, uv_height, uv_stride, uv_x, uv_y, 1)
			var y_linear: float = (y_value - 16.0 / 255.0) * 1.16438356
			var u: float = u_value - 0.5
			var v: float = v_value - 0.5
			var r: float = clamp(y_linear + 1.79274107 * v, 0.0, 1.0)
			var g: float = clamp(y_linear - 0.21324861 * u - 0.53290933 * v, 0.0, 1.0)
			var b: float = clamp(y_linear + 2.11240179 * u, 0.0, 1.0)

			output[output_index] = int(r * 255.0)
			output[output_index + 1] = int(g * 255.0)
			output[output_index + 2] = int(b * 255.0)
			output[output_index + 3] = 255
			output_index += 4

	return Image.create_from_data(output_width, output_height, false, Image.FORMAT_RGBA8, output)


func _resize_to_max_side(image: Image, max_side: int) -> void:
	if max_side <= 0:
		return

	var width: int = image.get_width()
	var height: int = image.get_height()
	var largest_side: int = width if width > height else height
	if largest_side <= max_side:
		return

	var scale_factor: float = float(max_side) / float(largest_side)
	image.resize(
		max(1, int(round(float(width) * scale_factor))),
		max(1, int(round(float(height) * scale_factor))),
		Image.INTERPOLATE_BILINEAR
	)


func _get_image_stride(image: Image) -> int:
	var width: int = image.get_width()
	var height: int = image.get_height()
	if width <= 0 or height <= 0:
		return 0

	var format: int = image.get_format()
	if format == Image.FORMAT_L8 or format == Image.FORMAT_R8:
		return 1
	if format == Image.FORMAT_LA8 or format == Image.FORMAT_RG8:
		return 2
	if format == Image.FORMAT_RGB8:
		return 3
	if format == Image.FORMAT_RGBA8:
		return 4

	var data_size: int = image.get_data().size()
	return max(1, int(data_size / max(1, width * height)))


func _sample_image_channel(
	data: PackedByteArray,
	width: int,
	height: int,
	stride: int,
	x: int,
	y: int,
	channel: int
) -> float:
	var clamped_x: int = clampi(x, 0, width - 1)
	var clamped_y: int = clampi(y, 0, height - 1)
	var clamped_channel: int = clampi(channel, 0, stride - 1)
	var index: int = (clamped_y * width + clamped_x) * stride + clamped_channel
	if index < 0 or index >= data.size():
		return 0.0
	return float(data[index]) / 255.0
