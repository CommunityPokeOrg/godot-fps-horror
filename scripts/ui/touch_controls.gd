extends CanvasLayer
## Touch controls overlay, shown only on devices with a touchscreen
## (Android, iOS, touch-capable web). Desktop sees nothing — keyboard and
## mouse keep working unchanged.
##
## Layout (all built in code, like hud.gd):
##   - floating virtual joystick in the lower-left -> move_* input actions
##   - right ~55% of the screen is a drag-look area -> synthesized
##     InputEventMouseMotion so the player's normal look path applies
##   - action buttons: USE (interact), LIGHT (flashlight), JUMP, CROUCH
##     and SPRINT (toggle-style holds), PAUSE top-right, RETRY on the
##     death/escape screens
## All action buttons drive the existing InputMap actions via
## Input.action_press / Input.action_release, so gameplay code needs no
## changes.

const JOY_RADIUS := 80.0
const JOY_DEADZONE := 0.18
const LOOK_SENS := 2.6

var _enabled := false
var _paused := false

var _joy_zone: Control
var _joy_base: TextureRect
var _joy_knob: TextureRect
var _joy_index := -1
var _joy_center := Vector2.ZERO
var _joy_vec := Vector2.ZERO

var _look_zone: Control
var _look_index := -1

var _pause_btn: Button
var _pause_label: Label
var _retry_btn: Button
var _sprint_btn: Button
var _crouch_btn: Button
var _sprint_on := false
var _crouch_on := false


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_enabled = DisplayServer.is_touchscreen_available() or OS.has_feature("mobile")
	if not _enabled:
		return
	# Player sets MOUSE_MODE_CAPTURED; pointless (and it eats clicks) when
	# there's no pointer — touch UI implies no mouse look to capture.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_look_zone()
	_build_joystick()
	_build_buttons()
	GameManager.state_changed.connect(_on_state_changed)


func _process(_delta: float) -> void:
	if not _enabled:
		return
	# Keep the retry button's visibility in sync cheaply.
	var end_state := GameManager.state == GameManager.State.DEAD \
		or GameManager.state == GameManager.State.ESCAPED
	_retry_btn.visible = end_state


func _circle_tex(size: int, inner: Color, outer: Color) -> GradientTexture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.7, 1.0])
	grad.colors = PackedColorArray([inner, outer])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = size
	tex.height = size
	return tex


func _build_look_zone() -> void:
	_look_zone = Control.new()
	_look_zone.set_anchors_preset(Control.PRESET_FULL_RECT)
	_look_zone.anchor_left = 0.42
	_look_zone.mouse_filter = Control.MOUSE_FILTER_STOP
	_look_zone.gui_input.connect(_on_look_gui_input)
	add_child(_look_zone)


func _build_joystick() -> void:
	_joy_zone = Control.new()
	_joy_zone.set_anchors_preset(Control.PRESET_FULL_RECT)
	_joy_zone.anchor_right = 0.42
	_joy_zone.anchor_top = 0.3
	_joy_zone.mouse_filter = Control.MOUSE_FILTER_STOP
	_joy_zone.gui_input.connect(_on_joy_gui_input)
	add_child(_joy_zone)

	_joy_base = TextureRect.new()
	_joy_base.texture = _circle_tex(256, Color(1, 1, 1, 0.06), Color(1, 1, 1, 0.18))
	_joy_base.custom_minimum_size = Vector2(160, 160)
	_joy_base.size = Vector2(160, 160)
	_joy_base.stretch_mode = TextureRect.STRETCH_SCALE
	_joy_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_joy_base.visible = false
	add_child(_joy_base)

	_joy_knob = TextureRect.new()
	_joy_knob.texture = _circle_tex(128, Color(1, 1, 1, 0.35), Color(1, 1, 1, 0.12))
	_joy_knob.custom_minimum_size = Vector2(64, 64)
	_joy_knob.size = Vector2(64, 64)
	_joy_knob.stretch_mode = TextureRect.STRETCH_SCALE
	_joy_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_joy_knob.visible = false
	add_child(_joy_knob)


func _make_button(text: String, anchor_right: float, anchor_bottom: float,
		off: Vector2, size: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	b.anchor_left = anchor_right
	b.anchor_right = anchor_right
	b.anchor_top = anchor_bottom
	b.anchor_bottom = anchor_bottom
	b.position = off
	b.custom_minimum_size = size
	b.size = size
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_color_override("font_color", Color(0.92, 0.92, 0.88))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.55)
	style.border_color = Color(1, 1, 1, 0.28)
	style.set_border_width_all(2)
	style.set_corner_radius_all(18)
	b.add_theme_stylebox_override("normal", style)
	var pressed := style.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.25, 0.28, 0.32, 0.75)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover", style)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	add_child(b)
	return b


func _build_buttons() -> void:
	# Right-edge column: USE above JUMP.
	var use := _make_button("USE", 1.0, 1.0, Vector2(-240, -170), Vector2(96, 72))
	use.pressed.connect(func(): _pulse_action("interact"))
	var jump := _make_button("JUMP", 1.0, 1.0, Vector2(-120, -110), Vector2(104, 96))
	jump.pressed.connect(func(): _pulse_action("jump"))

	# Inner column: LIGHT above two toggle-style holds.
	var light := _make_button("LIGHT", 1.0, 1.0, Vector2(-360, -170), Vector2(96, 72))
	light.pressed.connect(func(): _pulse_action("flashlight"))
	_crouch_btn = _make_button("CROUCH", 1.0, 1.0, Vector2(-360, -90), Vector2(104, 64))
	_crouch_btn.pressed.connect(_toggle_crouch)
	_sprint_btn = _make_button("SPRINT", 1.0, 1.0, Vector2(-240, -90), Vector2(104, 64))
	_sprint_btn.pressed.connect(_toggle_sprint)

	# Pause, top-right corner.
	_pause_btn = _make_button("II", 1.0, 0.0, Vector2(-70, 22), Vector2(56, 44))
	_pause_btn.pressed.connect(_toggle_pause)

	_pause_label = Label.new()
	_pause_label.text = "PAUSED"
	_pause_label.add_theme_font_size_override("font_size", 44)
	_pause_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	_pause_label.set_anchors_preset(Control.PRESET_CENTER)
	_pause_label.position = Vector2(-110, -100)
	_pause_label.size = Vector2(220, 60)
	_pause_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pause_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_label.visible = false
	add_child(_pause_label)

	# Retry for death/escape screens.
	_retry_btn = _make_button("RETRY", 0.5, 1.0, Vector2(-110, -140), Vector2(220, 84))
	_retry_btn.add_theme_font_size_override("font_size", 26)
	_retry_btn.visible = false
	_retry_btn.pressed.connect(func(): GameManager.reset_run())


## A tap that should behave like one key press (just_pressed for a frame).
func _pulse_action(action: StringName) -> void:
	Input.action_press(action)
	await get_tree().process_frame
	Input.action_release(action)


func _toggle_crouch() -> void:
	_crouch_on = not _crouch_on
	if _crouch_on:
		Input.action_press("crouch")
	else:
		Input.action_release("crouch")
	_crouch_btn.text = "CROUCH*" if _crouch_on else "CROUCH"


func _toggle_sprint() -> void:
	_sprint_on = not _sprint_on
	if _sprint_on:
		Input.action_press("sprint")
	else:
		Input.action_release("sprint")
	_sprint_btn.text = "SPRINT*" if _sprint_on else "SPRINT"


func _toggle_pause() -> void:
	_paused = not _paused
	get_tree().paused = _paused
	_pause_label.visible = _paused
	_pause_btn.text = ">" if _paused else "II"
	if _paused:
		_release_all_actions()


func _release_all_actions() -> void:
	for a in [&"move_forward", &"move_back", &"move_left", &"move_right",
			&"sprint", &"crouch", &"jump", &"interact", &"flashlight"]:
		Input.action_release(a)
	_joy_vec = Vector2.ZERO
	_joy_knob.visible = false
	_joy_base.visible = false
	_joy_index = -1
	_look_index = -1
	if _sprint_on:
		_sprint_on = false
		_sprint_btn.text = "SPRINT"
	if _crouch_on:
		_crouch_on = false
		_crouch_btn.text = "CROUCH"


func _on_state_changed(new_state: int) -> void:
	if new_state != GameManager.State.PLAYING:
		_release_all_actions()


## --- virtual joystick ---
func _on_joy_gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _joy_index == -1:
			_joy_index = event.index
			_joy_center = _joy_zone.position + event.position
			_joy_base.position = _joy_center - Vector2(80, 80)
			_joy_base.visible = true
			_joy_knob.position = _joy_center - Vector2(32, 32)
			_joy_knob.visible = true
		elif not event.pressed and event.index == _joy_index:
			_joy_index = -1
			_joy_base.visible = false
			_joy_knob.visible = false
			_set_move_vector(Vector2.ZERO)
	elif event is InputEventScreenDrag:
		if _joy_index == -1:
			# Finger started outside or the press was swallowed: adopt the
			# drag as a fresh stick centered where it began.
			_joy_index = event.index
			_joy_center = _joy_zone.position + event.position
			_joy_base.position = _joy_center - Vector2(80, 80)
			_joy_base.visible = true
			_joy_knob.position = _joy_center - Vector2(32, 32)
			_joy_knob.visible = true
		if event.index != _joy_index:
			return
		var local: Vector2 = _joy_zone.position + event.position
		var offset: Vector2 = (local - _joy_center) / JOY_RADIUS
		if offset.length() > 1.0:
			offset = offset.normalized()
		_joy_knob.position = _joy_center + offset * JOY_RADIUS - Vector2(32, 32)
		_set_move_vector(offset)


func _set_move_vector(v: Vector2) -> void:
	_joy_vec = v
	# Stick up (negative screen y) -> move_forward.
	_apply_axis(&"move_left", &"move_right", v.x)
	_apply_axis(&"move_forward", &"move_back", -v.y)


func _apply_axis(neg: StringName, pos: StringName, value: float) -> void:
	var dead := JOY_DEADZONE
	if value > dead:
		Input.action_press(pos, clampf(value, 0.0, 1.0))
		Input.action_release(neg)
	elif value < -dead:
		Input.action_press(neg, clampf(-value, 0.0, 1.0))
		Input.action_release(pos)
	else:
		Input.action_release(neg)
		Input.action_release(pos)


## --- drag look ---
func _on_look_gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _look_index == -1:
			_look_index = event.index
		elif not event.pressed and event.index == _look_index:
			_look_index = -1
	elif event is InputEventScreenDrag:
		if _look_index == -1:
			_look_index = event.index
		elif event.index != _look_index:
			return
		var p := GameManager.player as Player
		if p:
			p.look(event.relative * LOOK_SENS)
