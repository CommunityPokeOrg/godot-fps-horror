extends CharacterBody3D
class_name Player
## First-person horror controller.
##
## Features: mouse look (pitch-clamped), WASD movement, sprint with stamina,
## crouch (hold or via StandCheck), head bobbing, footstep noise events for
## AI hearing, a toggleable SpotLight3D flashlight with battery drain,
## passive crank recharge, and low-battery flicker. Sanity drains in darkness
## and while the enemy is close/chasing; it drives heartbeat + vignette
## feedback through the HUD.

signal battery_changed(value: float)
signal stamina_changed(value: float)
signal sanity_changed(value: float)
signal flashlight_toggled(on: bool)

@export_group("Movement")
@export var walk_speed := 3.0
@export var sprint_speed := 5.2
@export var crouch_speed := 1.5
@export var jump_velocity := 4.0
@export var acceleration := 14.0
@export var mouse_sensitivity := 0.0022
@export var gravity := 14.0

@export_group("Body")
@export var stand_height := 1.8
@export var crouch_height := 1.1
@export var eye_height := 1.62
@export var crouch_eye_height := 0.95

@export_group("Stamina")
@export var max_stamina := 100.0
@export var stamina_drain := 16.0   ## per second while sprinting
@export var stamina_regen := 13.0   ## per second while not sprinting

@export_group("Flashlight battery")
@export var max_battery := 100.0
@export var battery_drain_per_sec := 1.4
@export var battery_recharge_per_sec := 2.0  ## slow "crank" recharge while off
@export var low_battery_threshold := 25.0
@export var battery_dead_restart := 15.0     ## must recharge past this after dying

@export_group("Sanity")
@export var max_sanity := 100.0
@export var sanity_dark_drain := 1.2   ## per second while standing in darkness
@export var sanity_fear_drain := 8.0   ## scaled by enemy fear factor (0..1)
@export var sanity_recover := 1.6      ## per second while lit and calm

var stamina := 0.0
var battery := 0.0
var sanity := 0.0
var flashlight_on := false
var is_crouched := false
var exhausted := false

## 0..1, written by the enemy each frame: how scared the player should be.
var fear := 0.0
var frozen := false

var _bob_time := 0.0
var _step_timer := 0.0
var _pitch := 0.0
var _flicker_timer := 0.0
var _dead_battery := false

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var flashlight: SpotLight3D = $Head/Camera3D/Flashlight
@onready var interact_ray: RayCast3D = $Head/Camera3D/InteractRay
@onready var stand_check: RayCast3D = $Head/StandCheck
@onready var col_shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	stamina = max_stamina
	battery = max_battery
	sanity = max_sanity
	add_to_group("player")
	GameManager.register_player(self)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_collision_height(stand_height)
	_set_flashlight(true)   # start lit — full darkness is a choice, not a default


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		look(event.relative)


## Apply a camera-look delta (screen pixels). Used by mouse motion and by
## the touch overlay's drag-look area.
func look(relative: Vector2) -> void:
	if frozen or GameManager.state != GameManager.State.PLAYING:
		return
	head.rotate_y(-relative.x * mouse_sensitivity)
	_pitch = clampf(_pitch - relative.y * mouse_sensitivity, -1.45, 1.45)
	camera.rotation.x = _pitch


func _process(delta: float) -> void:
	if frozen:
		return
	if GameManager.state != GameManager.State.PLAYING:
		return

	# --- toggles ---
	if Input.is_action_just_pressed("flashlight"):
		toggle_flashlight()
	if Input.is_action_just_pressed("interact"):
		_try_interact()
	if Input.is_action_just_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED

	# --- battery ---
	if flashlight_on:
		battery = maxf(0.0, battery - battery_drain_per_sec * delta)
		if battery <= 0.0:
			_dead_battery = true
			_set_flashlight(false)
			GameManager.toast("Flashlight died — let the crank recharge it.")
		elif battery <= low_battery_threshold:
			_flicker(delta)
		battery_changed.emit(battery)
	elif _dead_battery or battery < max_battery:
		battery = minf(max_battery, battery + battery_recharge_per_sec * delta)
		if _dead_battery and battery >= battery_dead_restart:
			_dead_battery = false
		battery_changed.emit(battery)

	# --- sanity ---
	var in_darkness := not flashlight_on
	var drain := 0.0
	if in_darkness:
		drain += sanity_dark_drain
	drain += sanity_fear_drain * clampf(fear, 0.0, 1.0)
	if drain > 0.0:
		sanity = maxf(0.0, sanity - drain * delta)
	else:
		sanity = minf(max_sanity, sanity + sanity_recover * delta)
	sanity_changed.emit(sanity)
	AudioManager.set_heartbeat(sanity < 30.0)

	# low-sanity camera sway
	if sanity < 45.0:
		var wobble := (45.0 - sanity) / 45.0
		camera.rotation.z = sin(Time.get_ticks_msec() * 0.0011) * 0.015 * wobble
		head.rotation.z = sin(Time.get_ticks_msec() * 0.0007) * 0.01 * wobble
	else:
		camera.rotation.z = 0.0
		head.rotation.z = 0.0

	# footstep timer + noise emission
	var h_speed := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and h_speed > 0.5:
		_step_timer -= delta * h_speed
		if _step_timer <= 0.0:
			_step_timer = 2.6
			var loud := 0.3 if is_crouched else (1.4 if _is_sprinting() else 0.7)
			AudioManager.footstep(global_position + Vector3(0, -0.8, 0), loud)
	else:
		_step_timer = minf(_step_timer, 0.8)


func _physics_process(delta: float) -> void:
	if frozen or GameManager.state != GameManager.State.PLAYING:
		velocity = Vector3.ZERO
		return

	# --- crouch ---
	var want_crouch := Input.is_action_pressed("crouch")
	if want_crouch != is_crouched:
		if want_crouch:
			is_crouched = true
			_update_collision_height(crouch_height)
		elif not stand_check.is_colliding():
			is_crouched = false
			_update_collision_height(stand_height)

	# --- sprint/stamina ---
	var sprinting := _is_sprinting()
	if sprinting:
		stamina = maxf(0.0, stamina - stamina_drain * delta)
		if stamina <= 0.0:
			exhausted = true
	elif stamina < max_stamina:
		stamina = minf(max_stamina, stamina + stamina_regen * delta)
		if stamina > 30.0:
			exhausted = false
	stamina_changed.emit(stamina)

	# --- movement ---
	var speed := crouch_speed if is_crouched else (sprint_speed if sprinting else walk_speed)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish_dir := (head.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	wish_dir.y = 0
	wish_dir = wish_dir.normalized()

	velocity.y -= gravity * delta
	if is_on_floor():
		if velocity.y < -1.5:
			velocity.y = -1.5   # keep grounded contact without accumulating fall speed
		if Input.is_action_just_pressed("jump") and not is_crouched:
			velocity.y = jump_velocity
			AudioManager.emit_noise(global_position, 1.0)
		var hvel := Vector3(velocity.x, 0, velocity.z).lerp(wish_dir * speed, minf(1.0, acceleration * delta))
		velocity.x = hvel.x
		velocity.z = hvel.z
	else:
		var hvel := Vector3(velocity.x, 0, velocity.z).lerp(wish_dir * speed, minf(1.0, acceleration * 0.35 * delta))
		velocity.x = hvel.x
		velocity.z = hvel.z

	move_and_slide()

	# --- head bob ---
	var h_speed := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and h_speed > 0.4:
		_bob_time += delta * h_speed * 1.7
		var target_y := (crouch_eye_height if is_crouched else eye_height) + sin(_bob_time * 2.0) * 0.035
		head.position.y = lerpf(head.position.y, target_y, 0.4)
		head.position.x = lerpf(head.position.x, sin(_bob_time) * 0.02, 0.4)
	else:
		head.position.y = lerpf(head.position.y, crouch_eye_height if is_crouched else eye_height, 0.15)
		head.position.x = lerpf(head.position.x, 0.0, 0.15)


func _is_sprinting() -> bool:
	return Input.is_action_pressed("sprint") and not is_crouched and not exhausted \
		and Input.get_vector("move_left", "move_right", "move_forward", "move_back").length() > 0.1


func _update_collision_height(h: float) -> void:
	var capsule := col_shape.shape as CapsuleShape3D
	capsule.height = h
	col_shape.position.y = h * 0.5


func toggle_flashlight() -> void:
	if flashlight_on:
		_set_flashlight(false)
	elif battery > 0.0 and not _dead_battery:
		_set_flashlight(true)
	else:
		AudioManager.play_2d("flicker", -10.0)
		GameManager.toast("Flashlight is dead.")


func _set_flashlight(on: bool) -> void:
	flashlight_on = on
	flashlight.visible = on
	flashlight_toggled.emit(on)
	AudioManager.play_2d("blip", -8.0)
	AudioManager.emit_noise(global_position, 0.4)


func _flicker(delta: float) -> void:
	_flicker_timer -= delta
	if _flicker_timer <= 0.0:
		_flicker_timer = randf_range(0.05, 0.3)
		if randf() < 0.3:
			flashlight.light_energy = randf_range(0.2, 0.8)
			AudioManager.play_2d("flicker", -18.0)
		else:
			flashlight.light_energy = randf_range(1.8, 3.2)


func add_battery(amount: float) -> void:
	battery = minf(max_battery, battery + amount)
	_dead_battery = false
	battery_changed.emit(battery)


## --- interaction ---
func get_interact_target() -> Node:
	if not interact_ray.is_colliding():
		return null
	var node: Object = interact_ray.get_collider()
	while node is Node:
		if node.has_method("interact") and node.has_method("get_prompt"):
			return node
		node = node.get_parent()
	return null


func get_interact_prompt() -> String:
	var t := get_interact_target()
	return t.get_prompt() if t else ""


func _try_interact() -> void:
	var t := get_interact_target()
	if t:
		t.interact(self)


## How visible the player is to the enemy's vision cone (multiplier).
func detection_modifier() -> float:
	var m := 1.0
	if is_crouched:
		m *= 0.6
	if flashlight_on:
		m *= 1.35
	return m


func die() -> void:
	if frozen:
		return
	frozen = true
	sanity = 0.0
	sanity_changed.emit(0.0)
	_set_flashlight(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	GameManager.player_died()
