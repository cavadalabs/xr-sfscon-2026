extends RefCounted
## Wire guards (issue #29): pure checks over untrusted network data, no
## session state. The session delegates here so the rules live in one place
## and can be exercised without building a multiplayer peer.


## Anchor ids as minted by xr_net_colocation: lowercase UUIDv4 text, with
## dashes fixed at 8/13/18/23 and the nil UUID rejected.
static func valid_uuid(value: String) -> bool:
	if value.length() != 36:
		return false
	for index in value.length():
		if index in [8, 13, 18, 23]:
			if value[index] != "-":
				return false
		elif value[index] not in "0123456789abcdef":
			return false
	return value != "00000000-0000-0000-0000-000000000000"


## A pose must be finite and stay inside the room: rejects NaN drift and
## runaway coordinates before they reach the shared player table.
static func valid_transform(value: Transform3D) -> bool:
	if not value.is_finite():
		return false
	var p := value.origin
	var b := value.basis
	return absf(p.x) <= 12.0 and absf(p.z) <= 12.0 and p.y >= -0.5 and p.y <= 5.0 \
		and absf(b.x.length_squared() - 1.0) < 0.02 \
		and absf(b.y.length_squared() - 1.0) < 0.02 \
		and absf(b.z.length_squared() - 1.0) < 0.02 \
		and absf(b.determinant() - 1.0) < 0.02
