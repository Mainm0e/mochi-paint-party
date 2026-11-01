class_name Mochi
extends CharacterBody3D
## The player mochi: loads the rigged glTF, swaps in toon/outline/face shaders, applies a look
## (flavor, topping, face parts) and handles physics movement (walk, sprint, jumps, powers),
## eating, squishes and emotes.

const LAYERS := "res://assets/mochi/layers/"
const INK := Color("5a3a3a")
const EYES := ["bean", "sparkle", "happy", "sleepy", "wink", "dizzy", "heart", "angry", "teary", "shock"]
const MOUTHS := ["smile", "frown", "open", "cat", "grin", "tongue", "wavy", "ooh"]
const CHEEKS := ["none", "soft", "rosy", "lines"]
const MARKS := ["none", "anger", "sweat", "sparkles", "hearts"]
const TOPPINGS := ["None", "Sprout", "Sakura", "Berry", "Bow", "Crown", "Dango"]
const FLAVORS := {"strawberry": "f9c4cc", "matcha": "c3dfa8", "plain": "fbf7f1", "ube": "d2bff0",
	"mango": "ffdc90", "kinako": "e8c9a2", "sakura": "fbd9e4", "blueberry": "bfd0f4"}
const EYE_COLORS := {"cocoa": "5a3a3a", "midnight": "2f3150", "berry": "9b3b5c", "ocean": "2e6ea6",
	"forest": "3d7a4f", "plum": "6a4a9c"}
const ACCENTS := {"pink": "f58faa", "cherry": "e0596f", "sun": "f5c35b", "mint": "7fd1b4", "sky": "7fb5ec",
	"grape": "a585e0"}
const EMOTES := ["Happy", "Love", "Angry", "Sad", "Surprised", "Sleepy"]
const DEFAULT_LOOK := {"name": "Mochi", "flavor": "f9c4cc", "topping": "Sprout", "eyes": "bean", "eye_color": "5a3a3a",
	"mouth": "smile", "cheeks": "soft", "marks": "none", "accent": "f58faa"}

## Doodle powers: eat a power doodle to change flavor and gain one ability, spit it out to drop it.
const POWERS := {
	"puffy": {"name": "Puffy Mochi", "color": "f6f7ff", "hint": "I'm all puffy! Hold Space in the air to float."},
	"stone": {"name": "Stone Mochi", "color": "b5b8c6", "hint": "So heavy! Press Space in the air to stomp."},
	"sketch": {"name": "Sketch Mochi", "color": "ffe9a0", "hint": "I can draw! Click (or X) to sketch a bridge in front of me."},
}

signal stepped
signal jumped
signal landed
signal squished
signal emoted(anim_name: String)
signal double_jumped
signal tired          # stamina ran out
signal recovered      # rested enough to sprint again
signal puffed         # stamina getting low
signal gape_started   # opened wide for something edible
signal gulped         # swallowed it
signal power_changed(power: String)
signal spat(power: String)
signal pounded(at: Vector3)   # a Stone Mochi ground pound hit the floor

const LOW_STAMINA := 35.0
const TIRED_SPEED := 0.7        # an exhausted mochi shuffles
# How the mochi's own face shows its stamina (layered over its chosen look)
const FACE_PUFFED := {"marks": "sweat"}
const FACE_TIRED := {"eyes": "sleepy", "mouth": "wavy", "marks": "sweat"}
# Eating: a huge open mouth while it inhales, then a happy chewing face
const FACE_GAPE := {"mouth": "gape", "eyes": "squeeze", "cheeks": "none", "marks": "none"}
const FACE_MUNCH := {"eyes": "happy", "mouth": "munch", "cheeks": "rosy"}
const MUNCH_TIME := 0.9
const MOUTH := Vector3(0, 0.13, 0.3)   # where food goes in, relative to the mochi (it faces +Z)

const SPEED := 2.6
const SPRINT := 1.7             # sprint speed multiplier
const GRAVITY := -11.0
const JUMP := 3.6
const JUMP_BUFFER := 0.14       # seconds a too-early jump press is remembered
const JUMP_CUT := 0.45           # letting go of jump while rising keeps this much of the upward speed
const COYOTE := 0.12            # a jump still counts this long after walking off an edge
const GLIDE_FALL := -0.7        # Puffy Mochi's slowest fall while holding jump
const GLIDE_SPEED := 3.3
const STAMINA_MAX := 100.0
const SPRINT_DRAIN := 28.0      # per second
const REGEN := 24.0             # per second, after REGEN_DELAY
const REGEN_DELAY := 0.7
const RECOVER_AT := 30.0        # exhausted mochi can sprint again from here
const DOUBLE_JUMP_COST := 18.0

var look := DEFAULT_LOOK.duplicate()
var power := ""
var bob := Node3D.new()        # hop / squash / lean (visual only)
var shadow: MeshInstance3D
var anim: AnimationPlayer
var skeleton: Skeleton3D
var tops := {}
var mats := {}
var face_mat: ShaderMaterial
var phase := 0.0
var land := -1.0
var squish := -1.0
var stamina := STAMINA_MAX
var exhausted := false
var sprinting := false
var gliding := false
var pounding := false
var jumps := 0                  # jumps used since last touching the ground
var eating := ""                # "", "gape" or "munch"
var _air := 0.0                 # time since last on the floor
var _was_floor := true
var _pound_t := 0.0
var _rest := 0.0                # time since stamina was last spent
var _spin := -1.0               # double-jump twirl progress
var _mood := ""                 # "", "puffed" or "tired": drives the face override
var _pant := 0.0
var _eat_target := Vector3.ZERO # what is being inhaled (world space)
var _munch_t := 0.0
var _chomp := -1.0
var _step_count := 0
var _tex_cache := {}
var _hats := {}
var _redraw := 1.0              # 0 -> 1 while being drawn back in at a checkpoint
var size := 1.0                 # bigger on the World Map: scales the body, its stride and its hop
var _buffer := 0.0              # a jump pressed just before landing waits this long to happen
var _cuttable := false          # this jump gets lower if jump is let go early
var _ground_h := 99.0           # how far the floor below is (from the shadow ray)


func _ready() -> void:
	add_child(bob)
	var model: Node3D = preload("res://assets/mochi/mochi.glb").instantiate()
	bob.add_child(model)
	anim = model.find_children("*", "AnimationPlayer", true, false)[0]
	skeleton = model.find_children("*", "Skeleton3D", true, false)[0]
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		_setup_mesh(mi)
	anim.get_animation("Idle").loop_mode = Animation.LOOP_LINEAR
	anim.animation_finished.connect(_on_anim_finished)
	anim.play("Idle")
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 0.62
	shape.shape = capsule
	shape.position.y = 0.31
	add_child(shape)
	collision_layer = 2
	collision_mask = 1
	floor_snap_length = 0.2
	_build_hats()


func layer(path: String) -> Texture2D:
	if not _tex_cache.has(path):
		_tex_cache[path] = load(LAYERS + path + ".png")
	return _tex_cache[path]


func _setup_mesh(mi: MeshInstance3D) -> void:
	if mi.name.begins_with("Mochi_Top_"):
		tops[String(mi.name).trim_prefix("Mochi_Top_")] = mi
	var effect := mi.name.begins_with("Mochi_FX_") or mi.name.begins_with("Mochi_Emote_")
	for s in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(s)
		var key := src.resource_name if src else ""
		if not mats.has(key):
			mats[key] = _material_for(key, src, not effect and key != "MochiFace")
		mi.set_surface_override_material(s, mats[key])


func _material_for(key: String, src: Material, outlined: bool) -> Material:
	if key == "MochiFace":
		face_mat = ShaderMaterial.new()
		face_mat.shader = preload("res://shaders/mochi_face.gdshader")
		face_mat.set_shader_parameter("shine", layer("shine"))
		return face_mat
	if key.begins_with("MochiEmote_"):  # emote faces bring their own painted art
		var d := ShaderMaterial.new()
		d.shader = preload("res://shaders/decal.gdshader")
		d.set_shader_parameter("art", (src as BaseMaterial3D).albedo_texture)
		return d
	if key == "Outline":  # baked inverted hull on the emote effects
		var ink := StandardMaterial3D.new()
		ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ink.albedo_color = INK
		return ink
	return _toon((src as BaseMaterial3D).albedo_color if src is BaseMaterial3D else Color.WHITE,
		0.1 if key == "MochiBody" else 0.06, (0.008 if key == "MochiBody" else 0.0035) if outlined else 0.0)


func _toon(color: Color, rim: float, ink: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/toon.gdshader")
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("rim", rim)
	if ink > 0.0:
		var line := ShaderMaterial.new()
		line.shader = preload("res://shaders/outline.gdshader")
		line.set_shader_parameter("ink", INK)
		line.set_shader_parameter("thickness", ink)
		m.next_pass = line
	return m


## Little hats that show the current power: a puff of cloud, or a pebble cap.
func _build_hats() -> void:
	var puffy := Node3D.new()
	for b in [[0.09, 0.0, 0.0], [0.07, 0.09, -0.01], [0.07, -0.09, 0.0], [0.06, 0.03, 0.07]]:
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = b[0]
		sm.height = b[0] * 2.0
		s.mesh = sm
		s.material_override = _toon(Color("ffffff"), 0.1, 0.006)
		s.position = Vector3(b[1], 0.49 + b[0] * 0.5, b[2])
		puffy.add_child(s)
	var stone := Node3D.new()
	var cap := MeshInstance3D.new()
	var cm := SphereMesh.new()
	cm.radius = 0.12
	cm.height = 0.13
	cm.radial_segments = 7
	cm.rings = 4
	cap.mesh = cm
	cap.material_override = _toon(Color("8e92a3"), 0.05, 0.007)
	cap.position = Vector3(0.03, 0.5, -0.02)
	cap.rotation.z = 0.3
	stone.add_child(cap)
	var sketch := Node3D.new()  # a stubby pencil stuck in the top, tip up
	for part in [[0.05, 0.05, 0.16, "ffd86b", 0.56], [0.0, 0.05, 0.07, "f3d2a6", 0.675], [0.051, 0.051, 0.05, "f59ab4", 0.465]]:
		var p := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = part[0]
		pm.bottom_radius = part[1]
		pm.height = part[2]
		pm.radial_segments = 6
		p.mesh = pm
		p.material_override = _toon(Color(part[3]), 0.05, 0.006)
		p.position = Vector3(0.0, part[4], 0.0)
		sketch.add_child(p)
	sketch.rotation.z = -0.25
	for k in {"puffy": puffy, "stone": stone, "sketch": sketch}:
		var h: Node3D = {"puffy": puffy, "stone": stone, "sketch": sketch}[k]
		h.visible = false
		bob.add_child(h)
		_hats[k] = h


# ------------------------------------------------------------------ look
func apply_look(new_look: Dictionary) -> void:
	look = new_look
	_apply_body()
	_apply_face()


func _apply_body() -> void:
	for n in tops:
		tops[n].visible = n == look.topping and power == ""
	for k in _hats:
		_hats[k].visible = k == power
	var c := Color(look.flavor)
	if power != "":
		c = c.lerp(Color(POWERS[power].color), 0.8)
	mats["MochiBody"].set_shader_parameter("base_color", c)
	if mats.has("Accent"):
		mats["Accent"].set_shader_parameter("base_color", Color(look.accent))


## Paint the face: the chosen look, with stamina moods and eating faces layered on top.
func _apply_face() -> void:
	var f: Dictionary = look.duplicate()
	f.merge(FACE_TIRED if _mood == "tired" else (FACE_PUFFED if _mood == "puffed" else {}), true)
	if eating == "gape":
		f.merge(FACE_GAPE, true)
	elif eating == "munch":
		f.merge(FACE_MUNCH, true)
	face_mat.set_shader_parameter("eyes", layer("eyes/" + f.eyes))
	face_mat.set_shader_parameter("eye_mask", layer("eyes/%s_mask" % f.eyes))
	face_mat.set_shader_parameter("eye_color", Color(f.eye_color))
	face_mat.set_shader_parameter("mouth", layer("mouths/" + f.mouth))
	face_mat.set_shader_parameter("has_cheeks", f.cheeks != "none")
	if f.cheeks != "none":
		face_mat.set_shader_parameter("cheeks", layer("cheeks/" + f.cheeks))
	face_mat.set_shader_parameter("has_marks", f.marks != "none")
	if f.marks != "none":
		face_mat.set_shader_parameter("marks", layer("marks/" + f.marks))


static func valid_look(d: Variant) -> bool:
	if typeof(d) != TYPE_DICTIONARY:
		return false
	for k in DEFAULT_LOOK:
		if not d.has(k):
			return false
	return d.eyes in EYES and d.mouth in MOUTHS and d.cheeks in CHEEKS and d.marks in MARKS and d.topping in TOPPINGS


# ------------------------------------------------------------------ powers
func set_power(p: String) -> void:
	power = p
	pounding = false
	_apply_body()
	_spin = 0.0  # a little twirl as the new flavor kicks in
	power_changed.emit(p)


## Spit out the current power (it flies off as a star). Returns false if there was nothing to spit.
func spit() -> bool:
	if power == "":
		return false
	var p := power
	set_power("")
	_chomp = 0.0
	spat.emit(p)
	return true


# ------------------------------------------------------------------ animation
func emote(anim_name: String) -> void:
	if not anim.has_animation(anim_name):
		return
	skeleton.reset_bone_poses()  # clear faces/effects left by the last emote
	anim.play(anim_name, 0.12)
	emoted.emit(anim_name)


func _on_anim_finished(anim_name: StringName) -> void:
	if anim_name != &"Idle":
		skeleton.reset_bone_poses()
		anim.play("Idle", 0.25)


## On the ground: hop. In the air: Stone Mochi stomps; anyone else double jumps (costs stamina).
func jump() -> void:
	# about to land? keep the press for the landing rather than spending the double jump
	if not is_on_floor() and _air >= COYOTE and velocity.y < 0.0 and _ground_h < 0.45 and power != "stone":
		_buffer = JUMP_BUFFER
		return
	if jumps == 0 and (is_on_floor() or _air < COYOTE):
		velocity.y = JUMP * (0.85 if power == "stone" else 1.0) * sqrt(size)
		jumps = 1
		_air = COYOTE
		_cuttable = true
		jumped.emit()
	elif power == "stone" and not pounding:
		pounding = true
		_pound_t = 0.0
		_spin = 0.0
	elif jumps == 1 and power != "stone" and stamina >= DOUBLE_JUMP_COST:
		velocity.y = JUMP * 0.95 * sqrt(size)  # reset the fall so the second hop always feels high
		jumps = 2
		_spend(DOUBLE_JUMP_COST)
		_spin = 0.0
		_cuttable = true
		double_jumped.emit()
	else:
		_buffer = JUMP_BUFFER


func _spend(amount: float) -> void:
	stamina = maxf(0.0, stamina - amount)
	_rest = 0.0
	if stamina <= 0.0 and not exhausted:
		exhausted = true
		tired.emit()


## Open wide toward `target` (something edible in reach), or close again when it's gone.
func set_gape(on: bool, target := Vector3.ZERO) -> void:
	_eat_target = target
	if on and eating == "":
		eating = "gape"
		_pant = 0.0  # restarts the inhale swell
		_apply_face()
		gape_started.emit()
	elif not on and eating == "gape":
		eating = ""
		_apply_face()


## It made it in: chomp, puff the cheeks and chew happily for a moment.
func gulp() -> void:
	eating = "munch"
	_munch_t = MUNCH_TIME
	_chomp = 0.0
	_apply_face()
	gulped.emit()


func mouth_position() -> Vector3:
	return bob.global_transform * MOUTH


func forward() -> Vector3:
	return Vector3(sin(rotation.y), 0, cos(rotation.y))


func poke() -> void:
	squish = 0.0
	squished.emit()


## Knocked back by a Smudgie (or anything else that bumps it).
func knock(from: Vector3, strength := 4.0) -> void:
	var away := global_position - from
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else -forward()
	velocity = away * strength + Vector3(0, 2.6, 0)
	jumps = 1
	squish = 0.0


## Put back at a checkpoint after falling off the page, drawn back in from nothing.
func redraw_at(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	pounding = false
	gliding = false
	jumps = 0
	eating = ""
	_apply_face()
	_redraw = 0.0


# ------------------------------------------------------------------ movement
## input: x = right, y = back (screen space); yaw: camera yaw; sprint / jump_held: buttons held.
func step(delta: float, input: Vector2, yaw: float, sprint := false, jump_held := false) -> void:
	if input.length() > 1.0:
		input = input.normalized()
	# stamina: sprinting drains it; it refills after a short rest; running dry tires the mochi out
	sprinting = sprint and input.length() > 0.2 and not exhausted and stamina > 0.0 and is_on_floor()
	if sprinting:
		_spend(SPRINT_DRAIN * delta)
	else:
		_rest += delta
		if _rest > REGEN_DELAY:
			stamina = minf(STAMINA_MAX, stamina + REGEN * delta)
	if exhausted and stamina >= RECOVER_AT:
		exhausted = false
		recovered.emit()
	# the face shows how it's doing: a sweat drop when low, sleepy eyes when worn out
	var mood := "tired" if exhausted else ("puffed" if stamina < LOW_STAMINA else "")
	if mood != _mood:
		if mood == "puffed" and _mood == "":
			puffed.emit()
		_mood = mood
		_apply_face()

	# --- horizontal
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var pace := SPRINT if sprinting else (TIRED_SPEED if exhausted else 1.0)
	gliding = power == "puffy" and jump_held and not is_on_floor() and velocity.y < 0.0
	var top_speed := (GLIDE_SPEED if gliding else SPEED * pace) * size
	var want := (right * input.x - fwd * input.y) * top_speed
	if pounding:
		want = Vector3.ZERO
	var grip := 10.0 if is_on_floor() else 4.0
	var hv := Vector2(velocity.x, velocity.z).lerp(Vector2(want.x, want.z), 1.0 - exp(-delta * grip))
	velocity.x = hv.x
	velocity.z = hv.y
	# --- vertical: gravity, Puffy's float, Stone's stomp
	_buffer = maxf(0.0, _buffer - delta)
	if _cuttable and (velocity.y <= 0.0 or not jump_held):  # a tap is a small hop, a hold a full one
		if velocity.y > 0.0:
			velocity.y *= JUMP_CUT
		_cuttable = false
	if not is_on_floor():
		velocity.y += GRAVITY * (1.3 if power == "stone" else 1.0) * delta
		if gliding:
			velocity.y = maxf(velocity.y, GLIDE_FALL)
		if pounding:
			_pound_t += delta
			velocity.y = 1.2 if _pound_t < 0.12 else -15.0  # a tiny hang in the air, then SLAM
	move_and_slide()
	var on_floor := is_on_floor()
	if on_floor:
		if not _was_floor:
			land = 0.0
			jumps = 0
			landed.emit()
			if _buffer > 0.0:  # the jump pressed a moment too early happens now
				_buffer = 0.0
				jump()
			if pounding:
				pounding = false
				land = -0.15  # an extra-heavy landing squash
				pounded.emit(global_position)
		_air = 0.0
	else:
		_air += delta
	_was_floor = on_floor

	# --- facing
	var speed := Vector2(velocity.x, velocity.z).length()
	if eating == "gape":  # turn the open mouth toward the food
		var to := _eat_target - global_position
		rotation.y = lerp_angle(rotation.y, atan2(to.x, to.z), 1.0 - exp(-delta * 14.0))
	elif speed > 0.15 and not pounding:
		rotation.y = lerp_angle(rotation.y, atan2(velocity.x, velocity.z), 1.0 - exp(-delta * 12.0))
	_animate(delta, speed, on_floor)
	_place_shadow()


## Squash, stretch, lean and bounce on the visual `bob` node (the body collider never changes).
func _animate(delta: float, speed: float, on_floor: bool) -> void:
	# bouncy hop-walk: unhurried 'boing, boing, boing'. Sprinting makes each bounce longer and higher.
	var walk := minf(1.0, speed / (SPEED * size)) if on_floor else 0.0
	var cadence := 7.6 if sprinting else (5.6 if exhausted else 6.6)
	phase += delta * cadence * walk
	if on_floor and walk > 0.3 and int(phase / PI) != _step_count:  # one boing per bounce
		stepped.emit()
	_step_count = int(phase / PI)
	var bounce := 0.13 if sprinting else (0.04 if exhausted else 0.09)
	var step_y := absf(sin(phase)) * bounce * walk
	var sy := 1.0 - 0.1 * walk * cos(phase * 2.0)
	var puff := 1.0  # extra width (cheeks, glide)
	if exhausted:  # quick little panting breaths
		_pant += delta
		sy *= 1.0 - 0.045 * sin(_pant * 13.0)
	if not on_floor:
		sy = 1.0 + clampf(velocity.y * 0.04, -0.12, 0.14)
		if gliding:  # spread out wide like a little parachute
			sy = 0.88 + 0.02 * sin(_pant * 9.0)
			puff = 1.14
			_pant += delta
		if pounding:
			sy = 1.25 if _pound_t >= 0.12 else 0.85
	if land >= -0.2 and land < 0.8 and land != -1.0:
		land += delta
		var heavy := 1.6 if land < 0.0 else 1.0
		sy *= 1.0 - 0.2 * heavy * exp(-maxf(land, 0.0) * 7.0) * cos(maxf(land, 0.0) * 18.0)
		if land >= 0.8:
			land = -1.0
	if squish >= 0.0:
		squish += delta
		sy *= 1.0 - 0.18 * exp(-squish * 4.5) * cos(squish * 16.0)
		if squish > 1.6:
			squish = -1.0
	if eating == "gape":  # big inhale: stretch tall, puff up wide, quiver with effort
		_pant += delta
		var grow := minf(1.0, _pant * 5.0)
		sy *= 1.0 + grow * (0.14 + 0.025 * sin(_pant * 34.0))
		puff = 1.0 + grow * 0.12
	if _chomp >= 0.0:  # the big chomp, then chewing
		_chomp += delta
		sy *= 1.0 - 0.28 * exp(-_chomp * 6.0) * cos(_chomp * 15.0)
		puff = maxf(puff, 1.0 + 0.14 * exp(-_chomp * 2.5))
		if eating == "munch":
			sy *= 1.0 - 0.05 * absf(sin(_chomp * 14.0))
		if _chomp > 1.5 and eating != "munch":
			_chomp = -1.0
	if eating == "munch":
		_munch_t -= delta
		if _munch_t <= 0.0:
			eating = ""
			_apply_face()
	bob.position.y = step_y
	var grow_in := 1.0
	if _redraw < 1.0:  # pop back in with a little overshoot
		_redraw = minf(1.0, _redraw + delta * 2.2)
		var k := _redraw - 1.0
		grow_in = maxf(0.01, 1.0 + 2.7 * k * k * k + 1.7 * k * k)
	bob.scale = Vector3(puff / sqrt(sy), sy, puff / sqrt(sy)) * grow_in
	# lean into a sprint, lean back to inhale; a full twirl on double jumps and power-ups
	var lean := -0.22 if eating == "gape" else (0.16 if sprinting else 0.0)
	bob.rotation.x = lerpf(bob.rotation.x, lean, 1.0 - exp(-delta * 8.0))
	if _spin >= 0.0:
		_spin = minf(1.0, _spin + delta / 0.45)
		bob.rotation.y = TAU * (1.0 - pow(1.0 - _spin, 3.0))
		if _spin >= 1.0:
			_spin = -1.0
			bob.rotation.y = 0.0


## Keep the blob shadow on whatever floor is below, shrinking with height.
func _place_shadow() -> void:
	if shadow == null:
		return
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 0.2, 0), global_position + Vector3(0, -30, 0), 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	shadow.visible = not hit.is_empty()
	if hit.is_empty():
		_ground_h = 99.0
	if hit:
		shadow.global_position = hit.position + Vector3(0, 0.015, 0)
		var h: float = global_position.y - hit.position.y
		_ground_h = h
		shadow.scale = Vector3.ONE * clampf(1.0 - h * 0.35, 0.35, 1.0)
