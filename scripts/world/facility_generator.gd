extends Node3D
class_name FacilityGenerator
## Procedurally builds Facility 13: a small bunker/asylum of rooms linked by
## claustrophobic single-cell corridors.
##
## The layout is declared as a set of room/corridor rectangles that are
## carved into a cell grid; walls are generated automatically around carved
## cells (merged into row-runs for few draw calls). Doors, lights, props,
## pickups and the exit are placed from content tables. A NavigationRegion3D
## wraps all level meshes and the navmesh is baked at runtime.
##
## Everything (meshes, materials, textures) is generated in code — no
## external assets needed.

signal nav_ready(success: bool)

const CELL := 3.0          ## metres per grid cell
const WALL_H := 2.8
const DOOR_W := 2.0
const DOOR_H := 2.1

# ---------- layout tables ----------

const ROOMS := [
	Rect2i(1, 1, 6, 4),     # spawn room
	Rect2i(9, 1, 6, 4),     # office
	Rect2i(17, 1, 10, 4),   # ward (enemy territory)
	Rect2i(1, 14, 8, 5),    # storage
	Rect2i(11, 14, 8, 5),   # cell block
	Rect2i(21, 14, 8, 5),   # exit lobby
]

const CORRIDORS := [
	Rect2i(3, 4, 1, 11),    # west spine  (spawn <-> storage)
	Rect2i(11, 4, 1, 11),   # middle spine (office <-> cells)
	Rect2i(21, 4, 1, 11),   # east spine  (ward <-> lobby)
	Rect2i(3, 8, 19, 2),    # main hall linking all spines
]

# door cells: {cell, locked, exit}
const DOORS := [
	{"cell": Vector2i(3, 4), "locked": false, "exit": false},
	{"cell": Vector2i(11, 4), "locked": false, "exit": false},
	{"cell": Vector2i(21, 4), "locked": false, "exit": false},
	{"cell": Vector2i(3, 14), "locked": false, "exit": false},
	{"cell": Vector2i(11, 14), "locked": false, "exit": false},
	{"cell": Vector2i(21, 14), "locked": false, "exit": false},
	{"cell": Vector2i(29, 16), "locked": true, "exit": true},
]

const EXIT_ALCOVE := [Vector2i(30, 16)]   # carved cells beyond the exit door

const SPAWN_CELL := Vector2i(2, 2)
const ENEMY_SPAWN_CELL := Vector2i(24, 3)

const WAYPOINT_CELLS := [
	Vector2i(3, 9), Vector2i(11, 9), Vector2i(21, 9),
	Vector2i(21, 6), Vector2i(11, 6), Vector2i(3, 6),
]

const NOTES := [
	{"cell": Vector2i(12, 2), "title": "Intake Ledger",
	 "body": "Day 41 — Thirteen residents below now. The screaming from the west ward stopped last night. Dr. Halvern says that's progress. God help me, I think he's right."},
	{"cell": Vector2i(25, 2), "title": "Ward Log",
	 "body": "It walks the halls when the lights go out. We stopped counting it as staff weeks ago. Keep your light on. It doesn't like the light. I don't think."},
	{"cell": Vector2i(5, 16), "title": "Maintenance Note",
	 "body": "Flashlight cranks hold charge poorly down here. Spare cells in the office and storage. If the Orderly hears you running, don't run — crouch and pray it passes."},
	{"cell": Vector2i(15, 16), "title": "Last Page",
	 "body": "The exit key was moved to the ward after the incident. Whoever reads this: it's the tall room northeast, the one it guards. Get the four pages, get the key, get out."},
]

const KEY_CELL := Vector2i(25, 3)

const BATTERY_CELLS := [
	Vector2i(13, 3), Vector2i(2, 17), Vector2i(12, 9),
]

# {cell, flicker, on} — "on" false = dead fixture (mesh only)
const LIGHTS := [
	{"cell": Vector2i(5, 9), "flicker": true, "on": true},
	{"cell": Vector2i(9, 9), "flicker": true, "on": true},
	{"cell": Vector2i(13, 9), "flicker": false, "on": true},
	{"cell": Vector2i(17, 9), "flicker": true, "on": true},
	{"cell": Vector2i(4, 2), "flicker": false, "on": true},
	{"cell": Vector2i(12, 2), "flicker": true, "on": true},
	{"cell": Vector2i(21, 2), "flicker": true, "on": true},
	{"cell": Vector2i(4, 16), "flicker": true, "on": true},
	{"cell": Vector2i(14, 16), "flicker": false, "on": true},
	{"cell": Vector2i(24, 16), "flicker": false, "on": true},
	{"cell": Vector2i(7, 8), "flicker": true, "on": false},   # dead fixture
	{"cell": Vector2i(19, 8), "flicker": true, "on": false},  # dead fixture
]

const CRATES := [
	Vector2i(6, 2), Vector2i(6, 17), Vector2i(14, 17),
	Vector2i(8, 9), Vector2i(18, 8), Vector2i(23, 15),
]

const PIPES := [
	Vector2i(3, 7), Vector2i(3, 11), Vector2i(21, 7), Vector2i(11, 10),
]

var grid: Dictionary = {}            ## Vector2i -> true for carved (floor) cells
var nav_region: NavigationRegion3D
var _mats: Dictionary = {}
var _rng := RandomNumberGenerator.new()

var door_scene := preload("res://scenes/props/door.tscn")
var note_scene := preload("res://scenes/props/note.tscn")
var key_scene := preload("res://scenes/props/key.tscn")
var battery_scene := preload("res://scenes/props/battery.tscn")
var exit_trigger_scene := preload("res://scenes/props/exit_trigger.tscn")


func _ready() -> void:
	_rng.seed = 20260921
	_make_materials()
	_carve()
	_build_geometry()
	_build_doors()
	_build_lights()
	_build_props()
	_build_pickups()
	_build_exit_trigger()
	call_deferred("_bake_navmesh")


# ---------- public helpers ----------

func cell_to_world(c: Vector2i) -> Vector3:
	return Vector3(c.x * CELL + CELL * 0.5, 0.0, c.y * CELL + CELL * 0.5)


func spawn_point() -> Vector3:
	return cell_to_world(SPAWN_CELL)


func enemy_spawn_point() -> Vector3:
	return cell_to_world(ENEMY_SPAWN_CELL)


func waypoints() -> PackedVector3Array:
	var out := PackedVector3Array()
	for c in WAYPOINT_CELLS:
		out.append(cell_to_world(c))
	return out


## BFS over carved cells from spawn. Returns content cells that are NOT
## reachable — empty array means the whole level is connected.
func unreachable_content() -> Array:
	var seen := {SPAWN_CELL: true}
	var queue: Array[Vector2i] = [SPAWN_CELL]
	while not queue.is_empty():
		var c: Vector2i = queue.pop_front()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if grid.get(n, false) and not seen.has(n):
				seen[n] = true
				queue.append(n)
	var targets: Array[Vector2i] = [ENEMY_SPAWN_CELL, KEY_CELL]
	targets.append_array(WAYPOINT_CELLS)
	targets.append_array(BATTERY_CELLS)
	for d in DOORS:
		targets.append(d["cell"])
	for n in NOTES:
		targets.append(n["cell"])
	targets.append_array(EXIT_ALCOVE)
	var bad: Array = []
	for t in targets:
		if not seen.has(t):
			bad.append(t)
	return bad


# ---------- construction ----------

func _carve() -> void:
	for r in ROOMS:
		for y in range(r.position.y, r.position.y + r.size.y):
			for x in range(r.position.x, r.position.x + r.size.x):
				grid[Vector2i(x, y)] = true
	for r in CORRIDORS:
		for y in range(r.position.y, r.position.y + r.size.y):
			for x in range(r.position.x, r.position.x + r.size.x):
				grid[Vector2i(x, y)] = true
	for d in DOORS:
		grid[d["cell"]] = true
	for c in EXIT_ALCOVE:
		grid[c] = true


func _build_geometry() -> void:
	nav_region = NavigationRegion3D.new()
	nav_region.name = "NavigationRegion3D"
	add_child(nav_region)

	# bounding box of carved cells for floor/ceiling slabs
	var minc := Vector2i(1 << 30, 1 << 30)
	var maxc := Vector2i(-(1 << 30), -(1 << 30))
	for c in grid.keys():
		minc = minc.min(c)
		maxc = maxc.max(c)
	var size_x := (maxc.x - minc.x + 1) * CELL
	var size_z := (maxc.y - minc.y + 1) * CELL
	var centre := Vector3(minc.x * CELL + size_x * 0.5, 0.0, minc.y * CELL + size_z * 0.5)

	_add_box(nav_region, centre + Vector3(0, -0.1, 0), Vector3(size_x, 0.2, size_z), _mats.floor)
	_add_box(nav_region, centre + Vector3(0, WALL_H + 0.1, 0), Vector3(size_x, 0.2, size_z), _mats.ceiling)

	# walls: uncarved cells adjacent to a carved cell, merged per row
	var wall_cells: Dictionary = {}
	for c in grid.keys():
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
				Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
			var n: Vector2i = c + d
			if not grid.get(n, false):
				wall_cells[n] = true

	# merge contiguous runs along x for each row
	var rows: Dictionary = {}
	for c in wall_cells.keys():
		if not rows.has(c.y):
			rows[c.y] = []
		rows[c.y].append(c.x)
	for y in rows.keys():
		var xs: Array = rows[y]
		xs.sort()
		var run_start: int = xs[0]
		var prev: int = xs[0]
		for i in range(1, xs.size() + 1):
			if i == xs.size() or xs[i] != prev + 1:
				var run_len := prev - run_start + 1
				var wc := Vector3((run_start + run_len * 0.5) * CELL, WALL_H * 0.5, (y + 0.5) * CELL)
				_add_box(nav_region, wc, Vector3(run_len * CELL, WALL_H, CELL), _mats.wall)
				if i < xs.size():
					run_start = xs[i]
					prev = xs[i]
			else:
				prev = xs[i]


func _add_box(parent: Node, centre: Vector3, size: Vector3, mat: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	box.material = mat
	mesh_inst.mesh = box
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	shape.shape = bs
	body.add_child(mesh_inst)
	body.add_child(shape)
	body.position = centre
	parent.add_child(body)
	return body


func _build_doors() -> void:
	for d in DOORS:
		var c: Vector2i = d["cell"]
		var door: DoorInteractable = door_scene.instantiate()
		# passage direction: carved neighbours on +z/-z mean a z-passage
		var z_passage: bool = grid.get(c + Vector2i(0, 1), false) and grid.get(c - Vector2i(0, 1), false)
		var pos := cell_to_world(c) + Vector3(0, DOOR_H * 0.5, 0)
		door.position = pos
		var mesh := BoxMesh.new()
		mesh.material = _mats.door
		var shape := BoxShape3D.new()
		if z_passage:
			mesh.size = Vector3(DOOR_W, DOOR_H, 0.12)
			shape.size = mesh.size
			door.slide_dir = Vector3(1.6, 0, 0)
			# jambs + lintel to seal the 3 m cell around the 2 m door
			_jamb(c, Vector3(1, 0, 0))
		else:
			mesh.size = Vector3(0.12, DOOR_H, DOOR_W)
			shape.size = mesh.size
			door.slide_dir = Vector3(0, 0, 1.6)
			_jamb(c, Vector3(0, 0, 1))
		(door.get_node("Mesh") as MeshInstance3D).mesh = mesh
		(door.get_node("CollisionShape3D") as CollisionShape3D).shape = shape
		door.locked = d["locked"]
		door.is_exit_door = d["exit"]
		if d["exit"]:
			door.lock_message = "Locked. The exit key must be somewhere in the facility."
		add_child(door)


func _jamb(c: Vector2i, across: Vector3) -> void:
	## Fills the gap beside + above a door cell: stub walls either side of
	## the DOOR_W opening and a lintel above DOOR_H.
	var base := cell_to_world(c)
	var stub := (CELL - DOOR_W) * 0.5
	for s in [-1.0, 1.0]:
		var off: Vector3 = Vector3(across.x, 0.0, across.z) * (s * (DOOR_W * 0.5 + stub * 0.5))
		var size: Vector3 = Vector3(stub, DOOR_H, CELL) if across.x > 0 else Vector3(CELL, DOOR_H, stub)
		_add_box(nav_region, base + off + Vector3(0, DOOR_H * 0.5, 0), size, _mats.wall)
	var lintel_size := Vector3(CELL, WALL_H - DOOR_H, CELL)
	_add_box(nav_region, base + Vector3(0, DOOR_H + (WALL_H - DOOR_H) * 0.5, 0), lintel_size, _mats.wall)


func _build_lights() -> void:
	for ld in LIGHTS:
		var c: Vector2i = ld["cell"]
		var base := cell_to_world(c)
		# fixture mesh on the ceiling
		var fix := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.9, 0.08, 0.3)
		box.material = _mats.metal
		fix.mesh = box
		fix.position = base + Vector3(0, WALL_H - 0.05, 0)
		add_child(fix)
		if not ld["on"]:
			continue
		var light := FlickerLight.new()
		light.light_color = Color(1.0, 0.92, 0.75)
		light.spot_range = 11.0
		light.spot_angle = 52.0
		light.base_energy = 2.4
		light.shadow_enabled = true
		if not ld["flicker"]:
			light.flicker_amount = 0.0
		light.position = base + Vector3(0, WALL_H - 0.12, 0)
		light.rotation_degrees.x = -90.0
		add_child(light)


func _build_props() -> void:
	for c in CRATES:
		var base := cell_to_world(c) + Vector3(_rng.randf_range(-0.6, 0.6), 0, _rng.randf_range(-0.6, 0.6))
		var s := _rng.randf_range(0.7, 1.1)
		var crate := _add_box(nav_region, base + Vector3(0, s * 0.5, 0), Vector3(s, s, s), _mats.crate)
		crate.rotation.y = _rng.randf_range(0, PI)
	for c in PIPES:
		# vertical pipe at the edge of a corridor cell
		var base := cell_to_world(c) + Vector3(CELL * 0.45, 0, CELL * 0.45)
		var cyl := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.08
		cm.bottom_radius = 0.08
		cm.height = WALL_H
		cm.material = _mats.metal
		cyl.mesh = cm
		cyl.position = base + Vector3(0, WALL_H * 0.5, 0)
		add_child(cyl)


func _build_pickups() -> void:
	for n in NOTES:
		var note: NoteInteractable = note_scene.instantiate()
		note.position = cell_to_world(n["cell"]) + Vector3(_rng.randf_range(-0.8, 0.8), 0.0, _rng.randf_range(-0.8, 0.8))
		note.rotation.y = _rng.randf_range(0, TAU)
		note.title = n["title"]
		note.body = n["body"]
		add_child(note)
	var key := key_scene.instantiate()
	key.position = cell_to_world(KEY_CELL)
	add_child(key)
	for c in BATTERY_CELLS:
		var b := battery_scene.instantiate()
		b.position = cell_to_world(c) + Vector3(_rng.randf_range(-0.7, 0.7), 0.0, _rng.randf_range(-0.7, 0.7))
		add_child(b)


func _build_exit_trigger() -> void:
	var trig: ExitTrigger = exit_trigger_scene.instantiate()
	trig.position = cell_to_world(EXIT_ALCOVE[0]) + Vector3(0, 1.0, 0)
	add_child(trig)


# ---------- navmesh ----------

func _bake_navmesh() -> void:
	var navmesh := NavigationMesh.new()
	navmesh.agent_radius = 0.4
	navmesh.agent_height = 1.8
	navmesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES
	nav_region.navigation_mesh = navmesh
	# wait two physics frames so the region registers on the map
	await get_tree().physics_frame
	await get_tree().physics_frame
	nav_region.bake_navigation_mesh(false)
	await get_tree().physics_frame
	var ok := nav_region.navigation_mesh != null and nav_region.navigation_mesh.get_vertices().size() > 0
	nav_ready.emit(ok)


# ---------- materials ----------

func _make_materials() -> void:
	_mats.floor = _concrete_mat(Color(0.16, 0.17, 0.18))
	_mats.wall = _concrete_mat(Color(0.32, 0.34, 0.30))
	_mats.ceiling = _concrete_mat(Color(0.10, 0.10, 0.11))
	_mats.metal = _concrete_mat(Color(0.35, 0.37, 0.40), 0.6, 0.5)
	_mats.crate = _concrete_mat(Color(0.38, 0.30, 0.20))
	_mats.paper = _concrete_mat(Color(0.85, 0.82, 0.70))
	_mats.door = _concrete_mat(Color(0.28, 0.30, 0.34), 0.7, 0.4)
	_mats.key = _concrete_mat(Color(0.75, 0.6, 0.15), 0.9, 0.3)
	_mats.battery = _concrete_mat(Color(0.25, 0.6, 0.25), 0.4, 0.5)


func _concrete_mat(base: Color, metallic := 0.0, rough := 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = base
	m.albedo_texture = _noise_tex(base)
	m.metallic = metallic
	m.roughness = rough
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m


func _noise_tex(base: Color) -> ImageTexture:
	## 64x64 subtle grayscale noise + vertical grime streaks; tinted by albedo.
	var img := Image.create_empty(64, 64, false, Image.FORMAT_L8)
	for y in 64:
		for x in 64:
			var v := 200 + _rng.randi_range(-40, 40)
			# occasional vertical grime streak
			if x % 16 == _rng.randi_range(0, 15):
				v = int(v * 0.8)
			img.set_pixel(x, y, Color8(v, v, v))
	return ImageTexture.create_from_image(img)
