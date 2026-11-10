class_name XrDiag
extends RefCounted
## Structured field diagnostics (issue #18). One line per event, one shared
## prefix so `logcat | grep XR_DIAG` works on a Quest. The category names the
## stage where a world command stalled: `net-out` never left the client,
## `net-reject` the host refused it, `net-in` it arrived, `net-ack` the host
## confirmed delivery, `net-retry` the host re-sent it, and `colo`/`gate`/
## `layout`/`setup` track the room frame and demo wiring.

static func log(category: String, message: String) -> void:
	print("[XR_DIAG] %s %s" % [category, message])
