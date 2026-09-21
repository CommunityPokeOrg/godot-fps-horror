extends Node
## Global game state: objectives, run lifecycle, and references shared
## between the player, HUD, interactables and the enemy.
##
## Autoloaded as `GameManager`.

signal state_changed(new_state: State)
signal objective_updated
signal toast_requested(text: String)

enum State { PLAYING, READING_NOTE, DEAD, ESCAPED }

## The run's objective: collect all lore notes, find the exit key, reach the exit.
var notes_total := 4
var notes_found := 0
var has_exit_key := false

var state: State = State.PLAYING
var player: CharacterBody3D = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func register_player(p: CharacterBody3D) -> void:
	player = p


func collect_note() -> void:
	notes_found = mini(notes_found + 1, notes_total)
	objective_updated.emit()
	if notes_found >= notes_total and not has_exit_key:
		toast("All journals recovered. Now find the exit key.")
	elif notes_found >= notes_total and has_exit_key:
		toast("You have everything. Get to the exit.")


func collect_exit_key() -> void:
	has_exit_key = true
	objective_updated.emit()
	toast("Exit key acquired — reach the exit door on the east side.")


func recharge_battery(amount: float) -> void:
	if player and player.has_method("add_battery"):
		player.add_battery(amount)
		toast("Flashlight battery +%d%%" % int(amount))


func set_reading(reading: bool) -> void:
	if state == State.PLAYING and reading:
		state = State.READING_NOTE
	elif state == State.READING_NOTE and not reading:
		state = State.PLAYING
	state_changed.emit(state)


func player_died() -> void:
	if state == State.DEAD or state == State.ESCAPED:
		return
	state = State.DEAD
	state_changed.emit(state)


func player_escaped() -> void:
	if state == State.DEAD or state == State.ESCAPED:
		return
	state = State.ESCAPED
	state_changed.emit(state)


func toast(text: String) -> void:
	toast_requested.emit(text)


func objective_text() -> String:
	if state == State.ESCAPED:
		return "You escaped Facility 13."
	var parts: Array[String] = []
	parts.append("Journals: %d/%d" % [notes_found, notes_total])
	parts.append("Exit key: %s" % ("found" if has_exit_key else "missing"))
	return "  |  ".join(parts)


## Restart the whole scene. Called from HUD death/win screens.
func reset_run() -> void:
	notes_found = 0
	has_exit_key = false
	state = State.PLAYING
	state_changed.emit(state)
	get_tree().paused = false
	get_tree().reload_current_scene()
