extends Interactable
class_name KeyInteractable
## The exit key — floats and spins until picked up.

var collected := false
var _t := 0.0


func _ready() -> void:
	prompt_text = "Take exit key"


func _process(delta: float) -> void:
	if collected:
		return
	_t += delta
	$Mesh.position.y = 0.5 + sin(_t * 2.0) * 0.08
	$Mesh.rotation.y = _t * 1.5


func get_prompt() -> String:
	return "" if collected else "[E] Take exit key"


func interact(_player: Node) -> void:
	if collected:
		return
	collected = true
	AudioManager.play_2d("pickup")
	GameManager.collect_exit_key()
	queue_free()
