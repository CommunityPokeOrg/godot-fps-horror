extends CanvasLayer
## In-game HUD. All controls are built in code so the .tscn stays a
## one-node shell — easier to port into other projects.
##
## Shows: crosshair, interact prompt, battery/stamina/sanity bars,
## objective tracker, toast messages, note-reading overlay, vignette
## driven by darkness + sanity + fear, jumpscare/death and escape screens.

var player: Node = null

var _prompt: Label
var _objective: Label
var _toast: Label
var _hint: Label
var _battery: ProgressBar
var _stamina: ProgressBar
var _sanity: ProgressBar
var _vignette: TextureRect
var _note_panel: PanelContainer
var _note_title: Label
var _note_body: Label
var _death_screen: ColorRect
var _win_screen: ColorRect
var _scare_flash: ColorRect

var _toast_timer := 0.0
var _hint_timer := 10.0


func _ready() -> void:
	add_to_group("hud")
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	GameManager.state_changed.connect(_on_state_changed)
	GameManager.objective_updated.connect(_update_objective)
	GameManager.toast_requested.connect(_show_toast)
	_update_objective()


func _build_ui() -> void:
	# vignette: radial dark overlay
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.45, 1.0])
	grad.colors = PackedColorArray([Color(0, 0, 0, 0), Color(0, 0, 0, 0.9)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 512
	tex.height = 512
	_vignette = TextureRect.new()
	_vignette.texture = tex
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_vignette)

	# jumpscare flash (fullscreen red)
	_scare_flash = _fullscreen_rect(Color(0.45, 0.0, 0.0, 0.0))

	# crosshair
	var ch := ColorRect.new()
	ch.color = Color(1, 1, 1, 0.7)
	ch.custom_minimum_size = Vector2(4, 4)
	ch.set_anchors_preset(Control.PRESET_CENTER)
	ch.position = Vector2(-2, -2)
	add_child(ch)

	# interact prompt
	_prompt = _label(22, Color(0.9, 0.9, 0.85))
	_prompt.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_prompt.position = Vector2(-150, 40)
	_prompt.size = Vector2(300, 30)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_prompt)

	# objective (top-left)
	_objective = _label(16, Color(0.75, 0.75, 0.7))
	_objective.position = Vector2(16, 14)
	_objective.size = Vector2(600, 24)
	add_child(_objective)

	# bars (bottom-left)
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	vbox.position = Vector2(16, -110)
	vbox.size = Vector2(220, 90)
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)
	_battery = _bar("FLASHLIGHT", Color(0.9, 0.75, 0.2), vbox)
	_stamina = _bar("STAMINA", Color(0.3, 0.7, 0.9), vbox)
	_sanity = _bar("SANITY", Color(0.8, 0.3, 0.6), vbox)

	# toast (bottom-center)
	_toast = _label(18, Color(0.85, 0.85, 0.8))
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.position = Vector2(-300, -60)
	_toast.size = Vector2(600, 30)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_toast)

	# controls hint (top-center, fades)
	_hint = _label(15, Color(0.7, 0.7, 0.65))
	_hint.text = "WASD move  ·  Shift sprint  ·  Ctrl crouch  ·  F flashlight  ·  E interact  ·  Esc mouse"
	_hint.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_hint.position = Vector2(-350, 16)
	_hint.size = Vector2(700, 24)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_hint)

	# note reading panel
	_note_panel = PanelContainer.new()
	_note_panel.set_anchors_preset(Control.PRESET_CENTER)
	_note_panel.position = Vector2(-250, -160)
	_note_panel.custom_minimum_size = Vector2(500, 320)
	_note_panel.visible = false
	var nv := VBoxContainer.new()
	nv.add_theme_constant_override("separation", 12)
	_note_panel.add_child(nv)
	_note_title = _label(26, Color(0.9, 0.85, 0.6))
	nv.add_child(_note_title)
	_note_body = _label(16, Color(0.85, 0.82, 0.75))
	_note_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note_body.custom_minimum_size = Vector2(460, 200)
	nv.add_child(_note_body)
	var close_hint := _label(14, Color(0.6, 0.6, 0.55))
	close_hint.text = "[E] close"
	nv.add_child(close_hint)
	add_child(_note_panel)

	# death screen
	_death_screen = _fullscreen_rect(Color(0.02, 0, 0, 0.92))
	_death_screen.visible = false
	var dlabel := _label(64, Color(0.85, 0.1, 0.1))
	dlabel.text = "IT FOUND YOU"
	dlabel.set_anchors_preset(Control.PRESET_CENTER)
	dlabel.position = Vector2(-320, -80)
	dlabel.size = Vector2(640, 90)
	dlabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_screen.add_child(dlabel)
	var dhint := _label(18, Color(0.8, 0.6, 0.6))
	dhint.text = "Press Enter to try again"
	dhint.set_anchors_preset(Control.PRESET_CENTER)
	dhint.position = Vector2(-150, 30)
	dhint.size = Vector2(300, 30)
	dhint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_screen.add_child(dhint)

	# win screen
	_win_screen = _fullscreen_rect(Color(0, 0.02, 0.02, 0.92))
	_win_screen.visible = false
	var wlabel := _label(56, Color(0.7, 0.9, 0.7))
	wlabel.text = "YOU ESCAPED"
	wlabel.set_anchors_preset(Control.PRESET_CENTER)
	wlabel.position = Vector2(-320, -70)
	wlabel.size = Vector2(640, 90)
	wlabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_win_screen.add_child(wlabel)
	var whint := _label(18, Color(0.7, 0.8, 0.7))
	whint.text = "Press Enter to play again"
	whint.set_anchors_preset(Control.PRESET_CENTER)
	whint.position = Vector2(-150, 30)
	whint.size = Vector2(300, 30)
	whint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_win_screen.add_child(whint)


func _label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _fullscreen_rect(color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(r)
	return r


func _bar(name: String, color: Color, parent: Control) -> ProgressBar:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	var l := _label(12, Color(0.65, 0.65, 0.6))
	l.text = name
	l.custom_minimum_size = Vector2(86, 0)
	hb.add_child(l)
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value = 100
	bar.custom_minimum_size = Vector2(120, 12)
	bar.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.09, 0.8)
	bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override("fill", fill)
	hb.add_child(bar)
	parent.add_child(hb)
	return bar


func _process(delta: float) -> void:
	if player == null:
		return
	_battery.value = player.battery
	_stamina.value = player.stamina
	_sanity.value = player.sanity
	_prompt.text = player.get_interact_prompt()

	# vignette intensity: darkness + fear + low sanity
	var darkness := 0.0 if player.flashlight_on else 0.3
	var fear_v: float = player.fear
	var sanity_v: float = 1.0 - player.sanity / maxf(1.0, player.max_sanity)
	_vignette.modulate.a = clampf(darkness + fear_v * 0.35 + sanity_v * 0.4, 0.0, 0.9)

	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			_toast.text = ""
	if _hint_timer > 0.0:
		_hint_timer -= delta
		_hint.modulate.a = clampf(_hint_timer / 3.0, 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if GameManager.state == GameManager.State.READING_NOTE \
			and (event.is_action_pressed("interact") or event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel")):
		_note_panel.visible = false
		GameManager.set_reading(false)
		get_viewport().set_input_as_handled()
	elif GameManager.state == GameManager.State.DEAD or GameManager.state == GameManager.State.ESCAPED:
		if event.is_action_pressed("ui_accept"):
			GameManager.reset_run()


func show_note(title: String, body: String) -> void:
	_note_title.text = title
	_note_body.text = body
	_note_panel.visible = true
	GameManager.set_reading(true)


func _show_toast(text: String) -> void:
	_toast.text = text
	_toast_timer = 3.5
	AudioManager.play_2d("blip", -12.0)


func _update_objective() -> void:
	_objective.text = GameManager.objective_text()


func _on_state_changed(new_state: int) -> void:
	match new_state:
		GameManager.State.DEAD:
			_death_screen.visible = true
			_death_screen.modulate.a = 0.0
			_scare_flash.color.a = 1.0
			var t := create_tween()
			t.tween_property(_scare_flash, "color:a", 0.0, 1.2)
			t.parallel().tween_property(_death_screen, "modulate:a", 1.0, 0.8)
		GameManager.State.ESCAPED:
			_win_screen.visible = true
			_win_screen.modulate.a = 0.0
			var t2 := create_tween()
			t2.tween_property(_win_screen, "modulate:a", 1.0, 1.0)
		GameManager.State.READING_NOTE:
			_prompt.text = ""
