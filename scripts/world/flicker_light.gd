extends SpotLight3D
class_name FlickerLight
## Ceiling light with random flicker. `flicker_amount` 0 = steady.
## Occasionally buzzes audibly (quiet positional flicker sound).

@export var base_energy := 2.2
@export var flicker_amount := 0.55
@export var audible := true

var _next := 0.0


func _ready() -> void:
	light_energy = base_energy
	_next = randf_range(0.02, 0.2)


func _process(delta: float) -> void:
	if flicker_amount <= 0.001:
		return
	_next -= delta
	if _next > 0.0:
		return
	_next = randf_range(0.05, 0.35)
	if randf() < 0.16:
		# hard drop-out
		light_energy = base_energy * randf_range(0.0, 0.15)
		if audible:
			AudioManager.play_3d("flicker", global_position, -16.0)
	else:
		light_energy = base_energy * randf_range(1.0 - flicker_amount, 1.0)
