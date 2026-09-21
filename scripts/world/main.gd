extends Node3D
## Entry scene: wires the generated facility, player, enemy and HUD together.

@onready var facility: FacilityGenerator = $Facility
@onready var player: Player = $Player
@onready var enemy: Enemy = $Enemy
@onready var hud: CanvasLayer = $HUD


func _ready() -> void:
	facility.nav_ready.connect(_on_nav_ready)
	player.global_position = facility.spawn_point() + Vector3(0, 0.05, 0)
	# face the room's door on spawn (first door cell)
	player.look_at(facility.cell_to_world(Vector2i(3, 4)), Vector3.UP)
	enemy.global_position = facility.enemy_spawn_point() + Vector3(0, 0.05, 0)
	enemy.configure(facility.waypoints(), player)
	hud.player = player
	GameManager.objective_updated.emit()
	# safety: if navmesh bake never reports, let the enemy use fallback steering
	get_tree().create_timer(6.0).timeout.connect(func() -> void:
		if not enemy._nav_checked:
			enemy.set_navigation_ready(false)
	)


func _on_nav_ready(ok: bool) -> void:
	enemy.set_navigation_ready(ok)
	if not ok:
		GameManager.toast("(navmesh bake failed — enemy uses fallback steering)")
