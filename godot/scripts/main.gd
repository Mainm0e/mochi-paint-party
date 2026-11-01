extends Node
## Mochi Sketchbook: game flow (menu -> Home Page -> book pages), camera, input, UI and saving.
## Everything is built in code so the project stays a handful of readable scripts.
## Run with `-- --autotest=<dir>` to play through the slice, save screenshots there and quit.

const PAPER := Color("f8f6f0")
const INK := Color("1f1d24")
const ACCENT := Color("e3789a")
const MUTED := Color("6b6672")
const SAVE_PATH := "user://mochi_sketchbook.json"
const CROPS := {"eyes": Rect2i(272, 527, 480, 240), "mouths": Rect2i(432, 721, 160, 80),
	"cheeks": Rect2i(200, 570, 624, 312), "marks": Rect2i(112, 440, 800, 400)}
const FALL_Y := -6.0            # below this the mochi is redrawn at the last checkpoint
const STAR_COLORS := {"puffy": "dcebff", "stone": "b5b8c6", "sketch": "ffe07a"}

enum Mode { MENU, CREATE, PLAY, PAUSED }

var mode := Mode.MENU
var world: World
var mochi: Mochi
var audio: Audio
var camera: Camera3D
var yaw := 0.0                  # camera orbit around the mochi
var pitch := 0.45               # camera height angle (radians)
var cam_dist := 4.2
var follow := Vector3.ZERO      # smoothed point the play camera orbits
var shake := 0.0
var time := 0.0
var save := {"look": null, "pages": {}, "stickers": [], "music": 0.8, "sfx": 1.0, "look_speed": 0.5, "map_at": "1"}
var has_mochi := false
var environment: Environment
var cinematic := false          # a script is framing the camera (concept renders)
var _from_mirror := false       # the creator was opened from the Home Page mirror

var ui: Control
var menu_card: PanelContainer
var help_label: Label
var play_btn: Button
var make_btn: Button
var creator: PanelContainer
var tab_bar: TabBar
var pane: VBoxContainer
var name_edit: LineEdit
var hud: Control
var hud_name: Label
var page_label: Label
var drops_row: HBoxContainer
var drops_label: Label
var drop_dots: HBoxContainer
var sticker_label: Label
var power_tag: PanelContainer
var speech: PanelContainer
var speech_label: Label
var _speech_until := 0.0
var power_label: Label
var prompt: PanelContainer
var prompt_label: Label
var toast: PanelContainer
var toast_label: Label
var cloud: Control              # thought cloud floating over the mochi
var cloud_label: Label
var _cloud_until := 0.0
var _puff_cooldown := 0.0
var _inhaling := {}             # whatever is being slurped up right now
var _gape_time := 0.0
var _zone := {}
var pause_panel: Control
var home_btn: Button
var win_panel: Control
var win_text: Label
var tab := "Flavor"
var _img_cache := {}
var _told := {}                 # one-time tips already shown
var _just_done := ""            # a page finished this visit: the map celebrates it on the way back
var _sketch_cd := 0.0           # Sketch Mochi: a short pause between drawings


func _ready() -> void:
	_register_input()
	_load_save()
	_build_scene()
	_build_ui()
	world.ate.connect(_on_ate)
	world.checkpoint_reached.connect(func(_i):
		audio.play("collect", -9.0, 0.0, 1.3)
		_toast("Checkpoint!"))
	world.switch_pressed.connect(func():
		audio.play("win", -8.0, 0.0, 1.5)
		think("Ooh, something moved!", 2.0))
	world.smudgie_cleaned.connect(func(): audio.play("squish", -2.0, 0.1, 1.4))
	world.star_poofed.connect(func(): audio.play("click", -6.0, 0.1, 0.7))
	world.bloom_revealed.connect(func(id: String):  # remembered, so a revealed star waits there next visit
		var ps := _page_save(world.level)
		if not ("reveal:" + id) in ps.eaten:
			ps.eaten.append("reveal:" + id)
			_store()
		audio.play("win", -6.0, 0.0, 1.3)
		think("A Bloom Star appeared!", 2.2))
	world.friend_said.connect(func(title: String, text: String, seconds: float):
		speech_label.text = "%s:  %s" % [title, text]
		_speech_until = time + seconds)
	world.race_update.connect(func(text: String):
		audio.play("collect", -6.0, 0.0, 1.4)
		_toast(text))
	enter_level("home")
	set_mode(Mode.MENU)
	audio.set_volume("Music", save.music)
	audio.set_volume("SFX", save.sfx)
	audio.start_music()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autotest="):
			_autotest(a.trim_prefix("--autotest="))
		if a.begins_with("--level="):  # straight into a page (the level editor's Play button)
			if not has_mochi:
				has_mochi = true
				save.look = mochi.look
			enter_level(a.trim_prefix("--level="))
			set_mode(Mode.PLAY)
		if a.begins_with("--shot="):  # save a screenshot a moment after starting, then quit (checks)
			await get_tree().create_timer(2.5).timeout
			if "--overview" in OS.get_cmdline_user_args():  # from high above instead of behind the mochi
				cinematic = true
				ui.visible = false
				environment.fog_depth_end = 200.0
				camera.position = Vector3(0, 48, 52)
				camera.look_at(Vector3.ZERO)
				await get_tree().create_timer(0.2).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(a.trim_prefix("--shot="))
			print("SHOT %s: mochi at %s (scale %s, bob %s), camera at %s" % [world.level, mochi.global_position, mochi.scale, mochi.bob.scale, camera.global_position])
			get_tree().quit()
		if a.begins_with("--worldmap="):
			_worldmap_shots(a.trim_prefix("--worldmap="))


# ================================================================== setup
func _register_input() -> void:
	# keys, plus gamepad: left stick walks, A hops, B spits, Y uses, X boops, Start pauses (right stick looks)
	var binds := {"move_left": [KEY_A, KEY_LEFT, [JOY_AXIS_LEFT_X, -1.0]], "move_right": [KEY_D, KEY_RIGHT, [JOY_AXIS_LEFT_X, 1.0]],
		"move_forward": [KEY_W, KEY_UP, [JOY_AXIS_LEFT_Y, -1.0]], "move_back": [KEY_S, KEY_DOWN, [JOY_AXIS_LEFT_Y, 1.0]],
		"jump": [KEY_SPACE, JOY_BUTTON_A], "pause": [KEY_ESCAPE, JOY_BUTTON_START], "poke": ["mouse_left", JOY_BUTTON_X],
		"sprint": [KEY_SHIFT, JOY_BUTTON_LEFT_SHOULDER], "spit": [KEY_Q, "mouse_right", JOY_BUTTON_B],
		"interact": [KEY_E, JOY_BUTTON_Y]}
	for i in Mochi.EMOTES.size():
		binds["emote_%d" % (i + 1)] = [KEY_1 + i]
	for action in binds:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.25)
		for b in binds[action]:
			var ev: InputEvent
			if b is Array:
				ev = InputEventJoypadMotion.new()
				ev.axis = b[0]
				ev.axis_value = b[1]
			elif b is String:
				ev = InputEventMouseButton.new()
				ev.button_index = MOUSE_BUTTON_LEFT if b == "mouse_left" else MOUSE_BUTTON_RIGHT
			elif b < 32:
				ev = InputEventJoypadButton.new()
				ev.button_index = b
			else:
				ev = InputEventKey.new()
				ev.physical_keycode = b
			InputMap.action_add_event(action, ev)


func _build_scene() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = PAPER
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = PAPER
	env.fog_density = 1.0
	env.fog_depth_begin = 16.0
	env.fog_depth_end = 38.0
	var we := WorldEnvironment.new()
	we.environment = env
	environment = env
	add_child(we)
	audio = Audio.new()
	add_child(audio)
	world = World.new()
	add_child(world)
	mochi = Mochi.new()
	add_child(mochi)
	mochi.shadow = world.blob_shadow(0.95)
	mochi.add_child(mochi.shadow)
	mochi.stepped.connect(func(): audio.play("hop", -10.0 if mochi.exhausted else -8.0, 0.08, 0.85 if mochi.exhausted else 1.0))
	mochi.jumped.connect(func(): audio.play("jump", -3.0, 0.06, 0.8 if mochi.power == "stone" else 1.0))
	mochi.landed.connect(func(): audio.play("land", -4.0, 0.06, 0.7 if mochi.power == "stone" else 1.0))
	mochi.squished.connect(func(): audio.play("squish", -1.0))
	mochi.emoted.connect(func(n: String): audio.play("emote_" + n.to_lower(), -1.0, 0.03))
	mochi.double_jumped.connect(func(): audio.play("jump", -2.0, 0.0, 1.35))
	mochi.tired.connect(func():
		audio.play("emote_sad", -8.0, 0.0, 1.3)
		think(["Huff... puff... I need a little break.", "My mochi legs are wobbly...", "Phew! Let me catch my breath."].pick_random(), 2.5))
	mochi.recovered.connect(func():
		audio.play("emote_happy", -9.0, 0.0, 1.1)
		think(["Okay, ready to go!", "All better!", "Boing! I'm back."].pick_random(), 1.6))
	mochi.gape_started.connect(func(): audio.play("slurp", -2.0, 0.05))
	mochi.gulped.connect(func():
		audio.play("gulp", 0.0, 0.04)
		get_tree().create_timer(0.3).timeout.connect(func(): audio.play("munch", -3.0, 0.06)))
	mochi.puffed.connect(func():
		if mochi.sprinting and _puff_cooldown <= 0.0:
			_puff_cooldown = 8.0
			think(["Huff... huff...", "Getting a bit sweaty!", "Pant, pant..."].pick_random(), 1.4))
	mochi.power_changed.connect(_on_power_changed)
	mochi.spat.connect(func(p: String):
		audio.play("jump", -2.0, 0.05, 1.6)
		world.spit_star(mochi.mouth_position() + mochi.forward() * 0.2, mochi.forward(), Color(STAR_COLORS.get(p, "ffd86b"))))
	mochi.pounded.connect(func(at: Vector3):
		audio.play("gulp", 0.0, 0.0, 0.6)
		shake = 0.25
		world.pound(at))
	camera = Camera3D.new()
	camera.fov = 40.0
	camera.near = 0.05
	camera.far = 120.0
	camera.position = Vector3(4, 3, 6)
	add_child(camera)
	mochi.apply_look(save.look if has_mochi else Mochi.DEFAULT_LOOK.duplicate())


func _load_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		return
	if Mochi.valid_look(data.get("look")):
		save.look = data.look
		has_mochi = true
	if typeof(data.get("pages")) == TYPE_DICTIONARY:
		save.pages = data.pages
	if typeof(data.get("stickers")) == TYPE_ARRAY:
		save.stickers = data.stickers
	save.music = clampf(float(data.get("music", 0.8)), 0.0, 1.0)
	save.sfx = clampf(float(data.get("sfx", 1.0)), 0.0, 1.0)
	save.look_speed = clampf(float(data.get("look_speed", 0.5)), 0.0, 1.0)
	save.map_at = String(data.get("map_at", "1"))


func _store() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(save))


## Bloom Stars eaten on `page` (their ids start with "b_").
func _stars(page: String) -> int:
	return _page_save(page).eaten.filter(func(id): return String(id).begins_with("b_")).size()


func _page_save(page: String) -> Dictionary:
	if not save.pages.has(page):
		save.pages[page] = {"eaten": [], "done": false}
	return save.pages[page]


# ================================================================== levels
## Load the Home Page or a book page and drop the mochi in at its start.
func enter_level(name: String) -> void:
	var on_map := name == "worldmap"
	var eaten: Array = _page_save(name).eaten if not name in ["home", "worldmap"] else []
	if on_map:  # the map shows what is painted, where the mochi last was, and what was just finished
		world.map_stars = {}
		for s in World.STAMPS:
			if world.page_exists(s[5]):
				world.map_stars[s[0]] = _stars(s[5])
		world.map_done = World.STAMPS.filter(func(s): return world.map_stars.get(s[0], 0) >= World.STARS_TO_OPEN) \
			.map(func(s): return s[0])
		world.map_at = save.map_at
		world.map_new = world.stamp_for_level(_just_done)
		_just_done = ""
	world.load_level(name, eaten)
	# on the map the mochi walks the whole book, so it is drawn bigger and the camera pulls back
	mochi.size = 1.7 if on_map else 1.0
	mochi.scale = Vector3.ONE * mochi.size
	cam_dist = 10.0 if on_map else 4.2
	var open_page := not name in ["home", "worldmap"]  # pages are big and open: see further across them
	environment.fog_depth_begin = 40.0 if on_map else (28.0 if open_page else 16.0)
	environment.fog_depth_end = 90.0 if on_map else (70.0 if open_page else 38.0)
	mochi.redraw_at(world.spawn_point())
	mochi.rotation.y = PI  # face into the page (away from the camera)
	yaw = 0.0
	pitch = 0.7 if on_map else 0.45
	follow = mochi.global_position
	_inhaling = {}
	if name == "home":
		world.set_sticker_count(save.stickers.size(), world.PAGES.size() * 5)
	if hud:
		_refresh_hud()
	if on_map and world.map_new != "":
		await get_tree().create_timer(1.3).timeout
		_toast("A new path!")
		think("Look, the page got its colour back!", 3.0)
		return
	if on_map and not _told.has("map"):
		_told["map"] = true
		await get_tree().create_timer(1.0).timeout
		think("The whole sketchbook! Hop onto a stamp and press E.", 3.5)
		return
	if not name in ["home", "worldmap"] and not _told.has("drops"):
		_told["drops"] = true
		await get_tree().create_timer(1.0).timeout
		think("Paint drops! Walk up close and I'll gobble them up.", 3.5)


func _refresh_hud() -> void:
	var page := not world.level in ["home", "worldmap"]
	page_label.text = world.page_name()
	drops_row.visible = page
	_render_drops()
	var got: int = save.stickers.filter(func(s): return String(s).begins_with(world.level + ":")).size() if page \
		else save.stickers.size()
	sticker_label.text = "Stickers  %d / %d" % [got, 5 if page else world.PAGES.size() * 5]
	if world.page_stars(world.level) > 0:
		sticker_label.text = "Bloom Stars  %d / %d\n%s" % [_stars(world.level), world.page_stars(world.level), sticker_label.text]
	home_btn.visible = page
	_on_power_changed(mochi.power, false)


# ================================================================== UI kit (paper card + ink outline)
func _box(bg: Color, border := 3, shadow := 4, radius := 16) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = INK
	sb.set_border_width_all(border)
	sb.set_corner_radius_all(radius)
	sb.corner_radius_top_left = radius + 6
	sb.corner_radius_bottom_right = radius + 6
	sb.shadow_color = INK
	sb.shadow_size = 1 if shadow > 0 else 0
	sb.shadow_offset = Vector2(shadow, shadow)
	sb.set_content_margin_all(10)
	return sb


func _theme() -> Theme:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Segoe Print", "Comic Sans MS", "Gaegu"])
	t.default_font = font
	t.default_font_size = 20
	for cls in ["Label", "Button", "LineEdit", "TabBar"]:
		t.set_color("font_color", cls, INK)
	t.set_color("font_hover_color", "Button", INK)
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_focus_color", "Button", INK)
	t.set_stylebox("normal", "Button", _box(Color.WHITE, 3, 3, 12))
	t.set_stylebox("hover", "Button", _box(Color("fbe3eb"), 3, 4, 12))
	t.set_stylebox("pressed", "Button", _box(Color("f3c9d8"), 3, 1, 12))
	t.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), 2, 0, 12))
	t.set_stylebox("panel", "PanelContainer", _box(Color.WHITE, 3, 5, 18))
	t.set_stylebox("normal", "LineEdit", _box(PAPER, 2, 0, 8))
	t.set_color("font_selected_color", "TabBar", INK)
	t.set_color("font_unselected_color", "TabBar", MUTED)
	t.set_color("font_hovered_color", "TabBar", INK)
	var tab_sel := StyleBoxFlat.new()
	tab_sel.bg_color = Color("fbe3eb")
	tab_sel.border_color = ACCENT
	tab_sel.border_width_bottom = 4
	tab_sel.set_content_margin_all(6)
	var tab_off := tab_sel.duplicate()
	tab_off.bg_color = Color(0, 0, 0, 0)
	tab_off.border_color = Color(0, 0, 0, 0)
	t.set_stylebox("tab_selected", "TabBar", tab_sel)
	t.set_stylebox("tab_unselected", "TabBar", tab_off)
	t.set_stylebox("tab_hovered", "TabBar", tab_off)
	return t


func _label(text: String, size := 20, color := INK) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _button(text: String, primary := false, size := 20) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.pressed.connect(func(): audio.play("click", -5.0, 0.1))
	if primary:
		b.add_theme_stylebox_override("normal", _box(ACCENT, 3, 3, 12))
		b.add_theme_stylebox_override("hover", _box(ACCENT.lightened(0.1), 3, 4, 12))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(c, Color.WHITE)
	return b


func _vbox(gap := 10) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", gap)
	return v


func _hbox(gap := 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", gap)
	return h


func _overlay(title: String, text: String, buttons: Array) -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(PAPER, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var card := PanelContainer.new()
	card.custom_minimum_size.x = 380
	var v := _vbox(10)
	card.add_child(v)
	var t := _label(title, 30)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var p := _label(text, 18, MUTED)
	p.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.visible = text != ""
	p.name = "Text"
	v.add_child(p)
	for b in buttons:
		v.add_child(b)
	center.add_child(card)
	return root


# ================================================================== screens
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.theme = _theme()
	layer.add_child(ui)

	# --- main menu
	menu_card = PanelContainer.new()
	menu_card.anchor_top = 0.5
	menu_card.anchor_bottom = 0.5
	menu_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	menu_card.offset_left = 70
	menu_card.custom_minimum_size = Vector2(400, 0)
	menu_card.rotation_degrees = -1.0
	var mv := _vbox(12)
	menu_card.add_child(mv)
	var logo := _hbox(10)
	logo.alignment = BoxContainer.ALIGNMENT_CENTER
	logo.add_child(_label("Mochi", 42))
	logo.add_child(_label("Sketchbook", 42, ACCENT))
	mv.add_child(logo)
	var sub := _label("Eat the doodles, color the book", 18, MUTED)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mv.add_child(sub)
	play_btn = _button("Play", true, 22)
	make_btn = _button("Make a mochi", false, 22)
	var help_btn := _button("How to play", false, 22)
	for b in [play_btn, make_btn, help_btn]:
		mv.add_child(b)
	help_label = _label("Walk up to things to gobble them up.\nEat paint drops to color the page, eat doodles for powers.\nMouse looks, WASD walks, Shift sprints, Space hops (twice!).\nQ spits out a power, E uses things, Esc for the menu.\nFalling off is fine: you get redrawn at the last flag.", 17)
	help_label.visible = false
	mv.add_child(help_label)
	play_btn.pressed.connect(func():
		if has_mochi:
			set_mode(Mode.PLAY)
		else:
			_from_mirror = false
			set_mode(Mode.CREATE))
	make_btn.pressed.connect(func():
		_from_mirror = false
		set_mode(Mode.CREATE))
	help_btn.pressed.connect(func(): help_label.visible = not help_label.visible)
	ui.add_child(menu_card)

	# --- creator
	creator = PanelContainer.new()
	creator.anchor_left = 1.0
	creator.anchor_right = 1.0
	creator.anchor_bottom = 1.0
	creator.offset_left = -450
	creator.offset_right = -16
	creator.offset_top = 16
	creator.offset_bottom = -16
	var cv := _vbox(8)
	creator.add_child(cv)
	cv.add_child(_label("Make your mochi", 26))
	var nrow := _hbox()
	nrow.add_child(_label("Name", 18, MUTED))
	name_edit = LineEdit.new()
	name_edit.max_length = 16
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_changed.connect(func(t): _set_look({"name": t}, false))
	nrow.add_child(name_edit)
	cv.add_child(nrow)
	tab_bar = TabBar.new()
	for t in ["Flavor", "Topping", "Eyes", "Mouth", "Cheeks", "Mood"]:
		tab_bar.add_tab(t)
	tab_bar.tab_changed.connect(func(i): tab = tab_bar.get_tab_title(i); _render_pane())
	cv.add_child(tab_bar)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pane = _vbox(12)
	pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pane)
	cv.add_child(scroll)
	var foot := _hbox()
	var rand_btn := _button("Surprise me", false, 17)
	var back_btn := _button("Back", false, 17)
	var go_btn := _button("Let's go!", true, 20)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for b in [rand_btn, back_btn, spacer, go_btn]:
		foot.add_child(b)
	cv.add_child(foot)
	rand_btn.pressed.connect(_randomize)
	back_btn.pressed.connect(func(): set_mode(Mode.PLAY if _from_mirror else Mode.MENU))
	go_btn.pressed.connect(func():
		has_mochi = true
		save.look = mochi.look
		_store()
		set_mode(Mode.PLAY)
		_toast("Go, %s!" % _name())
		mochi.emote("Happy"))
	ui.add_child(creator)

	# --- HUD
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tag := PanelContainer.new()
	tag.position = Vector2(16, 14)
	var tv := _vbox(2)
	var name_row := _hbox(10)
	hud_name = _label("Mochi", 20)
	page_label = _label("Home Page", 16, MUTED)
	name_row.add_child(hud_name)
	name_row.add_child(page_label)
	tv.add_child(name_row)
	drops_row = _hbox(5)
	drop_dots = _hbox(4)
	drops_label = _label("0/8", 16, MUTED)
	drops_row.add_child(drop_dots)
	drops_row.add_child(drops_label)
	tv.add_child(drops_row)
	sticker_label = _label("Stickers 0/5", 16, MUTED)
	tv.add_child(sticker_label)
	tag.add_child(tv)
	hud.add_child(tag)
	power_tag = PanelContainer.new()
	power_tag.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	power_tag.add_theme_stylebox_override("panel", _box(Color("fff7e0"), 3, 3, 14))
	power_label = _label("", 17)
	power_tag.add_child(power_label)
	power_tag.visible = false
	tv.add_child(power_tag)  # stacks under the card's lines, however many there are
	var menu_btn := _button("Menu", false, 17)
	menu_btn.anchor_left = 1.0
	menu_btn.anchor_right = 1.0
	menu_btn.offset_left = -100
	menu_btn.offset_right = -16
	menu_btn.offset_top = 14
	menu_btn.pressed.connect(func(): set_mode(Mode.PAUSED))
	hud.add_child(menu_btn)
	var bottom := _vbox(4)
	bottom.anchor_left = 0.5
	bottom.anchor_right = 0.5
	bottom.anchor_top = 1.0
	bottom.anchor_bottom = 1.0
	bottom.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bottom.offset_bottom = -12
	bottom.alignment = BoxContainer.ALIGNMENT_END
	prompt = PanelContainer.new()
	prompt.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	prompt.add_theme_stylebox_override("panel", _box(Color("fbe3eb"), 3, 3, 14))
	prompt_label = _label("", 20)
	prompt.add_child(prompt_label)
	prompt.visible = false
	speech = PanelContainer.new()  # what a doodle friend is saying
	speech.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	speech_label = _label("", 19)
	speech_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	speech_label.custom_minimum_size = Vector2(560, 0)
	speech.add_child(speech_label)
	speech.visible = false
	bottom.add_child(speech)
	bottom.add_child(prompt)
	var emote_card := PanelContainer.new()
	emote_card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var erow := _hbox(6)
	for i in Mochi.EMOTES.size():
		var n: String = Mochi.EMOTES[i]
		var b := _button("%d %s" % [i + 1, n], false, 15)
		b.pressed.connect(func(): mochi.emote(n))
		erow.add_child(b)
	emote_card.add_child(erow)
	bottom.add_child(emote_card)
	var hint := _label("Mouse look  ·  WASD walk  ·  Shift sprint  ·  Space hop (x2)  ·  Q spit  ·  E use  ·  Esc menu", 15, MUTED)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bottom.add_child(hint)
	hud.add_child(bottom)
	toast = PanelContainer.new()
	toast.anchor_left = 0.5
	toast.anchor_right = 0.5
	toast.anchor_top = 0.16
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.rotation_degrees = -2.0
	toast_label = _label("", 28)
	toast.add_child(toast_label)
	toast.visible = false
	hud.add_child(toast)
	# thought cloud: the mochi tells you how it feels and what it just learned
	cloud = Control.new()
	cloud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bubble := PanelContainer.new()
	var bsb := _box(Color.WHITE, 3, 3, 22)
	bsb.set_corner_radius_all(26)
	bsb.content_margin_left = 16
	bsb.content_margin_right = 16
	bubble.add_theme_stylebox_override("panel", bsb)
	cloud_label = _label("", 19)
	bubble.add_child(cloud_label)
	cloud.add_child(bubble)
	for d in [[Vector2(-8, 4), 13.0], [Vector2(-22, 20), 8.0]]:  # little thought dots trailing to the mochi
		var dot := Panel.new()
		var dsb := _box(Color.WHITE, 2, 0, int(d[1]))
		dsb.set_corner_radius_all(int(d[1]))
		dot.add_theme_stylebox_override("panel", dsb)
		dot.size = Vector2(d[1], d[1])
		dot.position = d[0]
		cloud.add_child(dot)
	bubble.position = Vector2(-4, -50)
	cloud.visible = false
	hud.add_child(cloud)
	ui.add_child(hud)

	# --- pause + page complete
	var resume := _button("Keep walking", true)
	var edit := _button("Change my mochi")
	home_btn = _button("Back to the map")
	var restart := _button("Restart this page")
	var to_menu := _button("Main menu")
	resume.pressed.connect(func(): set_mode(Mode.PLAY))
	edit.pressed.connect(func():
		_from_mirror = true
		set_mode(Mode.CREATE))
	home_btn.pressed.connect(func(): enter_level("worldmap"); set_mode(Mode.PLAY))
	restart.pressed.connect(_restart_page)
	to_menu.pressed.connect(func(): set_mode(Mode.MENU))
	pause_panel = _overlay("Paused", "", [resume, edit, home_btn, restart, to_menu, _volume_row("Music", "music"),
		_volume_row("Sounds", "sfx"), _volume_row("Look", "look_speed")])
	ui.add_child(pause_panel)
	var keep := _button("Keep exploring")
	var win_home := _button("Back to the map", true)
	keep.pressed.connect(func(): win_panel.visible = false; set_mode(Mode.PLAY))
	win_home.pressed.connect(func():
		win_panel.visible = false
		enter_level("worldmap")
		set_mode(Mode.PLAY))
	win_panel = _overlay("Page painted!", "", [win_home, keep])
	win_text = win_panel.find_child("Text", true, false)
	win_panel.visible = false
	ui.add_child(win_panel)


func _volume_row(title: String, key: String) -> Control:
	var row := _hbox(10)
	var l := _label(title, 18, MUTED)
	l.custom_minimum_size.x = 80
	row.add_child(l)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = save[key]
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(func(v: float):
		save[key] = v
		if key != "look_speed":
			audio.set_volume("Music" if key == "music" else "SFX", v)
		if key == "sfx":
			audio.play("click", -4.0)
		_store())
	row.add_child(slider)
	return row


func _name() -> String:
	return mochi.look.name if mochi.look.name != "" else "Mochi"


func set_mode(m: Mode) -> void:
	if m == Mode.PLAY and mode in [Mode.MENU, Mode.CREATE]:
		yaw = mochi.rotation.y + PI  # start playing from behind the mochi, looking where it looks
		pitch = 0.45
	mode = m
	menu_card.visible = m == Mode.MENU
	creator.visible = m == Mode.CREATE
	hud.visible = m == Mode.PLAY or m == Mode.PAUSED
	pause_panel.visible = m == Mode.PAUSED
	audio.muffle(m == Mode.PAUSED)
	# third-person play locks the cursor for mouse look; every menu gets it back
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if m == Mode.PLAY else Input.MOUSE_MODE_VISIBLE
	if m == Mode.MENU:
		play_btn.text = "Play as %s" % _name() if has_mochi else "Play"
		make_btn.text = "Change my mochi" if has_mochi else "Make a mochi"
		if world.level != "home":
			enter_level("home")
	if m == Mode.CREATE:
		yaw = mochi.rotation.y  # camera in front of the face
		name_edit.text = mochi.look.name
		_render_pane()
	if m == Mode.PLAY:
		hud_name.text = _name()
		_refresh_hud()
		follow = mochi.global_position
		get_viewport().gui_release_focus()  # so Space hops instead of re-pressing the last button


func _restart_page() -> void:
	if world.level in ["home", "worldmap"]:
		set_mode(Mode.PLAY)
		return
	var ps := _page_save(world.level)
	ps.eaten = []
	ps.done = false
	_store()
	mochi.set_power("")
	enter_level(world.level)
	set_mode(Mode.PLAY)
	_toast("A fresh page")


func _toast(text: String) -> void:
	toast_label.text = text
	toast.visible = true
	toast.reset_size()
	toast.offset_left = -toast.size.x / 2.0
	get_tree().create_timer(1.6).timeout.connect(func(): if toast_label.text == text: toast.visible = false)


func _render_drops() -> void:
	for c in drop_dots.get_children():
		c.queue_free()
	var got := 0
	for d in world.drops:
		var dot := Panel.new()
		dot.custom_minimum_size = Vector2(14, 18)
		var sb := StyleBoxFlat.new()
		sb.bg_color = d.color if d.got else Color.WHITE
		sb.border_color = INK
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(8)
		dot.add_theme_stylebox_override("panel", sb)
		drop_dots.add_child(dot)
		got += 1 if d.got else 0
	drops_label.text = "%d/%d" % [got, world.drops.size()]


func _on_power_changed(p: String, announce := true) -> void:
	power_tag.visible = p != ""
	if p == "":
		return
	power_label.text = "%s   ·   Q to spit it out" % Mochi.POWERS[p].name
	if announce:
		audio.play("win", -8.0, 0.0, 1.25)
		think(Mochi.POWERS[p].hint, 3.5)


## Something was swallowed: count it, save it and react.
func _on_ate(kind: String, e: Dictionary) -> void:
	var ps := _page_save(world.level)
	if kind in ["drop", "sticker", "bloom", "item"] and not e.id in ps.eaten:
		ps.eaten.append(e.id)
	match kind:
		"drop":
			_render_drops()
			audio.play("collect", -2.0, 0.0)
			var left := world.drops_left()
			_toast("One drop left!" if left == 1 else ("All the paint drops!" if left == 0 else "%d drops left" % left))
		"sticker":
			var gid := "%s:%s" % [world.level, e.id]
			if not gid in save.stickers:
				save.stickers.append(gid)
			audio.play("collect", -1.0, 0.0, 1.2)
			_refresh_hud()
			_toast("Sticker found!")
		"power":
			mochi.set_power(e.power)
		"smudgie":
			audio.play("squish", -2.0, 0.1, 1.4)
			think(["Bleh, inky!", "Smudge cleaned up!", "Tastes like a pen..."].pick_random(), 1.6)
		"item":
			audio.play("collect", -2.0, 0.0, 1.1)
			think("I'll keep this safe in my cheeks. Someone must be missing it!", 2.6)
		"bloom":
			audio.play("win", 0.0, 0.0)
			_refresh_hud()
			var n := _stars(world.level)
			_toast("Bloom Star!  %d / %d" % [n, world.page_stars(world.level)])
			if n == World.STARS_TO_OPEN:
				ps.done = true
				_just_done = world.level  # the map celebrates the newly opened path
	_store()
	await get_tree().create_timer(Mochi.MUNCH_TIME).timeout  # let it finish chewing first
	if kind == "bloom":
		mochi.emote("Happy")
		var n := _stars(world.level)
		var total := world.page_stars(world.level)
		await get_tree().create_timer(1.6).timeout
		if n == World.STARS_TO_OPEN:
			think("A new path opened on the World Map!", 3.0)
		if n == total:  # every star found: the whole page is in colour again
			var stickers: int = save.stickers.filter(func(s): return String(s).begins_with(world.level + ":")).size()
			win_text.text = "%s is full of color again!\nBloom Stars %d / %d   ·   Stickers %d / 5" % [
				world.page_name(), n, total, stickers]
			win_text.visible = true
			win_panel.visible = true
			mode = Mode.PAUSED
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif kind == "drop" or kind == "sticker":
		mochi.emote(["Happy", "Love", "Surprised"].pick_random())


# ================================================================== creator
func _set_look(patch: Dictionary, rerender := true) -> void:
	var l: Dictionary = mochi.look.duplicate()
	l.merge(patch, true)
	mochi.apply_look(l)
	if has_mochi:
		save.look = l
		_store()
	if rerender:
		_render_pane()


func _randomize() -> void:
	_set_look({"flavor": Mochi.FLAVORS.values().pick_random(), "topping": Mochi.TOPPINGS.pick_random(),
		"eyes": Mochi.EYES.pick_random(), "eye_color": Mochi.EYE_COLORS.values().pick_random(),
		"mouth": Mochi.MOUTHS.pick_random(), "cheeks": Mochi.CHEEKS.pick_random(),
		"marks": Mochi.MARKS.pick_random(), "accent": Mochi.ACCENTS.values().pick_random()})
	mochi.emote("Happy")


func _layer_image(path: String) -> Image:
	if not _img_cache.has(path):
		var img := mochi.layer(path).get_image()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		_img_cache[path] = img
	return _img_cache[path]


## A small crop of one face layer over the mochi's flavor colour (eyes tinted by their mask).
func _face_icon(group: String, part: String) -> Texture2D:
	var w := 120
	var h := 60
	var bg := Image.create(w, h, false, Image.FORMAT_RGBA8)
	bg.fill(Color(mochi.look.flavor))
	if part != "none":
		var src := _layer_image("%s/%s" % [group, part]).get_region(CROPS[group])
		src.resize(w, h, Image.INTERPOLATE_BILINEAR)
		if group == "eyes":
			var mask := _layer_image("eyes/%s_mask" % part).get_region(CROPS[group])
			mask.resize(w, h, Image.INTERPOLATE_BILINEAR)
			var tint := Color(mochi.look.eye_color)
			for y in h:
				for x in w:
					var c := src.get_pixel(x, y)
					var m := mask.get_pixel(x, y).a
					src.set_pixel(x, y, Color(c.r * lerpf(1.0, tint.r, m), c.g * lerpf(1.0, tint.g, m), c.b * lerpf(1.0, tint.b, m), c.a))
		bg.blend_rect(src, Rect2i(0, 0, w, h), Vector2i.ZERO)
	return ImageTexture.create_from_image(bg)


func _option_grid(title: String, items: Array, key: String, icon: Callable = Callable()) -> Control:
	var v := _vbox(6)
	v.add_child(_label(title, 17, MUTED))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 8)
	for item in items:
		var b := _button(String(item).capitalize(), false, 15)
		if icon.is_valid():
			b.icon = icon.call(item)
			b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
			b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			b.custom_minimum_size = Vector2(124, 0)
		if mochi.look[key] == item:
			b.add_theme_stylebox_override("normal", _box(Color("fbe3eb"), 3, 3, 12))
		b.pressed.connect(func(): _set_look({key: item}))
		flow.add_child(b)
	v.add_child(flow)
	return v


func _swatches(title: String, palette: Dictionary, key: String) -> Control:
	var v := _vbox(6)
	v.add_child(_label(title, 17, MUTED))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 8)
	for n in palette:
		var col := Color(palette[n])
		var b := Button.new()
		b.custom_minimum_size = Vector2(40, 40)
		b.tooltip_text = String(n).capitalize()
		var sb := _box(col, 3, 0, 20)
		if Color(mochi.look[key]).is_equal_approx(col):
			sb.border_color = ACCENT
			sb.set_border_width_all(5)
		for state in ["normal", "hover", "pressed"]:
			b.add_theme_stylebox_override(state, sb)
		b.pressed.connect(func(): audio.play("click", -5.0, 0.1); _set_look({key: palette[n]}))
		flow.add_child(b)
	var pick := ColorPickerButton.new()
	pick.custom_minimum_size = Vector2(40, 40)
	pick.color = Color(mochi.look[key])
	pick.tooltip_text = "Custom colour"
	pick.color_changed.connect(func(c: Color): _set_look({key: c.to_html(false)}, false))
	flow.add_child(pick)
	v.add_child(flow)
	return v


func _render_pane() -> void:
	for c in pane.get_children():
		c.queue_free()
	match tab:
		"Flavor":
			pane.add_child(_swatches("Flavor", Mochi.FLAVORS, "flavor"))
		"Topping":
			pane.add_child(_option_grid("Topping", Mochi.TOPPINGS, "topping"))
			pane.add_child(_swatches("Bow colour", Mochi.ACCENTS, "accent"))
		"Eyes":
			pane.add_child(_option_grid("Eyes", Mochi.EYES, "eyes", func(p): return _face_icon("eyes", p)))
			pane.add_child(_swatches("Eye colour", Mochi.EYE_COLORS, "eye_color"))
		"Mouth":
			pane.add_child(_option_grid("Mouth", Mochi.MOUTHS, "mouth", func(p): return _face_icon("mouths", p)))
		"Cheeks":
			pane.add_child(_option_grid("Cheeks", Mochi.CHEEKS, "cheeks", func(p): return _face_icon("cheeks", p)))
		"Mood":
			pane.add_child(_option_grid("Mood marks", Mochi.MARKS, "marks", func(p): return _face_icon("marks", p)))


# ================================================================== input + camera
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if mode == Mode.PLAY:
			set_mode(Mode.PAUSED)
		elif mode == Mode.PAUSED and not win_panel.visible:
			set_mode(Mode.PLAY)
	if mode == Mode.PLAY:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			# the window lost the cursor (alt-tab etc.): the next click just grabs it again
			if event is InputEventMouseButton and event.pressed:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseMotion:  # third-person mouse look
			var sens := lerpf(0.0008, 0.006, save.look_speed)
			yaw -= event.relative.x * sens
			pitch = clampf(pitch + event.relative.y * sens, -0.15, 1.25)
		if event.is_action_pressed("jump"):
			mochi.jump()
		if event.is_action_pressed("spit"):
			if not mochi.spit():
				think("Nothing to spit! Eat a doodle first.", 1.6)
		if event.is_action_pressed("poke"):
			if mochi.power == "sketch":
				_sketch()
			else:
				mochi.poke()
		if event.is_action_pressed("interact") and not _zone.is_empty():
			_use_zone(_zone)
		for i in Mochi.EMOTES.size():
			if event.is_action_pressed("emote_%d" % (i + 1)):
				mochi.emote(Mochi.EMOTES[i])
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				cam_dist = clampf(cam_dist - 0.3, 2.0, 7.0 * mochi.size)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				cam_dist = clampf(cam_dist + 0.3, 2.0, 7.0 * mochi.size)
	elif mode == Mode.CREATE and event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		yaw -= event.relative.x * 0.008  # spin the mochi around while dressing it up


func _use_zone(z: Dictionary) -> void:
	match z.id:
		"friend":
			audio.play("click", -4.0, 0.1, 1.2)
			world.talk(z.friend)
		"book":
			audio.play("collect", -4.0, 0.0, 0.8)
			enter_level("worldmap")
			_toast(world.page_name())
		"stamp":
			if z.level == "":
				think("This page is still being drawn!", 2.2)
				return
			save.map_at = z.stamp
			_store()
			audio.play("collect", -4.0, 0.0, 0.8)
			enter_level(z.level)
			_toast(world.page_name())
		"home":
			save.map_at = "home"
			_store()
			audio.play("collect", -4.0, 0.0, 0.8)
			enter_level("home")
			_toast(world.page_name())
		"mirror":
			_from_mirror = true
			set_mode(Mode.CREATE)


func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	time += delta
	var input := Vector2.ZERO
	var playing := mode == Mode.PLAY
	if playing:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var look := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
		if look.length() > 0.15:  # gamepad right stick look
			var speed := lerpf(0.6, 3.5, save.look_speed)
			yaw -= look.x * speed * delta
			pitch = clampf(pitch + look.y * speed * 0.7 * delta, -0.15, 1.25)
	if mode != Mode.PAUSED:
		mochi.step(delta, input, yaw, playing and Input.is_action_pressed("sprint"),
			playing and Input.is_action_pressed("jump"))
	if playing:
		world.tick(delta, mochi.global_position)
		world.update_checkpoints(mochi.global_position)
		_eat(delta)
		if mochi.is_on_floor() and mochi.velocity.y <= 0.0 and world.bouncy_at(mochi.global_position):
			mochi.velocity.y = 9.0  # boing! a mushroom cap flings the mochi high
			mochi.jumps = 1
			mochi.squish = 0.0
			audio.play("jump", 0.0, 0.05, 0.7)
		var bump := world.bumping(mochi.global_position)
		if not bump.is_empty():
			mochi.knock(bump.node.global_position)
			audio.play("squish", -2.0, 0.1, 0.8)
			if not _told.has("smudge"):
				_told["smudge"] = true
				think("Ouch! Those Smudgies push. Eat them, or spit a star!", 3.0)
		if mochi.global_position.y < FALL_Y:  # off the page: drawn back in at the last flag
			mochi.redraw_at(world.spawn_point())
			follow = mochi.global_position
			audio.play("slurp", -6.0, 0.0, 1.5)
			think(["Whoops! Redrawn.", "Back on the page!", "Phew, a fresh sketch of me."].pick_random(), 1.8)
		_zone = world.zone_at(mochi.global_position)
		prompt.visible = not _zone.is_empty()
		if prompt.visible:
			prompt_label.text = _zone.prompt
	speech.visible = mode == Mode.PLAY and time < _speech_until
	_update_cloud(delta)
	_update_camera(delta)


## Sketch Mochi draws an ink bridge ahead of its feet (also in mid-air, as a rescue).
func _sketch() -> void:
	if time < _sketch_cd:
		return
	_sketch_cd = time + 0.45
	world.sketch_bridge(mochi.global_position, mochi.forward())
	mochi.poke()  # a little squish as it draws
	audio.play("click", -2.0, 0.08, 0.8)
	if not _told.has("sketch"):
		_told["sketch"] = true
		think("A bridge! It'll rub itself out soon, so hurry across.", 3.0)


## Pop a thought cloud over the mochi for `seconds`.
func think(text: String, seconds: float) -> void:
	cloud_label.text = text
	_cloud_until = time + seconds
	cloud.visible = true
	cloud.scale = Vector2(0.4, 0.4)
	create_tween().tween_property(cloud, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _update_cloud(delta: float) -> void:
	_puff_cooldown = maxf(0.0, _puff_cooldown - delta)
	if mochi.exhausted and time > _cloud_until - 0.3:
		_cloud_until = time + 0.5  # keep the "need a break" thought up until it has rested
	cloud.visible = mode == Mode.PLAY and time < _cloud_until
	var head := mochi.global_position + Vector3(0, 0.62, 0)
	if cloud.visible and not camera.is_position_behind(head):
		cloud.position = camera.unproject_position(head) + Vector2(26, -18)


## Anything edible in reach: the mochi opens wide and inhales it; once it's in, gulp and count it.
func _eat(delta: float) -> void:
	var e := world.nearest_edible(mochi.global_position)
	if e.is_empty() or mochi.eating == "munch":
		world.release(_inhaling)
		_inhaling = {}
		mochi.set_gape(false)
		return
	if not _inhaling.is_empty() and _inhaling.id != e.id:
		world.release(_inhaling)
	if _inhaling.is_empty() or _inhaling.id != e.id:
		_gape_time = 0.0
	_inhaling = e
	mochi.set_gape(true, e.node.global_position)
	_gape_time += delta
	if _gape_time < 0.25:  # wind-up: turn and open wide before the pull starts
		return
	if world.pull(e, mochi.mouth_position(), delta):
		_inhaling = {}
		mochi.gulp()
		world.collect(e)


func _update_camera(delta: float) -> void:
	if cinematic:
		return
	var p := mochi.global_position
	var target: Vector3
	var eye: Vector3
	match mode:
		Mode.MENU:
			var a := time * 0.12
			var right := Vector3(cos(a), 0, -sin(a)) * -0.9  # mochi sits right of the menu card
			target = p + Vector3(0, 0.5, 0) + right
			eye = p + Vector3(sin(a) * 3.6, 1.6, cos(a) * 3.6) + right
		Mode.CREATE:
			var right := Vector3(cos(yaw), 0, -sin(yaw)) * 0.42  # keep the mochi left of the panel
			target = p + Vector3(0, 0.32, 0) + right
			eye = p + Vector3(sin(yaw) * 1.85, 0.75, cos(yaw) * 1.85) + right
		_:
			# orbit a smoothed follow point; yaw/pitch come straight from the mouse so looking stays snappy.
			# Height follows more lazily so hops don't bob the camera.
			follow.x = lerpf(follow.x, p.x, 1.0 - exp(-delta * 10.0))
			follow.z = lerpf(follow.z, p.z, 1.0 - exp(-delta * 10.0))
			follow.y = lerpf(follow.y, p.y, 1.0 - exp(-delta * (6.0 if mochi.is_on_floor() else 2.5)))
			target = follow + Vector3(0, 0.35 * mochi.size, 0)
			var orbit := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * cam_dist
			eye = target + orbit
	var k := 1.0 - exp(-delta * (25.0 if mode == Mode.PLAY else 3.0))
	camera.position = camera.position.lerp(eye, k)
	if shake > 0.0:  # a little thump from the ground pound
		shake = maxf(0.0, shake - delta)
		camera.position += Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * shake * 0.15
	var look_at_now: Vector3 = camera.get_meta("look", target)
	look_at_now = look_at_now.lerp(target, k)
	camera.set_meta("look", look_at_now)
	camera.look_at(look_at_now)


# ================================================================== world map concept renders
## Build the world map diorama and save an overview plus close-ups of each chapter region.
func _worldmap_shots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	cinematic = true
	ui.visible = false
	environment.fog_depth_begin = 70.0
	environment.fog_depth_end = 140.0
	world.map_done = World.STAMPS.map(func(s): return s[0])  # the concept shows the whole book painted
	world.load_level("worldmap")
	mochi.global_position = Vector3(-18, 0.8, 10.5)  # waiting on stamp 1-1
	mochi.scale = Vector3.ONE * 2.2
	mochi.rotation.y = 0.5
	var shots := [
		["map_overview", Vector3(0, 27, 33), Vector3(0, 0, -1.5), 45.0],
		["map_meadow", Vector3(-10, 8, 22), Vector3(-12, 0.5, 7.5), 40.0],
		["map_village", Vector3(-4, 9, 4), Vector3(-13, 0.5, -6), 42.0],
		["map_seaside", Vector3(13, 8, 22), Vector3(12, 0.8, 7), 40.0],
		["map_snowy", Vector3(4, 9, 3), Vector3(12, 0.5, -7), 42.0],
		["map_bloom_castle", Vector3(7, 7, 10), Vector3(-0.5, 2.6, -8), 42.0],
	]
	await get_tree().create_timer(1.5).timeout
	for s in shots:
		camera.position = s[1]
		camera.fov = s[3]
		camera.look_at(s[2])
		await get_tree().create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(dir.path_join(s[0] + ".png"))
	print("WORLDMAP DONE")
	get_tree().quit()


# ================================================================== screenshot tour (plays through the slice)
func _autotest(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var shot := func(name: String):
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(dir.path_join(name + ".png"))
	var wait := func(s: float): await get_tree().create_timer(s).timeout
	var place := func(pos: Vector3, face := PI):
		mochi.global_position = pos
		mochi.velocity = Vector3.ZERO
		mochi.rotation.y = face
		follow = pos
	await wait.call(2.0)
	await shot.call("1_menu")
	_from_mirror = false
	set_mode(Mode.CREATE)
	await wait.call(1.0)
	has_mochi = true
	save.look = mochi.look
	set_mode(Mode.PLAY)
	await wait.call(1.5)
	await shot.call("2_home")
	place.call(Vector3(0, 0.1, -1.4))
	await wait.call(0.4)
	print("AUTOTEST home zone: '%s'" % _zone.get("prompt", ""))
	_use_zone(_zone)
	await wait.call(2.0)
	print("AUTOTEST on the map: %s, painted stamps %s, zones %d" % [world.level, world.map_done, world.zones.size()])
	await shot.call("3_map")
	# walk to stamp 1 and enter the open Meadow
	place.call(Vector3(-18, 0.4, 10.6))
	await wait.call(0.4)
	print("AUTOTEST stamp zone: '%s'" % _zone.get("prompt", ""))
	_use_zone(_zone)
	await wait.call(2.0)
	await shot.call("3b_meadow_start")
	var star_wait := func(before: int):  # stand by a star until it has been gobbled
		for i in 300:
			await get_tree().process_frame
			if _stars(world.level) > before:
				break
		await wait.call(0.3)
	# Pip's quest: hear it, fetch the bow from the far corner, bring it back
	place.call(Vector3(3.5, 0.1, 19.3))
	await wait.call(0.4)
	_use_zone(_zone)
	await wait.call(0.6)
	print("AUTOTEST Pip says: '%s'" % world.friends.pip.said)
	await shot.call("4_pip")
	place.call(Vector3(-28.5, 0.1, -26.3))
	for i in 300:
		await get_tree().process_frame
		if world.has_item("bow"):
			break
	print("AUTOTEST carrying the bow: %s" % world.has_item("bow"))
	await wait.call(1.0)
	place.call(Vector3(3.5, 0.1, 19.3))
	await wait.call(0.4)
	_use_zone(_zone)
	await wait.call(0.8)
	print("AUTOTEST Pip thanks: '%s', star shown %s" % [world.friends.pip.said, world.bloom_shown("b_pip")])
	place.call(Vector3(4.8, 0.1, 19.6))
	await star_wait.call(0)
	print("AUTOTEST stars after Pip: %d" % _stars(world.level))
	# Scribble's hoop race
	place.call(Vector3(9, 0.1, 9.3))
	await wait.call(0.4)
	_use_zone(_zone)
	await wait.call(0.5)
	await shot.call("5_race")
	for h in world.race.hoops:
		place.call(h.global_position - Vector3(0, 0.9, 0))
		await wait.call(0.25)
	print("AUTOTEST race star shown: %s" % world.bloom_shown("b_race"))
	place.call(Vector3(9.0, 0.1, 5.3))
	await star_wait.call(1)
	# the bouncy mushroom
	place.call(Vector3(-4, 1.4, -5))
	var peak := 0.0
	for i in 90:
		await get_tree().process_frame
		peak = maxf(peak, mochi.global_position.y)
	print("AUTOTEST mushroom bounce peak y %.1f" % peak)
	# the cage: eat the pebble, stomp the switch, grab the star
	place.call(Vector3(8, 0.1, -13.8))
	for i in 200:
		await get_tree().process_frame
		if mochi.power == "stone":
			break
	await wait.call(0.6)
	place.call(Vector3(6.8, 0.1, -18))
	await wait.call(0.3)
	mochi.jump()
	await wait.call(0.25)
	mochi.jump()
	await wait.call(1.8)
	print("AUTOTEST cage switch: %s, cage y %.2f" % [world.switches[0].on, world.switches[0].bridge.position.y])
	await shot.call("6_cage")
	place.call(Vector3(4, 0.1, -18.6))
	await star_wait.call(2)
	# the hidden nook behind the giant tree
	place.call(Vector3(-17.2, 0.1, 5.9))
	await star_wait.call(3)
	await shot.call("7_tree")
	# the end of the Ink Trail
	place.call(Vector3(0, 0.4, -84.0))
	await star_wait.call(4)
	print("AUTOTEST stars: %d / %d, page done %s" % [_stars(world.level), world.page_stars("meadow"), _page_save("meadow").done])
	await wait.call(2.0)
	await shot.call("8_trail")
	cinematic = true  # a bird's-eye view of the whole open Meadow
	ui.visible = false
	environment.fog_depth_begin = 80.0
	environment.fog_depth_end = 160.0
	camera.position = Vector3(0, 42, 48)
	camera.look_at(Vector3(0, 0, -12))
	await wait.call(0.3)
	await shot.call("8b_meadow_overview")
	cinematic = false
	ui.visible = true
	# back to the map: the Meadow paints in and the path to the Village draws itself
	enter_level("worldmap")
	set_mode(Mode.PLAY)
	await wait.call(1.0)
	print("AUTOTEST map after 5 stars: opened %s, stars %s, new %s" % [world.map_done, world.map_stars, world.map_new])
	await wait.call(2.5)
	await shot.call("9_map_painted")
	place.call(Vector3(-17, 0.4, -1.4))
	await wait.call(0.4)
	print("AUTOTEST stamp 2 zone: '%s'" % _zone.get("prompt", ""))
	_use_zone(_zone)
	await wait.call(0.6)
	print("AUTOTEST stamp 2 opens: %s" % world.level)
	enter_level("worldmap")
	set_mode(Mode.PLAY)
	await wait.call(1.0)
	await shot.call("10_map_next")
	place.call(Vector3(0, 0.4, 11.1))
	await wait.call(0.4)
	_use_zone(_zone)
	await wait.call(1.0)
	print("AUTOTEST home stamp -> %s" % world.level)
	# --- Chapter 2: the Village
	enter_level("village")
	set_mode(Mode.PLAY)
	await wait.call(2.0)
	await shot.call("11_village_start")
	# eat the pencil doodle, then draw a bridge over the canal to the first star
	place.call(Vector3(-3.5, 0.1, 7.3))
	for i in 200:
		await get_tree().process_frame
		if mochi.power == "sketch":
			break
	await wait.call(1.0)
	print("AUTOTEST power at the pedestal: '%s'" % mochi.power)
	place.call(Vector3(0, 0.1, 2.6), PI)
	yaw = 0.0
	await wait.call(0.3)
	_sketch()
	await wait.call(0.3)
	await shot.call("12_sketch_bridge")
	Input.action_press("move_forward")
	await wait.call(2.2)
	Input.action_release("move_forward")
	await star_wait.call(0)
	print("AUTOTEST walked the sketch bridge: z %.1f y %.2f, stars %d" % [mochi.global_position.z, mochi.global_position.y, _stars("village")])
	# the windmill: sketch from the hill top across to the balcony
	place.call(Vector3(16.6, 2.6, -20.5), PI / 2.0)
	yaw = -PI / 2.0
	await wait.call(0.4)
	_sketch()
	await wait.call(0.2)
	Input.action_press("move_forward")
	await wait.call(2.6)
	Input.action_release("move_forward")
	print("AUTOTEST crossed to the mill balcony: x %.1f y %.2f" % [mochi.global_position.x, mochi.global_position.y])
	await star_wait.call(1)
	await shot.call("13_mill")
	# Postie's letters (stall awning, rooftop, chimney), then hand them in
	for p in [Vector3(-19, 1.85, 8.4), Vector3(-24, 1.1, -12.8), Vector3(8.5, 1.3, -18.4)]:
		place.call(p)
		for i in 200:
			await get_tree().process_frame
			if _inhaling.is_empty() and world.nearest_edible(mochi.global_position).is_empty():
				break
		await wait.call(0.4)
	print("AUTOTEST letters: %s" % [["letter1", "letter2", "letter3"].map(func(l): return world.has_item(l))])
	place.call(Vector3(6, 0.1, 20.6))
	await wait.call(0.4)
	_use_zone(_zone)
	await wait.call(0.6)
	print("AUTOTEST Postie: '%s', star shown %s" % [world.friends.postie.said, world.bloom_shown("b_postie")])
	# the clock tower top and the garden maze (placed, to check the stars are reachable spots)
	place.call(Vector3(-5, 6.2, -25.3))
	await star_wait.call(_stars("village"))
	await shot.call("14_tower")
	place.call(Vector3(22.5, 0.1, 18.5))
	await star_wait.call(_stars("village"))
	print("AUTOTEST village stars: %d / %d" % [_stars("village"), world.page_stars("village")])
	cinematic = true
	ui.visible = false
	environment.fog_depth_end = 200.0
	camera.position = Vector3(-30, 14, -2)
	camera.look_at(Vector3(-10, 3, -20))
	await wait.call(0.3)
	await shot.call("15_rooftops")
	cinematic = false
	ui.visible = true
	print("AUTOTEST DONE")
	get_tree().quit()
