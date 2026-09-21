extends CharacterBody3D
class_name Enemy
## "The Orderly" — a wandering mannequin-thing.
##
## States:
##   PATROL     — walks waypoint circuit (NavigationAgent3D, fallback steering)
##   SUSPICIOUS — heard something: walks to the noise, looks, resumes patrol
##   CHASE      — sees the player: full speed pursuit, repaths constantly
##   SEARCH     — lost sight: sweeps the last known area
##
## Detection: view distance + cone (half-angle) + physics line-of-sight ray.
## Player crouching shrinks detection range; the flashlight beam enlarges it.
## Hearing: AudioManager.noise_emitted events within hear_radius * loudness.
## Catch: within catch_distance -> jumpscare + player death.

signal state_changed(new_state: State)

enum State { PATROL, SUSPICIOUS, CHASE, SEARCH, DISABLED }

@export var patrol_speed := 1.35
@export var chase_speed := 3.55
@export var view_distance := 13.0
@export var view_half_angle := 55.0      ## degrees, half-cone
@export var hear_radius := 10.0
@export var catch_distance := 1.25
@export var lose_sight_time := 3.0
@export var search_duration := 4.5
@export var gravity := 14.0

var state: State = State.PATROL
var waypoints: PackedVector3Array = PackedVector3Array()
var player: Node3D = null

var _wp_index := 0
var _target := Vector3.ZERO
var _has_target := false
var _last_seen := Vector3.ZERO
var _lose_timer := 0.0
var _search_timer := 0.0
var _pause_timer := 0.0
var _repath_timer := 0.0
var _stuck_timer := 0.0
var _last_pos := Vector3.ZERO
var _nav_ok := false
var _nav_checked := false
var _step_timer := 0.0
var _growl_cooldown := 0.0

@onready var nav: NavigationAgent3D = $NavigationAgent3D
@onready var eyes: Node3D = $Eyes


func _ready() -> void:
	add_to_group("enemy")
	AudioManager.noise_emitted.connect(_on_noise)
	_last_pos = global_position
	_growl_cooldown = randf_range(6.0, 14.0)


func configure(p_waypoints: PackedVector3Array, p_player: Node3D) -> void:
	waypoints = p_waypoints
	player = p_player


## Called by main.gd once the level's navmesh has baked (or bake failed).
func set_navigation_ready(ok: bool) -> void:
	_nav_ok = ok
	_nav_checked = true


func _physics_process(delta: float) -> void:
	if state == State.DISABLED or not _nav_checked:
		return
	if player == null:
		player = GameManager.player
		if player == null:
			return

	if not is_on_floor():
		velocity.y -= gravity * delta

	_update_detection(delta)
	_growl_cooldown -= delta

	match state:
		State.PATROL:
			_patrol(delta)
		State.SUSPICIOUS:
			_suspicious(delta)
		State.CHASE:
			_chase(delta)
		State.SEARCH:
			_search(delta)

	# enemy footsteps + dread aura for the player's sanity
	var spd := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and spd > 0.3:
		_step_timer -= delta * spd
		if _step_timer <= 0.0:
			_step_timer = 3.4
			AudioManager.play_3d("enemy_step", global_position, -4.0)

	var dist := global_position.distance_to(player.global_position)
	# fear factor drives player sanity drain + HUD dread
	var f := 0.0
	if state == State.CHASE:
		f = clampf(1.2 - dist / 18.0, 0.3, 1.0)
	elif dist < 8.0:
		f = clampf(1.0 - dist / 8.0, 0.0, 0.5)
	player.fear = f

	move_and_slide()
	_check_doors()
	_check_stuck(delta)


# ---------- perception ----------

func _update_detection(_delta: float) -> void:
	if player.frozen:
		return
	if _can_see_player():
		var dist := global_position.distance_to(player.global_position)
		# instant aggro at knife range, otherwise build-up via repeated sight
		if state != State.CHASE:
			_enter_chase()
		_last_seen = player.global_position
		_lose_timer = 0.0
	elif state == State.CHASE:
		_lose_timer += _delta
		if _lose_timer >= lose_sight_time:
			_enter_search(_last_seen)


func _can_see_player() -> bool:
	var to_player: Vector3 = player.global_position + Vector3(0, 1.2, 0) - eyes.global_position
	var dist := to_player.length()
	var mod: float = player.detection_modifier() if player.has_method("detection_modifier") else 1.0
	if dist > view_distance * mod:
		return false
	var fwd := -global_transform.basis.z
	if fwd.dot(to_player.normalized()) < cos(deg_to_rad(view_half_angle)):
		return false
	# line of sight
	var query := PhysicsRayQueryParameters3D.create(
		eyes.global_position, player.global_position + Vector3(0, 1.2, 0))
	query.collision_mask = 1  # world layer only
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or hit.get("collider") == player


func _on_noise(pos: Vector3, loudness: float) -> void:
	if state == State.CHASE or state == State.DISABLED or player == null or player.frozen:
		return
	var d := global_position.distance_to(pos)
	if d <= hear_radius * loudness:
		if d <= 3.0:
			_enter_chase()
		elif state != State.SUSPICIOUS or pos.distance_to(_target) > 2.0:
			state = State.SUSPICIOUS
			_target = pos
			_has_target = true
			_pause_timer = 0.0
			state_changed.emit(state)


# ---------- states ----------

func _patrol(delta: float) -> void:
	if waypoints.is_empty():
		velocity.x = move_toward(velocity.x, 0.0, delta * 8.0)
		velocity.z = move_toward(velocity.z, 0.0, delta * 8.0)
		return
	var wp := waypoints[_wp_index % waypoints.size()]
	if _move_toward(wp, patrol_speed, delta):
		_wp_index = (_wp_index + 1) % waypoints.size()


func _suspicious(delta: float) -> void:
	if not _has_target:
		_enter_patrol()
		return
	if _move_toward(_target, patrol_speed * 1.4, delta):
		# arrived: scan the room briefly
		_pause_timer += delta
		rotate_y(delta * 0.9 * (1.0 if int(_pause_timer * 2.0) % 2 == 0 else -1.0))
		velocity.x = 0.0
		velocity.z = 0.0
		if _pause_timer >= 2.4:
			_enter_patrol()


func _chase(delta: float) -> void:
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_repath_timer = 0.25
		_target = player.global_position
		_has_target = true
		_last_seen = player.global_position
	_move_toward(_target, chase_speed, delta)
	var dist := global_position.distance_to(player.global_position)
	if dist <= catch_distance:
		_attack()


func _search(delta: float) -> void:
	_search_timer -= delta
	if _search_timer <= 0.0:
		_enter_patrol()
		return
	if _has_target and _move_toward(_target, patrol_speed * 1.2, delta):
		# pick a nearby point to sweep next
		_target = _last_seen + Vector3(randf_range(-4, 4), 0, randf_range(-4, 4))
		_has_target = true
	rotate_y(delta * 1.6)


# ---------- movement ----------

## Moves toward `target`; returns true when arrived (XZ distance < 0.55).
func _move_toward(target: Vector3, speed: float, delta: float) -> bool:
	var to: Vector3 = target - global_position
	to.y = 0.0
	if to.length() < 0.55:
		velocity.x = move_toward(velocity.x, 0.0, delta * 10.0)
		velocity.z = move_toward(velocity.z, 0.0, delta * 10.0)
		return true

	var dir := Vector3.ZERO
	if _nav_ok:
		nav.target_position = target
		if nav.is_navigation_finished():
			dir = to.normalized()
		else:
			var next := nav.get_next_path_position()
			var seg: Vector3 = next - global_position
			seg.y = 0.0
			if seg.length() < 0.05:
				dir = to.normalized()
			else:
				dir = seg.normalized()
	else:
		dir = to.normalized()
		dir = _steer_around(dir)

	# face movement direction
	var look := global_position + Vector3(dir.x, 0, dir.z)
	if look.distance_squared_to(global_position) > 0.001:
		look_at(look, Vector3.UP)

	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	return false


## Cheap obstacle steering used when no navmesh is available:
## raycast ahead; if blocked, try rotating the desired direction.
func _steer_around(dir: Vector3) -> Vector3:
	if _ray_free(dir, 1.4):
		return dir
	for a in [0.6, -0.6, 1.2, -1.2, 1.8, -1.8]:
		var cand := dir.rotated(Vector3.UP, a)
		if _ray_free(cand, 1.2):
			return cand
	return dir


func _ray_free(dir: Vector3, length: float) -> bool:
	var from := global_position + Vector3(0, 0.9, 0)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * length)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


## The navmesh treats doorways as open; a closed door blocks us physically.
## Open unlocked doors on contact; a locked door (the exit) makes us give up.
func _check_doors() -> void:
	for i in get_slide_collision_count():
		var collider := get_slide_collision(i).get_collider()
		if collider is DoorInteractable:
			if collider.locked:
				if state == State.CHASE:
					_enter_search(_last_seen)
				else:
					_enter_patrol()
			else:
				collider.force_open()


func _check_stuck(delta: float) -> void:
	var want := Vector2(velocity.x, velocity.z).length()
	if want > 0.2 and global_position.distance_to(_last_pos) < 0.05:
		_stuck_timer += delta
	else:
		_stuck_timer = 0.0
	_last_pos = global_position
	if _stuck_timer > 2.0:
		_stuck_timer = 0.0
		# sidestep to break the jam
		position += global_transform.basis.x * randf_range(-0.8, 0.8)


# ---------- transitions ----------

func _enter_chase() -> void:
	if state == State.CHASE:
		return
	state = State.CHASE
	_lose_timer = 0.0
	_target = player.global_position
	_has_target = true
	AudioManager.play_3d("growl", global_position, -2.0)
	state_changed.emit(state)


func _enter_search(pos: Vector3) -> void:
	state = State.SEARCH
	_target = pos
	_has_target = true
	_search_timer = search_duration
	state_changed.emit(state)


func _enter_patrol() -> void:
	state = State.PATROL
	_has_target = false
	state_changed.emit(state)


func _attack() -> void:
	state = State.DISABLED
	AudioManager.play_2d("jumpscare")
	# lunge visuals handled by HUD jumpscare overlay
	if player.has_method("die"):
		player.die()
	state_changed.emit(state)
