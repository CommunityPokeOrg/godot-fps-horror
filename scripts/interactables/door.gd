extends AnimatableBody3D
class_name DoorInteractable
## A sliding metal door. The whole AnimatableBody3D is the moving panel,
## so its collision travels with it. `slide_dir` (grid axes) is set by the
## level generator depending on the doorway orientation.

@export var locked := false
@export var lock_message := "Locked. It needs a key."
@export var is_exit_door := false   ## purely informational on the prompt

var is_open := false
var slide_dir := Vector3(1.45, 0, 0)
var _animating := false
var _closed_pos := Vector3.ZERO


func _ready() -> void:
	_closed_pos = position


func get_prompt() -> String:
	if _animating:
		return ""
	if locked and not GameManager.has_exit_key:
		return "[E] Locked door"
	return "[E] " + ("Close" if is_open else "Open") + " door"


func interact(_player: Node) -> void:
	if _animating:
		return
	if locked and not GameManager.has_exit_key:
		AudioManager.play_3d("door_locked", global_position, -4.0)
		GameManager.toast(lock_message)
		return
	if locked:
		locked = false
		GameManager.toast("The key turns — the way out is open.")
	_toggle()


## Lets the enemy open (never unlock) doors it runs into.
func force_open() -> void:
	if not is_open and not _animating and not locked:
		_toggle()


func _toggle() -> void:
	_animating = true
	is_open = not is_open
	AudioManager.play_3d("door_creak", global_position, -6.0)
	AudioManager.emit_noise(global_position, 0.9)
	var target := _closed_pos + slide_dir if is_open else _closed_pos
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "position", target, 0.9)
	tween.tween_callback(func() -> void: _animating = false)
