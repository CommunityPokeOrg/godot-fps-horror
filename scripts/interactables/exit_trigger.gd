extends Area3D
class_name ExitTrigger
## Placed just beyond the exit door; the player walking in wins the run.

var _used := false


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if _used or not body.is_in_group("player"):
		return
	_used = true
	AudioManager.play_2d("escape")
	if body.has_method("set"):
		body.frozen = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	GameManager.player_escaped()
