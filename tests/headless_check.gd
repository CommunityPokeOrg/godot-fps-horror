extends Node
## Headless end-to-end verification for the project.
##
## Run:
##   godot --headless --path . "res://tests/headless_check.tscn"
##
## Exercises the input map, autoloads, generated level connectivity,
## player mechanics (movement, sprint, crouch, flashlight battery),
## interaction (doors, notes, key, exit), and the enemy AI state
## machine including a kill. Exit code 0 = all passed.

var failures: Array[String] = []
var passed: Array[String] = []
var main: Node = null
var facility: FacilityGenerator = null
var player: Player = null
var enemy: Enemy = null


func _ready() -> void:
	# the scene tree is still setting up during _ready; defer one frame
	call_deferred("_start")


func _start() -> void:
	await _run_all()
	print("----------------------------------------")
	for p in passed:
		print("PASS  ", p)
	for f in failures:
		printerr("FAIL  ", f)
	print("----------------------------------------")
	if failures.is_empty():
		print("ALL %d CHECKS PASSED" % passed.size())
		get_tree().quit(0)
	else:
		printerr("%d CHECK(S) FAILED" % failures.size())
		get_tree().quit(1)


func check(cond: bool, name: String) -> bool:
	if cond:
		passed.append(name)
	else:
		failures.append(name)
	return cond


func frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _run_all() -> void:
	# --- project config / autoloads ---
	var actions := ["move_forward", "move_back", "move_left", "move_right",
		"sprint", "crouch", "interact", "flashlight", "jump", "ui_cancel"]
	var missing: Array[String] = []
	for a in actions:
		if not InputMap.has_action(a):
			missing.append(a)
	check(missing.is_empty(), "input map actions present %s" % ("missing: " + str(missing) if not missing.is_empty() else ""))
	check(has_node("/root/GameManager"), "GameManager autoload")
	check(has_node("/root/AudioManager"), "AudioManager autoload")

	# --- main scene instantiation ---
	var packed: PackedScene = load("res://scenes/main.tscn")
	if check(packed != null, "main.tscn loads"):
		main = packed.instantiate()
		get_tree().root.add_child(main)
		get_tree().current_scene = main
		await frames(3)

	facility = main.get_node_or_null("Facility")
	player = main.get_node_or_null("Player")
	enemy = main.get_node_or_null("Enemy")
	check(facility != null, "facility node present")
	check(player != null, "player node present")
	check(enemy != null, "enemy node present")
	if facility == null or player == null or enemy == null:
		return

	# wait for navmesh bake (or timeout -> fallback steering)
	var waited := 0
	while not enemy._nav_checked and waited < 400:
		await get_tree().physics_frame
		waited += 1
	check(enemy._nav_checked, "navigation ready or fallback engaged")

	# --- level integrity ---
	check(facility.grid.size() > 80, "level carved (%d cells)" % facility.grid.size())
	var bad := facility.unreachable_content()
	check(bad.is_empty(), "all content reachable %s" % ("" if bad.is_empty() else "unreachable: %s" % str(bad)))
	var doors := get_tree().get_nodes_in_group("interactable").filter(func(n): return n is DoorInteractable)
	check(doors.size() >= 6, "doors placed (%d)" % doors.size())
	var notes := get_tree().get_nodes_in_group("interactable").filter(func(n): return n is NoteInteractable)
	check(notes.size() == 4, "4 notes placed (%d)" % notes.size())

	# --- player mechanics ---
	# park the enemy so it can't interfere with the deterministic checks below
	enemy.state = Enemy.State.DISABLED
	enemy.global_position = facility.cell_to_world(Vector2i(2, 17))
	enemy.velocity = Vector3.ZERO

	await frames(30)   # let the player settle onto the floor
	check(player.is_on_floor(), "player grounded at spawn")
	var start := player.global_position
	Input.action_press("move_forward")
	await frames(30)
	check(start.distance_to(player.global_position) > 0.8, "player moves forward")

	Input.action_press("sprint")
	await frames(30)
	check(player.stamina < player.max_stamina, "sprint drains stamina (%.1f)" % player.stamina)
	Input.action_release("sprint")
	Input.action_release("move_forward")

	Input.action_press("crouch")
	await frames(3)
	check(player.is_crouched, "crouch engages")
	Input.action_release("crouch")
	await frames(5)
	check(not player.is_crouched or player.stand_check.is_colliding(), "uncrouch works (or ceiling blocks)")

	player._set_flashlight(false)   # ensure darkness for the drain check
	var s0: float = player.sanity
	await frames(60)
	check(player.sanity < s0, "sanity drains in darkness (%.1f -> %.1f)" % [s0, player.sanity])

	player.toggle_flashlight()
	await frames(2)
	check(player.flashlight_on and player.flashlight.visible, "flashlight toggles on")
	var b0: float = player.battery
	await frames(60)
	check(player.battery < b0, "battery drains while on (%.1f -> %.1f)" % [b0, player.battery])
	var sanity_drain_ok := player.sanity > 0.0

	# --- interaction ---
	var door: DoorInteractable = null
	for d in doors:
		if not d.locked and not d.is_exit_door:
			door = d
			break
	check(door != null, "found a normal door")
	if door:
		door.interact(player)
		await frames(70)
		check(door.is_open, "door opens on interact")
		door.interact(player)
		await frames(70)
		check(not door.is_open, "door closes on interact")

	var exit_door: DoorInteractable = null
	for d in doors:
		if d.is_exit_door:
			exit_door = d
	if check(exit_door != null, "exit door exists") and exit_door:
		exit_door.interact(player)
		await frames(10)
		check(not exit_door.is_open, "exit door stays locked without key")

	var note: NoteInteractable = notes[0] if notes.size() > 0 else null
	if note:
		note.interact(player)
		await frames(2)
		check(GameManager.notes_found == 1, "note collected (%d)" % GameManager.notes_found)
		check(GameManager.state == GameManager.State.READING_NOTE, "note opens reading overlay")
		GameManager.set_reading(false)

	var key: Node = null
	for n in get_tree().get_nodes_in_group("interactable"):
		if n is KeyInteractable:
			key = n
	if check(key != null, "exit key pickup exists") and key:
		key.interact(player)
		check(GameManager.has_exit_key, "key pickup sets has_exit_key")

	var bat: Node = null
	for n in get_tree().get_nodes_in_group("interactable"):
		if n is BatteryPickup:
			bat = n
	if check(bat != null, "battery pickup exists") and bat:
		var before: float = player.battery
		bat.interact(player)
		check(player.battery > before, "battery pickup recharges flashlight (%.1f)" % player.battery)

	if exit_door:
		exit_door.interact(player)
		await frames(70)
		check(exit_door.is_open, "exit door opens with key")

	# escape: walk the player into the alcove trigger
	player.global_position = facility.cell_to_world(Vector2i(30, 16)) + Vector3(0, 0.5, 0)
	await frames(5)
	check(GameManager.state == GameManager.State.ESCAPED, "exit trigger wins the run")

	# revive for the AI test
	GameManager.state = GameManager.State.PLAYING
	player.frozen = false
	player.flashlight_on = true
	player._set_flashlight(true)

	# --- enemy AI ---
	# deterministic setup: enemy in the main hall patrolling east, player ahead
	enemy.state = Enemy.State.PATROL
	enemy.global_position = facility.cell_to_world(Vector2i(9, 9)) + Vector3(0, 0.05, 0)
	enemy.velocity = Vector3.ZERO
	enemy.waypoints = PackedVector3Array([facility.cell_to_world(Vector2i(20, 9))])
	enemy._wp_index = 0
	player.global_position = facility.cell_to_world(Vector2i(12, 9)) + Vector3(0, 0.05, 0)
	player.velocity = Vector3.ZERO
	await frames(45)
	check(enemy.state == Enemy.State.CHASE, "enemy spots player -> CHASE (state=%d)" % enemy.state)
	# hold still until caught
	await frames(240)
	check(GameManager.state == GameManager.State.DEAD, "catch triggers death (state=%d)" % GameManager.state)
