extends RefCounted
## Host-side ACK ledger (issue #29): who acknowledged which revision and who
## owes a re-send. The three tables are owned by the session (the reconnect
## check pokes them to simulate lost acks); this module owns the backoff:
## every attempt arms a growing per-peer window, so a peer stuck in standby
## is retried at 1 Hz, 2 Hz, 3 Hz… instead of every tick (the hot loop seen
## in the 13:20 field log). After MAX_EVENT_RETRIES the peer gets a full
## snapshot instead, which heals any gap in one shot.


const ACK_TIMEOUT := 1.0
const MAX_EVENT_RETRIES := 2

var _acked: Dictionary
var _sent: Dictionary
var _next: Dictionary


func _init(acked: Dictionary, sent: Dictionary, next: Dictionary) -> void:
	_acked = acked
	_sent = sent
	_next = next


## The host applied the event itself: it acknowledges immediately.
func host_applied(rev: int) -> void:
	_acked[1] = rev
	_sent[1] = 0


## A peer received the join snapshot: only later events can be missing.
func track_peer(peer_id: int, rev: int) -> void:
	_acked[peer_id] = rev
	_sent[peer_id] = 0


func forget_peer(peer_id: int) -> void:
	_acked.erase(peer_id)
	_sent.erase(peer_id)
	_next.erase(peer_id)


## Register an ack; true when the ledger advanced (acks never rewind).
func ack(peer_id: int, rev: int) -> bool:
	if rev <= int(_acked.get(peer_id, 0)):
		return false
	_acked[peer_id] = rev
	_sent[peer_id] = 0
	_next.erase(peer_id)
	return true


func reset() -> void:
	_acked.clear()
	_sent.clear()
	_next.clear()


## Peers still missing `event_rev`, as [peer_id, escalate, attempt] rows.
## Calling this arms the next retry window; `event_time` is when the event
## was first broadcast.
func pending(peers: Array, event_rev: int, now: float, event_time: float) -> Array:
	var due: Array = []
	if event_rev == 0:
		return due
	for peer_id in peers:
		if peer_id == 1 or int(_acked.get(peer_id, 0)) >= event_rev:
			continue
		if now - event_time < ACK_TIMEOUT:
			continue
		if now < float(_next.get(peer_id, 0.0)):
			continue
		var retries := int(_sent.get(peer_id, 0))
		due.append([peer_id, retries >= MAX_EVENT_RETRIES, retries + 1])
		_sent[peer_id] = retries + 1
		_next[peer_id] = now + ACK_TIMEOUT * (retries + 1)
	return due
