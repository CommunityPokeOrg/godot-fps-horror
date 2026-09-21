extends Interactable
class_name BatteryPickup
## Flashlight battery pickup — restores charge.

@export var amount := 45.0
var collected := false
var _t := 0.0


func _ready() -> void:
	prompt_text = "Take battery"
	randomize()
	_t = randf() * 10.0


func _process(delta: float) -> void:
	if collected:
		return
	_t += delta
	$Mesh.position.y = 0.35 + sin(_t * 2.4) * 0.06


func get_prompt() -> String:
	return "" if collected else "[E] Take battery"


func interact(player: Node) -> void:
	if collected:
		return
	collected = true
	AudioManager.play_2d("pickup")
	GameManager.recharge_battery(amount)
	queue_free()
