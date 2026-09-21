extends Interactable
class_name NoteInteractable
## A collectible journal page. Opens a reading overlay via the HUD and
## counts toward the notes objective.

@export var title := "Journal Page"
@export_multiline var body := "..."
var collected := false


func _ready() -> void:
	prompt_text = "Read note"


func get_prompt() -> String:
	return "" if collected else "[E] Read note"


func interact(_player: Node) -> void:
	if collected:
		return
	collected = true
	interact_enabled = false
	AudioManager.play_2d("note", -4.0)
	GameManager.collect_note()
	var hud := get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("show_note"):
		hud.show_note(title, body)
	visible = false
