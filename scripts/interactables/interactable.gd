extends Node3D
class_name Interactable
## Base class for everything the player's InteractRay can use.
## The ray walks up collider parents until it finds a node with
## `interact(player)` + `get_prompt()`.

@export var prompt_text := "Interact"
@export var interact_enabled := true


func get_prompt() -> String:
	return "[E] " + prompt_text if interact_enabled else ""


func interact(_player: Node) -> void:
	pass
