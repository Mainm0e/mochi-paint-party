class_name World
extends Node3D
## Pages of the sketchbook. A page is a set of paper islands floating over the blank page below, dressed
## with ink-outlined doodles, plus everything the mochi can eat (paint drops, power doodles, stickers,
## Smudgies, the Paint Seal), checkpoints, switches and the stars it spits.
## `load_level()` builds the Home Page or a book page from scratch.

signal ate(kind: String, e: Dictionary)
signal checkpoint_reached(index: int)
signal switch_pressed
signal smudgie_cleaned
signal star_poofed
signal bloom_revealed(id: String)
signal race_update(text: String)
signal friend_said(title: String, text: String, seconds: float)

const REACH := 1.7             # how close something edible must be for the mochi to start inhaling it
const PAPER := Color("f8f6f0")
const WHITE := Color.WHITE
const ISLAND_DEPTH := 0.9
const PAGES := {"meadow": "The Meadow", "village": "The Village"}
const PAGE_STARS := {"meadow": 12, "village": 12}   # Bloom Stars hidden on each page
const STARS_TO_OPEN := 5        # Bloom Stars from a chapter that open the path to the next one
const RACE_TIME := 30.0
const SKETCH_LENGTH := 5.0      # a Sketch Mochi bridge (metres)
const SKETCH_LIFE := 6.0        # seconds before it is rubbed out

var level := ""
var edibles: Array[Dictionary] = []      # kind: drop | power | sticker | smudgie | seal | bloom | item
var friends := {}                        # doodle friends on this page, by id
var bouncers: Array[Dictionary] = []     # bouncy mushroom caps
var nest: Array = []                     # Smudgie ids whose cleanup earns b_nest
var race := {"on": false, "next": 0, "t": 0.0, "hoops": [], "friend": "", "star": "", "time": RACE_TIME}
var flutters: Array[Dictionary] = []     # butterflies
var sketches: Array = []                 # Sketch Mochi bridges standing right now
var spinners: Array = []                 # windmill blades and the like, turning slowly
var _keep: Array = []                    # [x, z, radius] spots props must stay clear of
var reveals := {}                        # editor pages: hidden star id -> "drops" / "smudgies" (what reveals it)
var drops: Array[Dictionary] = []        # the paint drops (for the HUD)
var smudgies: Array[Dictionary] = []
var checkpoints: Array[Dictionary] = []
var active_checkpoint := 0
var zones: Array[Dictionary] = []        # Home Page things to interact with
var paintables: Array[GeometryInstance3D] = []
var clouds: Array[Node3D] = []
var switches: Array[Dictionary] = []
var stars: Array[Dictionary] = []
var rng := RandomNumberGenerator.new()
var time := 0.0

var _toon := preload("res://shaders/toon.gdshader")
var _outline := preload("res://shaders/outline.gdshader")
var _paper := preload("res://shaders/paper.gdshader")
var _mats := {}
var _blob_mat: StandardMaterial3D
var _font: SystemFont
var _beam_mat: StandardMaterial3D


# ================================================================== loading
## Build `name` ("home" or a page id). `eaten` lists edible ids already eaten on this page (they stay gone).
func load_level(name: String, eaten: Array = []) -> void:
	for c in get_children():
		c.queue_free()
	for list in [edibles, drops, smudgies, checkpoints, zones, paintables, clouds, switches, stars, bouncers, nest]:
		list.clear()
	friends.clear()
	flutters.clear()
	sketches.clear()
	spinners.clear()
	_keep.clear()
	reveals.clear()
	race = {"on": false, "next": 0, "t": 0.0, "hoops": [], "friend": "", "star": "", "time": RACE_TIME}
	active_checkpoint = 0
	level = name
	rng.seed = hash(name)
	_build_void()
	if name == "home":
		_build_home()
	elif name == "worldmap":
		_build_worldmap()
	elif name == "village":
		_build_village()
	elif name == "meadow":
		_build_meadow()
	else:
		_build_json(name)
	for id in eaten:  # stars already earned stay revealed (or eaten, below)
		if String(id).begins_with("reveal:"):
			reveal_bloom(String(id).trim_prefix("reveal:"), true)
	for e in edibles:
		if e.id in eaten and e.kind in ["drop", "sticker", "bloom", "item"]:
			collect(e, true)
	var stars_here := bloom_ids()
	if not stars_here.is_empty() and stars_here.all(func(id): return id in eaten):
		_paint_all(true)


func spawn_point() -> Vector3:
	return checkpoints[active_checkpoint].pos + Vector3(0, 0.3, 0)


func page_name() -> String:
	if level == "worldmap" or level == "home":
		return "World Map" if level == "worldmap" else "Home Page"
	return page_title(level)


# ================================================================== materials + shapes
func _doodle_mat(ink: float, radial: bool) -> ShaderMaterial:
	var key := "%s-%s" % [ink, radial]
	if not _mats.has(key):
		var line := ShaderMaterial.new()
		line.shader = _outline
		line.set_shader_parameter("thickness", ink)
		line.set_shader_parameter("radial", radial)
		line.set_shader_parameter("wobble", 0.025)
		var m := ShaderMaterial.new()
		m.shader = _toon
		m.set_shader_parameter("rim", 0.0)
		m.set_shader_parameter("wobble", 0.025)
		m.next_pass = line
		_mats[key] = m
	return _mats[key]


## A white paper prop with an ink outline that remembers the colour it gets once painted.
func doodle(mesh: Mesh, paint: String, pos := Vector3.ZERO, ink := 0.03, radial := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _doodle_mat(ink, radial)
	mi.position = pos
	mi.set_meta("paint", Color(paint))
	mi.set_meta("painted", false)
	mi.set_instance_shader_parameter("albedo", WHITE)
	paintables.append(mi)
	return mi


## A pre-coloured prop (edibles, flags): toon colour + ink outline, never repainted.
func colored(mesh: Mesh, color: String, pos := Vector3.ZERO, ink := 0.022, rim := 0.12) -> MeshInstance3D:
	var line := ShaderMaterial.new()
	line.shader = _outline
	line.set_shader_parameter("thickness", ink)
	var m := ShaderMaterial.new()
	m.shader = _toon
	m.set_shader_parameter("base_color", Color(color))
	m.set_shader_parameter("rim", rim)
	m.next_pass = line
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.position = pos
	return mi


func blob_shadow(size: float) -> MeshInstance3D:
	if _blob_mat == null:
		var g := Gradient.new()
		g.set_color(0, Color(0.24, 0.21, 0.27, 0.28))
		g.set_color(1, Color(0.24, 0.21, 0.27, 0.0))
		var tex := GradientTexture2D.new()
		tex.gradient = g
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(1.0, 0.5)
		_blob_mat = StandardMaterial3D.new()
		_blob_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_blob_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_blob_mat.albedo_texture = tex
	var q := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(size, size)
	q.mesh = pm
	q.material_override = _blob_mat
	q.position.y = 0.012
	return q


func _cyl(top: float, bottom: float, h: float, seg := 10) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = h
	m.radial_segments = seg
	m.rings = 1
	return m


func _sphere(r: float, seg := 14, rings := 8, hemi := false) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r if hemi else r * 2.0
	m.radial_segments = seg
	m.rings = rings
	m.is_hemisphere = hemi
	return m


func _box(x: float, y: float, z: float) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = Vector3(x, y, z)
	return m


## Flat star (x/y plane, facing +z) extruded a little: stickers, spat stars, the seal's emblem.
func _star_mesh(outer: float, inner: float, depth: float) -> ArrayMesh:
	var pts: Array[Vector2] = []
	for i in 10:
		var r := outer if i % 2 == 0 else inner
		var a := PI / 2.0 + i * PI / 5.0
		pts.append(Vector2(cos(a), sin(a)) * r)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [1.0, -1.0]:
		for i in 10:
			var a := pts[i]
			var b := pts[(i + 1) % 10]
			# Godot treats clockwise triangles as front faces, so each face is wound clockwise from outside
			var tri := [Vector3(0, 0, side * depth), Vector3(b.x, b.y, side * depth), Vector3(a.x, a.y, side * depth)]
			if side < 0:
				tri = [tri[0], tri[2], tri[1]]
			for v in tri:
				st.add_vertex(v)
	for i in 10:
		var a := pts[i]
		var b := pts[(i + 1) % 10]
		var q := [Vector3(a.x, a.y, depth), Vector3(a.x, a.y, -depth), Vector3(b.x, b.y, -depth), Vector3(b.x, b.y, depth)]
		for v in [q[0], q[2], q[1], q[0], q[3], q[2]]:
			st.add_vertex(v)
	st.generate_normals()
	return st.commit()


func _drop_mesh() -> ArrayMesh:
	var prof: Array[Vector2] = []
	for i in 17:
		var a := i / 16.0 * PI
		prof.append(Vector2(0.17 * sin(a) * pow(sin(a / 2.0), 0.8) + 0.0001, 0.22 * cos(a)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 18
	for i in prof.size() - 1:
		for j in seg:
			var a0 := j / float(seg) * TAU
			var a1 := (j + 1) / float(seg) * TAU
			var p := [Vector3(cos(a0) * prof[i].x, prof[i].y, sin(a0) * prof[i].x),
				Vector3(cos(a1) * prof[i].x, prof[i].y, sin(a1) * prof[i].x),
				Vector3(cos(a1) * prof[i + 1].x, prof[i + 1].y, sin(a1) * prof[i + 1].x),
				Vector3(cos(a0) * prof[i + 1].x, prof[i + 1].y, sin(a0) * prof[i + 1].x)]
			for v in [p[0], p[2], p[1], p[0], p[3], p[2]]:
				st.add_vertex(v)
	st.index()
	st.generate_normals()
	return st.commit()


func _pick(list: Array) -> Variant:
	return list[rng.randi() % list.size()]


## Add `node` at `pos` (with an optional blob shadow) and, if `shape` is given, a solid collider.
func place(node: Node3D, pos: Vector3, scale_by := 1.0, shadow := 0.0, rot_y := INF, shape: Shape3D = null,
		shape_offset := Vector3.ZERO) -> Node3D:
	node.position = pos
	node.rotation.y = rng.randf() * TAU if rot_y == INF else rot_y
	node.scale = Vector3.ONE * scale_by
	add_child(node)
	if shadow > 0.0:
		var s := blob_shadow(shadow * scale_by)
		s.position = pos + Vector3(0, 0.012, 0)
		add_child(s)
	if shape:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.position = shape_offset
		body.add_child(cs)
		node.add_child(body)
	return node


func _cyl_shape(r: float, h: float) -> CylinderShape3D:
	var s := CylinderShape3D.new()
	s.radius = r
	s.height = h
	return s


func _box_shape(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s


# ================================================================== ground: islands over a blank page
func _build_void() -> void:
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	plane.mesh = pm
	var m := ShaderMaterial.new()
	m.shader = _paper
	m.set_shader_parameter("paper", Color("ebe7df"))
	m.set_shader_parameter("grid", 2.5)
	plane.material_override = m
	plane.position.y = -9.0
	add_child(plane)
	for k in 10:
		var c := cloud()
		c.position = Vector3(rng.randf_range(-20, 20), rng.randf_range(4.5, 7.0), rng.randf_range(-60, 10))
		c.scale = Vector3.ONE * rng.randf_range(0.8, 1.6)
		add_child(c)
		clouds.append(c)


## A thick paper slab whose top is at `top`; painted a soft colour once the page is coloured in.
func island(x: float, z: float, sx: float, sz: float, top: float, paint := "e3f1d4", depth := ISLAND_DEPTH) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = Vector3(x, top - depth / 2.0, z)
	var cs := CollisionShape3D.new()
	cs.shape = _box_shape(Vector3(sx, depth, sz))
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = _box(sx, depth, sz)
	if not _mats.has("paper"):
		var line := ShaderMaterial.new()
		line.shader = _outline
		line.set_shader_parameter("thickness", 0.035)
		line.set_shader_parameter("radial", true)
		var m := ShaderMaterial.new()
		m.shader = _paper
		m.next_pass = line
		_mats["paper"] = m
	mi.material_override = _mats["paper"]
	mi.set_meta("paint", Color(paint))
	mi.set_meta("painted", false)
	mi.set_instance_shader_parameter("albedo", WHITE)
	paintables.append(mi)
	body.add_child(mi)
	add_child(body)
	return body


# ================================================================== doodle props
func tree() -> Node3D:
	var g := Node3D.new()
	g.add_child(doodle(_cyl(0.09, 0.14, 0.95, 8), "d9b38c", Vector3(0, 0.47, 0), 0.025))
	var crown: String = _pick(["a8d8a0", "9fd0b4", "c3e2a0", "b5dc96"])
	for b in [[0.58, 0.0, 1.35, 0.0], [0.42, 0.34, 1.05, 0.12], [0.4, -0.3, 1.12, -0.08], [0.36, 0.05, 1.7, -0.05]]:
		g.add_child(doodle(_sphere(b[0]), crown, Vector3(b[1], b[2], b[3]), 0.032))
	return g


func house() -> Node3D:
	var g := Node3D.new()
	var roof := _cyl(0.0, 1.25, 0.85, 4)
	g.add_child(doodle(_box(1.6, 1.1, 1.3), _pick(["f7d9b0", "cfe3f7", "f7cfe0", "e2f0c8"]), Vector3(0, 0.55, 0), 0.03, true))
	var r := doodle(roof, _pick(["e88f8f", "8fb5e8", "b79be8", "f0b46a"]), Vector3(0, 1.52, 0), 0.03, true)
	r.rotation.y = PI / 4.0
	g.add_child(r)
	g.add_child(doodle(_box(0.36, 0.62, 0.05), "c99a6a", Vector3(0.1, 0.31, 0.66), 0.018, true))
	g.add_child(doodle(_box(0.3, 0.3, 0.05), "bfe6ff", Vector3(-0.45, 0.68, 0.66), 0.018, true))
	g.add_child(doodle(_box(0.3, 0.3, 0.05), "bfe6ff", Vector3(0.55, 0.72, 0.66), 0.018, true))
	return g


func rock() -> Node3D:
	var g := Node3D.new()
	var m := doodle(_sphere(0.4, 7, 4), _pick(["cfd3e0", "d8cfe0", "d6dccf"]), Vector3(0, 0.2, 0), 0.03)
	m.scale = Vector3(1.25, 0.7, 1.0)
	g.add_child(m)
	return g


func mushroom() -> Node3D:
	var g := Node3D.new()
	g.add_child(doodle(_cyl(0.08, 0.11, 0.36), "fff3e0", Vector3(0, 0.18, 0), 0.02))
	g.add_child(doodle(_sphere(0.28, 16, 6, true), _pick(["f2828f", "f5a35b", "b79be8"]), Vector3(0, 0.34, 0), 0.025))
	return g


func flower() -> Node3D:
	var g := Node3D.new()
	var head: String = _pick(["ff9ab5", "ffd86b", "b9a2ee", "8fd0f5", "ffb38a"])
	g.add_child(doodle(_cyl(0.014, 0.018, 0.32, 6), "8fc98a", Vector3(0, 0.16, 0), 0.012))
	for k in 5:
		var a := k / 5.0 * TAU
		g.add_child(doodle(_sphere(0.055, 8, 4), head, Vector3(cos(a) * 0.06, 0.34, sin(a) * 0.06), 0.012))
	g.add_child(doodle(_sphere(0.04, 8, 4), "ffe9a8", Vector3(0, 0.36, 0), 0.012))
	return g


func pencil() -> Node3D:
	var g := Node3D.new()
	var parts := [
		[_cyl(0.3, 0.3, 3.6, 6), "ffd86b", 0.0, PI / 2.0], [_cyl(0.0, 0.3, 0.75, 6), "f3d2a6", 2.17, -PI / 2.0],
		[_cyl(0.0, 0.1, 0.25, 6), "5a5560", 2.47, -PI / 2.0], [_cyl(0.31, 0.31, 0.25, 12), "c9c9d2", -1.92, PI / 2.0],
		[_cyl(0.29, 0.29, 0.4, 12), "f59ab4", -2.24, PI / 2.0],
	]
	for p in parts:
		var m := doodle(p[0], p[1], Vector3(p[2], 0.3, 0), 0.03)
		m.rotation.z = p[3]
		g.add_child(m)
	return g


func cloud() -> Node3D:
	var g := Node3D.new()
	for b in [[0.7, 0.0, 0.0], [0.55, 0.75, -0.1], [0.5, -0.7, -0.12], [0.45, 0.3, 0.38]]:
		g.add_child(doodle(_sphere(b[0]), "dcebff", Vector3(b[1], b[2], 0), 0.04))
	return g


func _scatter(kind: Callable, center: Vector3, radius: float, count: int, min_scale := 0.8, max_scale := 1.3) -> void:
	for k in count:
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * radius
		place(kind.call(), center + Vector3(cos(a) * r, 0, sin(a) * r), rng.randf_range(min_scale, max_scale))


func _tree(pos: Vector3, s := 1.0) -> void:
	place(tree(), pos, s, 1.8, INF, _cyl_shape(0.2, 2.0), Vector3(0, 1.0, 0))


# ================================================================== edibles
func _edible(kind: String, id: String, node: Node3D, extra := {}) -> Dictionary:
	add_child(node)
	var sh := blob_shadow(0.6)
	sh.position = Vector3(node.position.x, node.position.y - 0.54, node.position.z)
	add_child(sh)
	var e := {"kind": kind, "id": id, "node": node, "home": node.position, "shadow": sh, "got": false, "sucking": false}
	e.merge(extra)
	edibles.append(e)
	return e


func paint_drop(id: String, pos: Vector3, color: String) -> void:
	var node := colored(_drop_mesh(), color, pos + Vector3(0, 0.55, 0), 0.022, 0.15)
	drops.append(_edible("drop", id, node, {"color": Color(color)}))


## A power doodle sitting on a little pedestal; it grows back a few seconds after being eaten.
func power_doodle(power: String, pos: Vector3) -> void:
	place(doodle(_cyl(0.18, 0.24, 0.28, 10), "e6c79c", Vector3(0, 0.14, 0), 0.02), pos, 1.0, 0.8, 0.0,
		_cyl_shape(0.24, 0.28), Vector3(0, 0.14, 0))
	var node := Node3D.new()
	if power == "puffy":
		for b in [[0.17, 0.0, 0.0], [0.13, 0.17, -0.02], [0.13, -0.17, 0.0], [0.11, 0.05, 0.12]]:
			node.add_child(colored(_sphere(b[0]), "ffffff", Vector3(b[1], b[2], 0.0), 0.02))
	elif power == "sketch":  # a little pencil, leaning
		var pen := Node3D.new()
		pen.add_child(colored(_cyl(0.08, 0.08, 0.36, 6), "ffd86b", Vector3.ZERO, 0.02, 0.1))
		pen.add_child(colored(_cyl(0.0, 0.08, 0.14, 6), "f3d2a6", Vector3(0, 0.25, 0), 0.02, 0.05))
		pen.add_child(colored(_cyl(0.081, 0.081, 0.08, 8), "f59ab4", Vector3(0, -0.22, 0), 0.02, 0.05))
		pen.rotation.z = 0.6
		node.add_child(pen)
	else:
		var pebble := colored(_sphere(0.2, 7, 4), "9ea2b2", Vector3.ZERO, 0.02, 0.05)
		pebble.scale = Vector3(1.2, 0.8, 1.0)
		node.add_child(pebble)
	node.position = pos + Vector3(0, 0.7, 0)
	_edible("power", "power_%s" % power, node, {"power": power})


func sticker(id: String, pos: Vector3) -> void:
	var node := colored(_star_mesh(0.2, 0.09, 0.03), "ffd86b", pos + Vector3(0, 0.55, 0), 0.02, 0.2)
	_edible("sticker", id, node)


func paint_seal(pos: Vector3) -> void:
	var node := Node3D.new()
	var disc := colored(_cyl(0.75, 0.75, 0.16, 28), "2b2530", Vector3.ZERO, 0.03, 0.05)
	disc.rotation.x = PI / 2.0
	node.add_child(disc)
	node.add_child(colored(_star_mesh(0.42, 0.18, 0.05), "fbf7f1", Vector3(0, 0, 0.1), 0.0, 0.0))
	node.add_child(colored(_star_mesh(0.42, 0.18, 0.05), "fbf7f1", Vector3(0, 0, -0.1), 0.0, 0.0))
	node.position = pos + Vector3(0, 1.0, 0)
	var e := _edible("seal", "seal", node)
	e.shadow.scale = Vector3.ONE * 2.2


func smudgie(id: String, pos: Vector3, roam := 2.0) -> void:
	var node := Node3D.new()
	var blob := colored(_sphere(0.26, 14, 8), "26232b", Vector3(0, 0.2, 0), 0.0, 0.18)
	blob.scale = Vector3(1.2, 0.8, 1.0)
	node.add_child(blob)
	for sx in [-1.0, 1.0]:
		node.add_child(colored(_sphere(0.075, 10, 6), "ffffff", Vector3(sx * 0.1, 0.27, 0.2), 0.0, 0.0))
		node.add_child(colored(_sphere(0.035, 8, 5), "1f1d24", Vector3(sx * 0.1, 0.27, 0.27), 0.0, 0.0))
	for k in 3:  # little drippy feet
		var a := k / 3.0 * TAU
		node.add_child(colored(_sphere(0.08, 8, 5), "26232b", Vector3(cos(a) * 0.2, 0.04, sin(a) * 0.2), 0.0, 0.1))
	node.position = pos
	var e := _edible("smudgie", id, node, {"center": pos, "roam": roam, "target": pos, "stun": 0.0, "bump_cd": 0.0})
	e.shadow.position.y = pos.y + 0.012
	smudgies.append(e)


# ================================================================== checkpoints, switches, home zones
func checkpoint(pos: Vector3) -> void:
	var g := Node3D.new()
	g.add_child(doodle(_cyl(0.035, 0.04, 1.1, 8), "c99a6a", Vector3(0, 0.55, 0), 0.015))
	var flag := doodle(_cyl(0.0, 0.26, 0.04, 3), "f2788e", Vector3(0.17, 0.95, 0), 0.015)
	flag.rotation = Vector3(PI / 2.0, 0, PI / 2.0)
	flag.scale = Vector3(1.0, 1.0, 1.3)
	g.add_child(flag)
	place(g, pos + Vector3(0.9, 0, 0), 1.0, 0.6, 0.0)  # the flag stands beside the spawn spot
	checkpoints.append({"pos": pos, "node": g, "flag": flag, "reached": checkpoints.is_empty()})
	if checkpoints.size() == 1:
		_paint(flag, true)


## A floor button; a Stone Mochi ground pound on it raises `bridge` up to `raised_y`.
func switch(pos: Vector3, bridge: Node3D, raised_y: float) -> void:
	var plate := colored(_cyl(0.42, 0.48, 0.12, 20), "e5485e", pos + Vector3(0, 0.06, 0), 0.025, 0.1)
	add_child(plate)
	switches.append({"pos": pos, "plate": plate, "bridge": bridge, "raised_y": raised_y, "on": false})


func bridge(x: float, z: float, length: float, top: float) -> StaticBody3D:
	return island(x, z, 1.6, length, top, "e6c79c", 0.35)


func zone(id: String, pos: Vector3, radius: float, prompt: String) -> void:
	zones.append({"id": id, "pos": pos, "radius": radius, "prompt": prompt})


func zone_at(pos: Vector3) -> Dictionary:
	for z in zones:
		if Vector2(pos.x - z.pos.x, pos.z - z.pos.z).length() < z.radius:
			return z
	return {}


# ================================================================== Home Page
func _build_home() -> void:
	island(0, 0, 13, 12, 0.0, "f6e7d3")
	checkpoint(Vector3(0, 0, 3.0))
	checkpoints[0].node.visible = false
	# the big sketchbook you jump into
	var book := Node3D.new()
	for sx in [-1.0, 1.0]:
		var page := doodle(_box(1.5, 0.1, 2.1), "fffaf0", Vector3(sx * 0.78, 0.55, 0), 0.025, true)
		page.rotation.z = -sx * 0.18
		book.add_child(page)
	book.add_child(doodle(_box(3.3, 0.14, 2.3), "c86b6b", Vector3(0, 0.38, 0), 0.03, true))
	book.add_child(doodle(_box(0.08, 0.6, 0.02), "f2c14e", Vector3(0.1, 0.25, 1.15), 0.01, true))
	place(book, Vector3(0, 0, -3.2), 1.0, 3.5, 0.0, _box_shape(Vector3(3.3, 0.7, 2.3)), Vector3(0, 0.35, 0))
	zone("book", Vector3(0, 0, -1.6), 1.4, "E  Open the book")
	# a dressing mirror for the creator
	var mirror := Node3D.new()
	var frame := doodle(TorusMesh.new(), "f5c35b", Vector3(0, 1.0, 0), 0.02)
	frame.rotation.x = PI / 2.0
	frame.scale = Vector3(0.55, 0.3, 0.75)
	mirror.add_child(frame)
	var glass := colored(_cyl(0.5, 0.5, 0.03, 24), "cfe6f7", Vector3(0, 1.0, 0), 0.0, 0.3)
	glass.rotation.x = PI / 2.0
	glass.scale = Vector3(0.95, 1.0, 1.3)
	mirror.add_child(glass)
	mirror.add_child(doodle(_cyl(0.05, 0.08, 0.5, 8), "c99a6a", Vector3(0, 0.25, 0), 0.015))
	place(mirror, Vector3(-4.2, 0, -0.5), 1.0, 1.0, 0.5, _cyl_shape(0.35, 1.6), Vector3(0, 0.8, 0))
	zone("mirror", Vector3(-3.4, 0, 0.2), 1.2, "E  Change my look")
	# sticker board
	var board := Node3D.new()
	board.add_child(doodle(_box(1.8, 1.2, 0.1), "d9b38c", Vector3(0, 1.0, 0), 0.025, true))
	board.add_child(doodle(_cyl(0.05, 0.05, 0.6, 6), "c99a6a", Vector3(-0.6, 0.3, 0), 0.015))
	board.add_child(doodle(_cyl(0.05, 0.05, 0.6, 6), "c99a6a", Vector3(0.6, 0.3, 0), 0.015))
	var label := Label3D.new()
	label.name = "StickerLabel"
	label.font = _ui_font()
	label.font_size = 64
	label.pixel_size = 0.004
	label.modulate = Color("1f1d24")
	label.outline_size = 0
	label.position = Vector3(0, 1.0, 0.07)
	board.add_child(label)
	place(board, Vector3(4.2, 0, -0.8), 1.0, 1.4, -0.4, _box_shape(Vector3(1.8, 1.6, 0.3)), Vector3(0, 0.8, 0))
	for p in [Vector3(-5, 0, -4.5), Vector3(5.2, 0, -4.4), Vector3(-5.3, 0, 4.2), Vector3(5.4, 0, 4.0)]:
		_tree(p, 1.1)
	_scatter(flower, Vector3(-2.5, 0, 3.5), 1.6, 14)
	_scatter(flower, Vector3(3, 0, 3.8), 1.4, 12)
	_paint_all(true)  # the home page is always in colour


func set_sticker_count(got: int, total: int) -> void:
	var label: Label3D = find_child("StickerLabel", true, false)
	if label:
		label.text = "Stickers\n%d / %d" % [got, total]


func _ui_font() -> SystemFont:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["Segoe Print", "Comic Sans MS", "Gaegu"])
	return _font


# ================================================================== Meadow 1
## A path of islands running away from the camera (-z): hop gaps, a glide gap (Puffy), a switch bridge
## (Stone), a double-jump ledge and the Paint Seal at the end. 8 drops, 5 stickers.
func _build_meadow() -> void:
	# The open Meadow: one big page to roam, with Bloom Stars to find all over it. Each star is won a
	# different way (a climb, a glide, a quest, a race, a secret...). The old Meadow 1 run is the
	# "Ink Trail" leaving from the north edge.
	var ground := island(0, 0, 64, 60, 0.0)
	_paint(ground.get_child(1), true)  # the grass is already pale green; the doodles on it are what need colour
	checkpoint(Vector3(0, 0, 22))
	_tree(Vector3(-3, 0, 25), 1.1)
	_tree(Vector3(4.5, 0, 26), 1.0)
	_scatter(flower, Vector3(0, 0, 18), 6.0, 30)
	_scatter(flower, Vector3(-20, 0, 18), 6.0, 24)
	_scatter(flower, Vector3(18, 0, -22), 5.0, 18)
	for p in [[-28, 26], [-24, -2], [-27, -24], [27, 26], [28, 2], [10, 24], [-10, 26], [12, -26], [-6, -27], [24, -14]]:
		_tree(Vector3(p[0], 0, p[1]), rng.randf_range(0.9, 1.3))
	for p in [[-12, 4], [6, -8], [-26, 10], [20, 22]]:
		_scatter(rock, Vector3(p[0], 0, p[1]), 1.2, 3, 0.7, 1.2)

	# --- Pip, a sprout bean doodle who lost her bow (hidden in the meadow's far corner)
	friend("pip", Vector3(3.5, 0, 17.5), "c3e2a0", "Pip", {
		"ask": "Oh no, my bow blew away in the wind! It's a pink one... maybe by the far trees?",
		"thanks": "My bow! You found it! Here, this Bloom Star is for you!",
		"done": "I'll never take my bow off again. Thank you!"}, ["bow"])
	item("bow", Vector3(-28.5, 0, -27.5), "ff9ab5")

	# --- Tufts, a cloud-puff doodle missing three fluff-puffs
	friend("tufts", Vector3(-9, 0, 15), "ffffff", "Tufts", {
		"ask": "My three little fluff-puffs wandered off! One likes high places, one likes flowers, one hides by the trail.",
		"thanks": "All three! Puff puff, hooray! Take this Bloom Star!",
		"done": "My puffs are all snuggled up. Thank you!"}, ["puff1", "puff2", "puff3"])
	item("puff1", Vector3(16.5, 3.0, -9.5), "ffffff")       # high: the hill summit
	item("puff2", Vector3(19, 0, -24), "ffffff")            # flowers by the east meadow
	item("puff3", Vector3(-4, 0, -28.5), "ffffff")          # by the Ink Trail gate

	# --- Scribble the pencil stub: a hoop race
	friend("scribble", Vector3(9, 0, 8), "ffd86b", "Scribble", {
		"ask": "Race through my six ink hoops before I finish my doodle! Ready... GO!",
		"thanks": "Whoa, speedy mochi! That Bloom Star is yours!",
		"done": "Want to watch me doodle? ...no? Okay!",
		"fail": "Hee hee, I finished first! Talk to me to try again."}, [])
	for h in [[9, 2], [15, 5], [19, 12], [12, 15], [4, 11], [1, 4]]:
		hoop(Vector3(h[0], 0, h[1]))
	bloom("b_race", Vector3(9, 0, 6.2), true)
	race.friend = "scribble"
	race.star = "b_race"
	friends.scribble.star = "b_race"

	# --- The giant tree: branch platforms spiral up the trunk to a star in the crown
	var tc := Vector3(-16, 0, 2)
	var trunk := Node3D.new()
	trunk.add_child(doodle(_cyl(0.9, 1.3, 7.5, 12), "d9b38c", Vector3(0, 3.75, 0), 0.05))
	for b in [[0.0, 8.2, 0.0, 2.8], [1.8, 7.6, 0.8, 2.0], [-1.6, 7.7, -0.9, 2.1], [0.3, 9.4, -0.4, 1.8]]:
		trunk.add_child(doodle(_sphere(b[3]), "a8d8a0", Vector3(b[0], b[1], b[2]), 0.05))
	place(trunk, tc, 1.0, 4.0, 0.0, _cyl_shape(1.2, 7.5), Vector3(0, 3.75, 0))
	for k in 6:
		var a := k * 1.15
		island(tc.x + cos(a) * 2.2, tc.z + sin(a) * 2.2, 1.7, 1.7, 0.9 + k * 0.95, "c3e2a0", 0.3)
	island(tc.x + cos(6.9) * 2.0, tc.z + sin(6.9) * 2.0, 2.4, 2.4, 6.6, "c3e2a0", 0.3)
	bloom("b_tree", Vector3(tc.x + cos(6.9) * 2.0, 6.6, tc.z + sin(6.9) * 2.0))
	bloom("b_peek", Vector3(-17.2, 0, 4.7))  # hiding in the hollow behind the trunk
	sticker("s1", Vector3(tc.x + cos(3.45) * 2.2, 0.9 + 3 * 0.95, tc.z + sin(3.45) * 2.2))

	# --- The Hill: grassy terraces to climb, a cloud doodle at the top and an islet to glide to
	var hc := Vector3(16, 0, -10)
	for k in 6:
		var s := 12.0 - 2.0 * k
		island(hc.x, hc.z, s, s, 0.5 * (k + 1), "a9dd8f", 0.5 * (k + 1))
	power_doodle("puffy", Vector3(hc.x - 0.4, 3.0, hc.z + 0.4))
	island(27, -10, 2.6, 2.6, 1.6, "f6e3b4", 0.4)
	bloom("b_glide", Vector3(27, 1.6, -10))
	checkpoint(Vector3(hc.x - 7.5, 0, hc.z))
	paint_drop("d9", Vector3(hc.x + 3.5, 1.5, hc.z + 3.5), "a8d8a0")

	# --- The Smudgie nest: an ink puddle; clean every Smudgie and a star blooms from it
	var nc := Vector3(-14, 0, -16)
	var puddle := colored(_cyl(4.0, 4.0, 0.04, 28), "4a4552", nc + Vector3(0, 0.02, 0), 0.0, 0.0)
	puddle.scale = Vector3(1.0, 1.0, 0.75)
	add_child(puddle)
	for i in 4:
		var a := i / 4.0 * TAU
		smudgie("n%d" % i, nc + Vector3(cos(a) * 1.8, 0, sin(a) * 1.4), 2.6)
		nest.append("n%d" % i)
	bloom("b_nest", nc + Vector3(0, 0, 0), true)
	paint_drop("d10", Vector3(-20, 0, -12), "8fd0f5")

	# --- The cage: a pebble doodle, a switch to stomp, and a star locked in a cage that sinks
	power_doodle("stone", Vector3(8, 0, -15))
	var cage := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = _box_shape(Vector3(1.8, 2.0, 1.8))
	cs.position = Vector3(0, 1.0, 0)
	cage.add_child(cs)
	for bx in [-0.8, 0.0, 0.8]:
		for bz in [-0.8, 0.8]:
			cage.add_child(doodle(_cyl(0.06, 0.06, 2.0, 6), "c99a6a", Vector3(bx, 1.0, bz), 0.02))
			cage.add_child(doodle(_cyl(0.06, 0.06, 2.0, 6), "c99a6a", Vector3(bz, 1.0, bx), 0.02))
	cage.add_child(doodle(_box(1.9, 0.15, 1.9), "e6c79c", Vector3(0, 2.05, 0), 0.02, true))
	cage.position = Vector3(4, 0, -20)
	add_child(cage)
	bloom("b_cage", Vector3(4, 0, -20))
	switch(Vector3(6.8, 0, -18), cage, -2.3)
	paint_drop("d11", Vector3(1, 0, -16), "e88f8f")

	# --- The bouncy mushroom: boing up to a cloud with a star on it
	var mush := Node3D.new()
	mush.add_child(doodle(_cyl(0.35, 0.45, 0.8, 10), "fff1dc", Vector3(0, 0.4, 0), 0.03))
	var cap := doodle(_sphere(1.1, 16, 8, true), "f2788e", Vector3(0, 0.7, 0), 0.04)
	cap.scale = Vector3(1.0, 0.45, 1.0)
	mush.add_child(cap)
	place(mush, Vector3(-4, 0, -5), 1.0, 1.2, 0.0, _cyl_shape(1.0, 1.2), Vector3(0, 0.6, 0))
	bouncers.append({"pos": Vector3(-4, 1.2, -5), "r": 1.05})
	var sky := island(-4, -9.5, 3.0, 3.0, 4.6, "ffffff", 0.6)
	sky.add_child(doodle(_sphere(1.0), "ffffff", Vector3(-1.2, -0.1, 0.6), 0.03))
	sky.add_child(doodle(_sphere(0.9), "ffffff", Vector3(1.3, -0.15, -0.4), 0.03))
	bloom("b_sky", Vector3(-4, 4.6, -9.5))
	sticker("s2", Vector3(-27, 0, -12))

	# --- The village corner: two houses, crates to climb, a star on a rooftop
	place(house(), Vector3(22, 0, 17), 1.2, 2.4, -0.3, _box_shape(Vector3(1.6, 2.0, 1.3)), Vector3(0, 1.0, 0))
	place(house(), Vector3(26.5, 0, 14), 1.2, 2.4, 0.4, _box_shape(Vector3(1.6, 2.0, 1.3)), Vector3(0, 1.0, 0))
	for c in [[20.2, 18.8, 0.7], [19.4, 20.0, 1.4]]:
		var crate := island(c[0], c[1], 1.1, 1.1, c[2], "e6c79c", 0.7)
		crate.position.y = c[2] - 0.35
	bloom("b_roof", Vector3(22, 2.4, 17))
	sticker("s3", Vector3(28.5, 0, 16))  # behind the second house
	paint_drop("d12", Vector3(24, 0, 20.5), "f5c35b")

	# --- more paint drops around the meadow; eat them all and the last star blooms in the middle
	paint_drop("d13", Vector3(-8, 0, 9), "ff9ab5")
	paint_drop("d14", Vector3(-26, 0, 20), "b9a2ee")
	bloom("b_drops", Vector3(0, 0, 10), true)

	_meadow_trail(-34.0)
	sticker("s4", Vector3(-28.5, 0, 26.5))
	_dress_meadow()


## The Ink Trail: the original Meadow 1 run, leaving the north edge of the meadow at z = -30.
func _meadow_trail(o: float) -> void:
	# A: the gate
	island(0, o, 8, 8, 0)
	checkpoint(Vector3(-2.5, 0, o + 2.0))
	place(pencil(), Vector3(-2.2, 0, o - 1.4), 1.0, 0.0, -0.5, _box_shape(Vector3(4.6, 0.6, 0.6)), Vector3(0, 0.3, 0))
	paint_drop("d1", Vector3(1.6, 0, o - 1.8), "ffd86b")
	# B, C: little hops
	island(0, o - 7.5, 4, 4, 0)
	paint_drop("d2", Vector3(0, 0, o - 7.5), "ff9ab5")
	island(2.2, o - 12, 3, 3, 0.45)
	paint_drop("d3", Vector3(2.2, 0.45, o - 12), "b9a2ee")
	# D: Smudgies and the cloud
	island(0, o - 18.5, 8, 6, 0)
	checkpoint(Vector3(-2.5, 0, o - 16.3))
	power_doodle("puffy", Vector3(2.6, 0, o - 19.6))
	smudgie("m1", Vector3(-1.5, 0, o - 19.5), 1.6)
	smudgie("m2", Vector3(1.0, 0, o - 17.5), 1.4)
	paint_drop("d4", Vector3(-3.0, 0, o - 20.6), "8fd0f5")
	paint_drop("d5", Vector3(3.0, 0, o - 16.4), "a8d8a0")
	_scatter(mushroom, Vector3(-3.0, 0, o - 20.6), 0.9, 4)
	_tree(Vector3(3.4, 0, o - 21.0), 0.9)
	# glide gap -> E: the pebble, the switch and the bridge
	island(0, o - 31.5, 7, 8, -0.6)
	checkpoint(Vector3(0, -0.6, o - 28.6))
	power_doodle("stone", Vector3(-2.3, -0.6, o - 31.0))
	paint_drop("d6", Vector3(0.6, -0.6, o - 32.2), "e88f8f")
	_scatter(rock, Vector3(2.4, -0.6, o - 29.5), 0.8, 3, 0.6, 1.0)
	island(7.4, o - 31.5, 2, 2, -0.2, "f6e3b4")  # a side islet only a glide reaches
	sticker("s5", Vector3(7.4, -0.2, o - 31.5))
	var br := bridge(0, o - 38.0, 5.0, -0.6)
	br.position.y -= 4.0  # starts sunk below; the switch raises it
	switch(Vector3(2.0, -0.6, o - 34.6), br, br.position.y + 4.0)
	# F: more Smudgies
	island(0, o - 44, 7, 7, -0.6)
	checkpoint(Vector3(0, -0.6, o - 41.4))
	smudgie("m3", Vector3(-1.8, -0.6, o - 44.0), 1.6)
	smudgie("m4", Vector3(1.8, -0.6, o - 45.0), 1.6)
	smudgie("m5", Vector3(0.2, -0.6, o - 42.6), 1.2)
	paint_drop("d7", Vector3(-2.5, -0.6, o - 42.2), "f5c35b")
	paint_drop("d8", Vector3(2.6, -0.6, o - 46.4), "9fd0b4")
	place(house(), Vector3(2.9, -0.6, o - 42.0), 0.8, 2.0, -0.6, _box_shape(Vector3(1.6, 1.4, 1.3)), Vector3(0, 0.7, 0))
	# G: the ledge at the end, with its Bloom Star
	island(0, o - 50.5, 4, 4, 0.3)
	bloom("b_trail", Vector3(0, 0.3, o - 51.2))
	_tree(Vector3(-1.4, 0.3, o - 52.0), 0.8)


# ================================================================== Bloom Stars, friends, quests
## A Bloom Star: the page's main prize. `hidden` ones appear once their task is done (`reveal_bloom`).
func bloom(id: String, pos: Vector3, hidden := false) -> void:
	var node := Node3D.new()
	node.add_child(colored(_star_mesh(0.5, 0.22, 0.12), "ffd86b", Vector3.ZERO, 0.03, 0.35))
	node.add_child(colored(_sphere(0.13, 10, 6), "fff6c8", Vector3(0, 0, 0.1), 0.0, 0.0))
	node.position = pos + Vector3(0, 0.9, 0)
	if _beam_mat == null:  # a soft beam of light, so stars can be spotted from across the page
		_beam_mat = StandardMaterial3D.new()
		_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_beam_mat.albedo_color = Color(1.0, 0.86, 0.42, 0.28)
		_beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var beam := MeshInstance3D.new()
	beam.mesh = _cyl(0.05, 0.22, 7.0, 10)
	beam.material_override = _beam_mat
	beam.position = Vector3(0, 3.6, 0)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(beam)
	var e := _edible("bloom", id, node)
	if hidden:
		node.visible = false
		e.shadow.visible = false


## A burst of ink confetti (little coloured stars) that pops out and falls.
func confetti(at: Vector3) -> void:
	var colors := ["ff9ab5", "ffd86b", "b9a2ee", "8fd0f5", "a8d8a0", "ffb38a"]
	for k in 26:
		var bit := colored(_star_mesh(0.11, 0.05, 0.02), colors[k % colors.size()], at, 0.008, 0.2)
		add_child(bit)
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.6, 1.6), rng.randf_range(-1, 1)).normalized()
		var peak := at + dir * rng.randf_range(1.2, 2.4)
		var tw := bit.create_tween().set_parallel()
		tw.tween_property(bit, "position", peak, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(bit, "rotation", Vector3(rng.randf() * TAU, rng.randf() * TAU, 0), 1.3)
		tw.chain().tween_property(bit, "position", peak - Vector3(0, 2.2, 0), 0.9).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(bit, "scale", Vector3.ONE * 0.01, 0.9)
		tw.chain().tween_callback(bit.queue_free)


func reveal_bloom(id: String, instant := false) -> void:
	for e in edibles:
		if e.id == id and e.kind == "bloom" and not e.got and not e.node.visible:
			e.node.visible = true
			e.shadow.visible = true
			if not instant:
				e.node.scale = Vector3.ONE * 0.01
				create_tween().tween_property(e.node, "scale", Vector3.ONE, 0.6).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
				_splash(e.node.global_position, Color("ffd86b"))
				bloom_revealed.emit(id)


func bloom_shown(id: String) -> bool:
	for e in edibles:
		if e.id == id:
			return e.got or e.node.visible
	return false


func bloom_ids() -> Array:
	return edibles.filter(func(e): return e.kind == "bloom").map(func(e): return e.id)


## Something a friend lost. Eating it keeps it safe in the mochi's cheeks until it's handed back.
func item(id: String, pos: Vector3, color: String) -> void:
	var node := Node3D.new()
	if id == "bow":
		for sx in [-1.0, 1.0]:
			var loop := colored(_sphere(0.17, 10, 6), color, Vector3(sx * 0.17, 0, 0), 0.02, 0.15)
			loop.scale = Vector3(1.0, 0.75, 0.45)
			node.add_child(loop)
		node.add_child(colored(_sphere(0.08, 8, 5), color, Vector3.ZERO, 0.02, 0.15))
	elif id.begins_with("letter"):  # an envelope with a heart seal
		node.add_child(colored(_box(0.42, 0.28, 0.05), color, Vector3.ZERO, 0.02, 0.1))
		node.add_child(colored(_sphere(0.06, 8, 5), "f2788e", Vector3(0, 0, 0.04), 0.0, 0.0))
	elif id == "spark":  # a little glowing light
		node.add_child(colored(_sphere(0.16, 12, 8), color, Vector3.ZERO, 0.02, 0.6))
		node.add_child(colored(_star_mesh(0.3, 0.1, 0.03), "fff6c8", Vector3.ZERO, 0.0, 0.5))
	else:  # a fluff-puff with two dot eyes
		node.add_child(colored(_sphere(0.2, 12, 8), color, Vector3.ZERO, 0.02, 0.2))
		for sx in [-1.0, 1.0]:
			node.add_child(colored(_sphere(0.03, 6, 4), "1f1d24", Vector3(sx * 0.07, 0.04, 0.18), 0.0, 0.0))
	node.position = pos + Vector3(0, 0.55, 0)
	_edible("item", id, node)


func has_item(id: String) -> bool:
	for e in edibles:
		if e.id == id and e.kind == "item":
			return e.got
	return false


## A doodle friend who lives on the page. Talk (E) for their request; bring back `wants` for a Bloom Star.
func friend(id: String, pos: Vector3, color: String, title: String, lines: Dictionary, wants: Array, look := "") -> void:
	var g := Node3D.new()
	match look if look != "" else {"pip": "sprout", "tufts": "puff"}.get(id, "pencil"):
		"sprout":  # a sprout bean
			var body := doodle(_sphere(0.42, 14, 10), color, Vector3(0, 0.45, 0), 0.03)
			body.scale = Vector3(0.85, 1.1, 0.85)
			g.add_child(body)
			g.add_child(doodle(_cyl(0.03, 0.04, 0.3, 6), "6fae8c", Vector3(0, 1.05, 0), 0.015))
			var leaf := doodle(_sphere(0.16, 10, 6), "6fae8c", Vector3(0.12, 1.2, 0), 0.015)
			leaf.scale = Vector3(1.0, 0.35, 0.6)
			g.add_child(leaf)
		"puff":  # a cloud puff on little ink legs
			for b in [[0.36, 0.0, 0.7, 0.0], [0.28, 0.32, 0.72, 0.05], [0.28, -0.32, 0.72, -0.05], [0.26, 0.0, 0.98, 0.0]]:
				g.add_child(doodle(_sphere(b[0]), color, Vector3(b[1], b[2], b[3]), 0.03))
			for lx in [-0.18, 0.18]:
				g.add_child(colored(_cyl(0.05, 0.05, 0.4, 6), "1f1d24", Vector3(lx, 0.2, 0), 0.0, 0.0))
		"lamp":  # a lamp post with an empty glass head
			g.add_child(doodle(_cyl(0.08, 0.12, 1.6, 8), color, Vector3(0, 0.8, 0), 0.02))
			g.add_child(doodle(_cyl(0.22, 0.16, 0.36, 6), "e3eef8", Vector3(0, 1.75, 0), 0.02))
			g.add_child(doodle(_cyl(0.0, 0.28, 0.2, 6), color, Vector3(0, 2.03, 0), 0.02))
			g.add_child(doodle(_box(0.5, 0.42, 0.3), color, Vector3(0, 0.62, 0.0), 0.02, true))  # its face plate
		"mail":  # a round-topped mailbox on a post
			g.add_child(doodle(_cyl(0.06, 0.06, 0.5, 6), "c99a6a", Vector3(0, 0.25, 0), 0.02))
			g.add_child(doodle(_box(0.62, 0.5, 0.5), color, Vector3(0, 0.72, 0), 0.025, true))
			var flag := doodle(_box(0.05, 0.3, 0.12), "f2788e", Vector3(0.34, 0.85, -0.1), 0.01, true)
			g.add_child(flag)
		"plane":  # a paper plane resting nose-down
			var wing := doodle(_cyl(0.0, 0.55, 0.9, 3), color, Vector3(0, 0.55, 0), 0.025)
			wing.scale = Vector3(1.0, 1.0, 0.35)
			wing.rotation.x = -0.25
			g.add_child(wing)
		_:  # a pencil stub standing on end
			g.add_child(doodle(_cyl(0.3, 0.3, 0.9, 6), color, Vector3(0, 0.55, 0), 0.03))
			g.add_child(doodle(_cyl(0.3, 0.3, 0.2, 10), "f2788e", Vector3(0, 1.1, 0), 0.02))
			g.add_child(doodle(_cyl(0.0, 0.3, 0.35, 6), "f3d2a6", Vector3(0, -0.07, 0), 0.02))
	for sx in [-1.0, 1.0]:  # the same dot eyes for everyone
		g.add_child(colored(_sphere(0.05, 8, 5), "1f1d24", Vector3(sx * 0.12, 0.62, 0.33), 0.0, 0.0))
	place(g, pos, 1.0, 0.9, 0.0, _cyl_shape(0.4, 1.2), Vector3(0, 0.6, 0))
	_paint_tree(g)  # friends are always in colour, so they stand out on the ink page
	var mark := Label3D.new()  # a bouncing "!" while they still need help
	mark.text = "!"
	mark.font = _ui_font()
	mark.font_size = 96
	mark.pixel_size = 0.006
	mark.modulate = Color("e3789a")
	mark.outline_modulate = Color.WHITE
	mark.outline_size = 18
	mark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mark.position = pos + Vector3(0, 1.9, 0)
	add_child(mark)
	friends[id] = {"node": g, "home": pos, "lines": lines, "wants": wants, "mark": mark, "said": "",
		"star": "b_" + id, "title": title}
	zone("friend", pos, 2.0, "E  Talk to %s" % title)
	zones[-1]["friend"] = id
	if not wants.is_empty():
		bloom("b_" + id, pos + Vector3(1.3, 0, 0.6), true)


func say(id: String, text: String, seconds := 4.0) -> void:
	var f: Dictionary = friends[id]
	f.said = text
	friend_said.emit(f.title, text, seconds)


func _paint_tree(node: Node) -> void:
	for c in node.get_children():
		if c is GeometryInstance3D and c.has_meta("paint"):
			_paint(c, true)


## Talking to a friend: thank them for what you bring, or hear what they need.
func talk(id: String) -> void:
	var f: Dictionary = friends[id]
	if bloom_shown(f.star):
		say(id, f.lines.done)
	elif id == race.friend:
		say(id, f.lines.ask, 3.0)
		_start_race()  # (the page's racing friend)
	elif f.wants.all(func(w): return has_item(w)):
		say(id, f.lines.thanks)
		reveal_bloom(f.star)
	else:
		var got: int = f.wants.filter(func(w): return has_item(w)).size()
		say(id, f.lines.ask + ("" if got == 0 else "  (%d / %d found)" % [got, f.wants.size()]), 5.0)


func hoop(pos: Vector3) -> void:
	var ring := colored(TorusMesh.new(), "1f1d24", pos + Vector3(0, 1.0, 0), 0.0, 0.1)
	ring.mesh.inner_radius = 0.75
	ring.mesh.outer_radius = 0.9
	ring.rotation.x = PI / 2.0
	ring.visible = false
	add_child(ring)
	race.hoops.append(ring)


func _start_race() -> void:
	race.on = true
	race.next = 0
	race.t = race.time
	for h in race.hoops:
		h.visible = true
		h.scale = Vector3.ONE
	race_update.emit("Hoop 0 / %d" % race.hoops.size())


func _tick_race(delta: float, player_pos: Vector3) -> void:
	if not race.on:
		return
	race.t -= delta
	var h: Node3D = race.hoops[race.next]
	h.rotation.z += delta * 2.0
	if player_pos.distance_to(h.global_position - Vector3(0, 0.6, 0)) < 1.4:
		h.visible = false
		_splash(h.global_position, Color("ffd86b"))
		race.next += 1
		race_update.emit("Hoop %d / %d" % [race.next, race.hoops.size()])
		if race.next == race.hoops.size():
			race.on = false
			say(race.friend, friends[race.friend].lines.thanks)
			reveal_bloom(race.star)
	elif race.t <= 0.0:
		race.on = false
		for r in race.hoops:
			r.visible = false
		say(race.friend, friends[race.friend].lines.fail)
		race_update.emit("Time's up!")


## Sketch Mochi draws an ink plank from its feet along `dir`. It is solid at once, draws itself in, and is
## rubbed out after SKETCH_LIFE seconds; only two at a time (the oldest fades first).
func sketch_bridge(feet: Vector3, dir: Vector3) -> void:
	dir.y = 0.0
	dir = dir.normalized()
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = _box_shape(Vector3(1.3, 0.16, SKETCH_LENGTH))
	body.add_child(cs)
	var plank := colored(_box(1.3, 0.16, SKETCH_LENGTH), "fff1b8", Vector3.ZERO, 0.03, 0.1)
	body.add_child(plank)
	for k in 5:  # pencil hatching across the plank
		var hatch := colored(_box(1.0, 0.02, 0.05), "1f1d24", Vector3(0, 0.09, -SKETCH_LENGTH / 2.0 + 0.5 + k * (SKETCH_LENGTH - 1.0) / 4.0), 0.0, 0.0)
		hatch.rotation.y = 0.35
		body.add_child(hatch)
	body.position = feet + dir * (0.35 + SKETCH_LENGTH / 2.0) - Vector3(0, 0.08, 0)
	body.rotation.y = atan2(dir.x, dir.z)
	add_child(body)
	plank.scale = Vector3(1.0, 1.0, 0.05)  # only the picture draws in; the collider is whole from the start
	create_tween().tween_property(plank, "scale", Vector3.ONE, 0.22).set_trans(Tween.TRANS_SINE)
	sketches.append(body)
	if sketches.size() > 2:
		_rub_out(sketches.pop_front(), 0.0)
	_rub_out(body, SKETCH_LIFE)
	_splash(feet + dir * 1.0 + Vector3(0, 0.2, 0), Color("ffd86b"))


func _rub_out(body: Node3D, after: float) -> void:
	var tw := body.create_tween()
	tw.tween_interval(maxf(0.0, after - 1.2))
	for k in 4:  # blink before it's gone
		tw.tween_property(body, "visible", false, 0.15)
		tw.tween_property(body, "visible", true, 0.15)
	tw.tween_callback(func():
		sketches.erase(body)
		body.queue_free())


## Standing on a bouncy mushroom cap?
func bouncy_at(pos: Vector3) -> bool:
	for b in bouncers:
		if Vector2(pos.x - b.pos.x, pos.z - b.pos.z).length() < b.r and absf(pos.y - b.pos.y) < 0.3:
			return true
	return false


## Tasks finished by what the mochi does on the page (not by talking): nest cleared, every drop eaten.
func _check_tasks() -> void:
	if not nest.is_empty() and not bloom_shown("b_nest"):
		if smudgies.filter(func(m): return m.id in nest and not m.got).is_empty():
			reveal_bloom("b_nest")
	if drops_left() == 0 and not drops.is_empty() and not bloom_shown("b_drops"):
		reveal_bloom("b_drops")
	for id in reveals:  # editor pages: stars set to appear when every drop is eaten / every Smudgie cleaned
		if bloom_shown(id):
			continue
		if reveals[id] == "drops" and drops_left() == 0 or reveals[id] == "smudgies" and smudgies.all(func(m): return m.got):
			reveal_bloom(id)


# ================================================================== Chapter 2: the Village
## The Village: a town square in the south, a canal across the middle (fall in and you are redrawn), rooftops,
## a clock tower and a windmill hill in the north. Power: Sketch Mochi (draw ink bridges). 12 Bloom Stars,
## see docs/level_design.md for the table.
func _build_village() -> void:
	for c in clouds:  # lift the sky clouds clear of the clock tower and rooftops
		c.position.y += 5.0
	# ground: the south bank (town) and the north bank (rooftops, mill), with the canal between (z -10..2)
	for g in [island(0, 16, 64, 28, 0.0), island(0, -20, 64, 20, 0.0)]:
		g.get_child(1).set_meta("paint", Color("ece6d6"))  # cobbles: warmer than the Meadow grass
		_paint(g.get_child(1), true)
	var water := colored(_box(64, 0.1, 12), "8fd0f5", Vector3(0, -1.6, -4), 0.0, 0.15)
	add_child(water)
	for b in [[-12.0], [8.0]]:  # the two good bridges
		var br := island(b[0], -4, 3.2, 12.4, 0.0, "d9b38c", 0.35)
		_paint(br.get_child(1), true)
		for side in [-1.0, 1.0]:
			add_child(doodle(_box(0.12, 0.5, 12.4), "c99a6a", Vector3(b[0] + side * 1.5, 0.25, -4), 0.02, true))
	checkpoint(Vector3(0, 0, 24))

	# --- Town Square: fountain, Glim, Postie, Zip, the pencil pedestal and the first Sketch star
	var fountain := Node3D.new()
	fountain.add_child(doodle(_cyl(2.0, 2.1, 0.5, 20), "e3e6ef", Vector3(0, 0.25, 0), 0.04))
	fountain.add_child(colored(_cyl(1.75, 1.75, 0.06, 20), "8fd0f5", Vector3(0, 0.5, 0), 0.0, 0.1))
	fountain.add_child(doodle(_cyl(0.25, 0.35, 1.4, 10), "e3e6ef", Vector3(0, 1.0, 0), 0.03))
	fountain.add_child(doodle(_cyl(0.7, 0.5, 0.25, 14), "e3e6ef", Vector3(0, 1.75, 0), 0.03))
	place(fountain, Vector3(0, 0, 12), 1.0, 0.0, 0.0, _cyl_shape(2.0, 0.5), Vector3(0, 0.25, 0))
	bloom("b_drops", Vector3(0, 1.9, 12), true)  # every drop eaten: a star blooms out of the fountain
	power_doodle("sketch", Vector3(-3.5, 0, 6))
	bloom("b_sketch", Vector3(0, 0, -4))  # on the islet just across the water: the first bridge
	var islet := island(0, -4, 2.2, 2.2, 0.0, "f6e3b4", 0.5)
	_paint(islet.get_child(1), true)
	_signpost(Vector3(-2.6, 0, 4.2), "Draw a bridge!")
	friend("glim", Vector3(-6, 0, 19), "6b6672", "Glim", {
		"ask": "My spark rolled into the dark alley by the old walls, west of here. Without it I can't glow!",
		"thanks": "My spark! I'm glowing again! Here, a Bloom Star for you.",
		"done": "Glow, glow, glow!"}, ["spark"], "lamp")
	item("spark", Vector3(-29, 0, 25), "ffe07a")
	friend("postie", Vector3(6, 0, 19), "e5485e", "Postie", {
		"ask": "The wind blew three letters onto the rooftops! One by the market, one on a chimney, one up Rooftop Row.",
		"thanks": "All three letters! Special delivery: one Bloom Star!",
		"done": "Mail's on time today, thanks to you."}, ["letter1", "letter2", "letter3"], "mail")
	friend("zip", Vector3(12, 0, 23), "ffffff", "Zip", {
		"ask": "Zoom with me! Six hoops, over the bridge and back across the rooftops side. GO!",
		"thanks": "Wheee! You fly like paper! The Bloom Star's yours.",
		"done": "Wind's good today. Fancy a glide?",
		"fail": "Whoosh, I won! Talk to me to race again."}, [], "plane")
	race.friend = "zip"
	race.star = "b_zip"
	race.time = 32.0
	for h in [[6, 15], [8, 5], [8, -4], [10, -13], [2, -18], [-8, -12]]:
		hoop(Vector3(h[0], 0, h[1]))
	bloom("b_zip", Vector3(13.3, 0, 21.5), true)
	friends.zip.star = "b_zip"

	# --- the Broken Bridge: snapped in the middle; a star floats over the gap
	for z in [0.0, -8.0]:
		var stub := island(24, z, 3.2, 4.0, 0.0, "d9b38c", 0.35)
		_paint(stub.get_child(1), true)
	bloom("b_bridge", Vector3(24, 0.2, -4))
	_signpost(Vector3(21.5, 0, 3.6), "Old Bridge")

	# --- Market (south-west): stalls, a pebble doodle and a star in a cage
	for s in [[-24, 8, "f2788e"], [-19, 8, "8fd0f5"], [-24, 14, "ffd86b"], [-19, 14, "a8d8a0"]]:
		_stall(Vector3(s[0], 0, s[1]), s[2])
	power_doodle("stone", Vector3(-16, 0, 11))
	_cage_star("b_cage", Vector3(-27, 0, 11), Vector3(-27, 0, 15.5))
	item("letter1", Vector3(-19, 1.75, 8), "fffaf0")  # on top of a stall awning: hop up from the crate
	var crate := island(-16.6, 8, 1.0, 1.0, 0.9, "e6c79c", 0.9)
	_paint(crate.get_child(1), true)

	# --- the Dark Alley (far west): narrow, between the old walls; Glim's spark at the end
	for w in [[-28.0, 22.0], [-30.8, 22.0]]:
		var wall := island(w[0], w[1], 0.8, 10, 3.0, "b8b0c4", 3.0)
		_paint(wall.get_child(1), true)
	sticker("s1", Vector3(-29.4, 0, 17.6))

	# --- Garden maze (south-east): tall hedges; the star waits in the middle
	var mc := Vector3(21, 0, 17)
	for wseg in [
		[[-7, -7], [7, -7]], [[-7, 7], [-1, 7]], [[1, 7], [7, 7]], [[-7, -7], [-7, 7]], [[7, -7], [7, 7]],
		[[-4, -4], [4, -4]], [[-4, -4], [-4, 4]], [[-4, 4], [1, 4]], [[4, -1], [4, 4]],
		[[-1, -1], [-1, 1.5]], [[-1, -1], [2, -1]], [[-7, 1], [-5.5, 1]], [[5.5, -3], [7, -3]],
	]:
		_hedge(mc + Vector3(wseg[0][0], 0, wseg[0][1]), mc + Vector3(wseg[1][0], 0, wseg[1][1]))
	bloom("b_maze", mc + Vector3(1.5, 0, 1.5))
	sticker("s2", mc + Vector3(-5.5, 0, -5.5))  # a dead-end corner

	# --- Rooftop Row (north-west): rising roofs to the Clock Tower, and the laundry lines
	var roofs := [  # x, z, size x, size z, height, wall colour
		[-24, -14, 4, 4, 1.0, "f7d9b0"], [-24, -19.5, 4, 4, 2.0, "f2c6c6"], [-19, -24, 4, 4, 3.0, "d8e6f5"],
		[-13.5, -25, 4, 4, 4.0, "f5e3b0"], [-15, -16, 4, 4, 2.0, "e3d8f2"], [-5, -14.5, 4, 4, 2.0, "f7d9b0"],
	]
	for r in roofs:
		_building(Vector3(r[0], 0, r[1]), Vector2(r[2], r[3]), r[4], r[5])
	item("letter2", Vector3(-24, 1.0, -14), "fffaf0")
	# the Clock Tower and its ledge
	_building(Vector3(-8.5, 0, -25), Vector2(2.0, 2.0), 5.0, "e6c79c")
	_building(Vector3(-5, 0, -25), Vector2(3.4, 3.4), 6.0, "d9b38c")
	var face := colored(_cyl(1.2, 1.2, 0.1, 24), "fffaf0", Vector3(-5, 4.6, -23.25), 0.03, 0.1)
	face.rotation.x = PI / 2.0
	add_child(face)
	for hand in [[0.0, 0.8], [1.2, 0.55]]:
		var arm := colored(_box(0.08, hand[1], 0.04), "1f1d24", Vector3(-5, 4.6, -23.18), 0.0, 0.0)
		arm.rotation.z = hand[0]
		arm.position += Vector3(-sin(hand[0]), cos(hand[0]), 0) * hand[1] / 2.0
		add_child(arm)
	add_child(doodle(_cyl(0.04, 0.04, 1.6, 6), "c99a6a", Vector3(-6.4, 6.8, -26.4), 0.015))  # a flag on the roof
	add_child(colored(_cyl(0.0, 0.3, 0.04, 3), "f2788e", Vector3(-6.2, 7.4, -26.4), 0.01, 0.1))
	bloom("b_tower", Vector3(-5, 6.0, -24.2))
	sticker("s3", Vector3(-8.5, 5.0, -25))
	checkpoint(Vector3(-20, 0, -12))
	# laundry lines: thin walkable lines with washing hung under them
	_laundry(Vector3(-22, 2.0, -19.5), Vector3(-17, 2.0, -16))
	_laundry(Vector3(-13, 2.0, -16), Vector3(-7, 2.0, -14.5))
	bloom("b_laundry", Vector3(-5, 2.0, -14.5))

	# --- Chimney yard (north-centre): chimneys and a Smudgie nest
	var cy := Vector3(8, 0, -21)
	var soot := colored(_cyl(4.5, 4.5, 0.04, 28), "4a4552", cy + Vector3(0, 0.02, 0), 0.0, 0.0)
	soot.scale = Vector3(1.0, 1.0, 0.7)
	add_child(soot)
	for c in [[-3.5, -2.0, 1.6], [3.8, -1.5, 2.2], [0.5, 2.6, 1.2], [-1, -3.8, 2.6]]:
		var ch := Node3D.new()
		ch.add_child(doodle(_box(0.9, c[2], 0.9), "c97a6a", Vector3(0, c[2] / 2.0, 0), 0.03, true))
		ch.add_child(doodle(_box(1.1, 0.2, 1.1), "a85f52", Vector3(0, c[2], 0), 0.02, true))
		place(ch, cy + Vector3(c[0], 0, c[1]), 1.0, 1.0, 0.0, _box_shape(Vector3(0.9, c[2], 0.9)), Vector3(0, c[2] / 2.0, 0))
	item("letter3", cy + Vector3(0.5, 1.3, 2.6), "fffaf0")  # on the short chimney
	for i in 5:
		var a := i / 5.0 * TAU
		smudgie("n%d" % i, cy + Vector3(cos(a) * 2.2, 0, sin(a) * 1.5), 2.6)
		nest.append("n%d" % i)
	bloom("b_nest", cy, true)

	# --- Windmill Hill (north-east): climb the terraces, then sketch across to the mill balcony
	var hc := Vector3(16, 0, -20)
	for k in 5:
		var s := 9.0 - 1.8 * k
		var t := island(hc.x, hc.z, s, s, 0.5 * (k + 1), "a9dd8f", 0.5 * (k + 1))
		_paint(t.get_child(1), true)
	var mc2 := Vector3(24.5, 0, -22)
	var mill := Node3D.new()
	mill.add_child(doodle(_cyl(1.0, 1.4, 6.0, 12), "f7d9b0", Vector3(0, 3.0, 0), 0.04))
	mill.add_child(doodle(_cyl(0.0, 1.5, 1.4, 12), "e88f8f", Vector3(0, 6.7, 0), 0.04))
	var blades := Node3D.new()
	blades.position = Vector3(0, 6.6, 1.3)  # high enough that the tips clear the balcony and the mochi
	for k in 4:
		var blade := doodle(_box(0.5, 2.8, 0.08), "fffaf0", Vector3.ZERO, 0.03, true)
		blade.rotation.z = k * PI / 2.0
		blade.position = Vector3(-sin(k * PI / 2.0), cos(k * PI / 2.0), 0) * 1.4
		blades.add_child(blade)
	mill.add_child(blades)
	spinners.append(blades)
	place(mill, mc2, 1.0, 2.5, 0.0, _cyl_shape(1.3, 6.0), Vector3(0, 3.0, 0))
	var balcony := island(mc2.x, mc2.z, 4.4, 4.4, 2.5, "c99a6a", 0.3)
	_paint(balcony.get_child(1), true)
	bloom("b_mill", mc2 + Vector3(0, 2.5, 1.7))
	checkpoint(Vector3(hc.x - 6, 0, hc.z + 6))
	sticker("s4", hc + Vector3(0, 2.5, 0))  # on the hill top

	# --- paint drops all over the village
	var drop_spots := [
		[-3, 0, 20, "ff9ab5"], [4, 0, 9, "ffd86b"], [-14, 0, 22, "8fd0f5"], [14, 0, 10, "b9a2ee"],
		[-22, 0, 4, "a8d8a0"], [28, 0, 6, "ffb38a"], [-12, 0, -12, "f5c35b"], [2, 0, -13, "e88f8f"],
		[18, 1.5, -20, "a8d8a0"], [-24, 2.0, -19.5, "9fd0b4"], [26, 0, -14, "8fd0f5"], [-29, 0, 21, "ff9ab5"],
	]
	for i in drop_spots.size():
		var d: Array = drop_spots[i]
		paint_drop("d%d" % (i + 1), Vector3(d[0], d[1], d[2]), d[3])
	sticker("s5", Vector3(30, 0, -28))  # far north-east corner, behind the mill

	# --- dressing: paths, signs, houses along the streets, lamp posts, flower boxes, hedges at the edges
	_keep = [
		[0, 12, 3.5], [-3.5, 6, 1.5], [-21.5, 11, 6], [-29, 22, 3.5], [21, 17, 8.5], [-16, -20, 11], [-5, -25, 3],
		[8, -21, 5.5], [16, -20, 6], [24.5, -22, 3.5], [0, -4, 7], [24, -4, 7], [-12, -4, 7], [8, -4, 7],
	]
	var start := Vector3(0, 0, 23)
	_stone_path([start, Vector3(0, 0, 15.5)])
	_stone_path([Vector3(-2.5, 0, 10), Vector3(-10, 0, 6), Vector3(-12, 0, 2.5)])          # west bridge
	_stone_path([Vector3(2.5, 0, 10), Vector3(8, 0, 6), Vector3(8, 0, 2.5)])                # east bridge
	_stone_path([Vector3(-3, 0, 14), Vector3(-12, 0, 13), Vector3(-16, 0, 12)])             # market
	_stone_path([Vector3(3, 0, 14), Vector3(10, 0, 15), Vector3(13, 0, 17)])                # garden
	_stone_path([Vector3(-12, 0, -10.5), Vector3(-16, 0, -12), Vector3(-21, 0, -12)])       # rooftop row
	_stone_path([Vector3(8, 0, -10.5), Vector3(9, 0, -15)])                                 # chimney yard
	_stone_path([Vector3(9, 0, -15), Vector3(12, 0, -14), Vector3(13, 0, -16)])             # windmill hill
	for s in [[Vector3(-4, 0, 9.5), "Market  ·  West Bridge"], [Vector3(4, 0, 9.5), "Garden  ·  East Bridge"],
			[Vector3(-14, 0, -11), "Rooftop Row"], [Vector3(11, 0, -12), "Windmill Hill"]]:
		_signpost(s[0], s[1])
	for h in [[-12, 26, 0.0], [-17, 25, 0.3], [-22, 24.5, -0.2], [10, 27, 0.2], [17, 27, -0.1], [24, 27.5, 0.3],
			[-10, 18, 0.4], [12, 6.5, -0.4], [30, 5, 0.2], [-27, 2.5, 0.1], [-4, 27.5, 0.0], [4, 27.5, 0.1]]:
		place(house(), Vector3(h[0], 0, h[1]), 1.2, 2.4, h[2], _box_shape(Vector3(1.6, 2.0, 1.3)), Vector3(0, 1.0, 0))
		_keep.append([h[0], h[1], 2.2])
	for p in [[-2.5, 17], [2.5, 17], [-9, 8], [9, 9], [-10, -11], [6, -11], [-5.5, 3.5], [5.5, 3.5]]:
		_lamp_post(Vector3(p[0], 0, p[1]))
	for x in range(-30, 31, 3):
		if rng.randf() < 0.7:
			_bush(Vector3(x + rng.randf_range(-0.5, 0.5), 0, 29.0))
		if rng.randf() < 0.6 and absf(x + 5) > 4.0:
			_bush(Vector3(x + rng.randf_range(-0.5, 0.5), 0, -29.0))
	_sprinkle(func(p): _tree(p, rng.randf_range(0.9, 1.2)), 10, 2.0)
	_sprinkle(func(p): _scatter(flower, p, 1.2, 8, 1.0, 1.5), 8, 1.6)
	_sprinkle(func(p): _bush(p), 10, 1.4)
	for k in 6:
		_butterfly(Vector3(rng.randf_range(-24, 24), 0, rng.randf_range(4, 26)))


## A simple flat-roofed house block you can stand on. Walls are paper; a coloured roof trim, windows, a door.
func _building(pos: Vector3, size: Vector2, h: float, wall: String) -> void:
	var b := island(pos.x, pos.z, size.x, size.y, h, wall, h)
	_paint(b.get_child(1), true)
	add_child(colored(_box(size.x + 0.2, 0.12, size.y + 0.2), "c86b6b", pos + Vector3(0, h + 0.03, 0), 0.02, 0.1))
	var floors := int(h)
	for f in floors:
		for wx in ([-size.x / 4.0, size.x / 4.0] if size.x > 2.5 else [0.0]):
			add_child(colored(_box(0.55, 0.5, 0.06), "8fb4d9", pos + Vector3(wx, f + 0.55, size.y / 2.0 + 0.02), 0.015, 0.2))
	if h >= 2.0:
		add_child(colored(_box(0.7, 1.0, 0.06), "a8755a", pos + Vector3(0, 0.5, size.y / 2.0 + 0.03), 0.015, 0.1))


## A walkable washing line between two roofs: a thin plank-line, with clothes hanging below it.
func _laundry(a: Vector3, b: Vector3) -> void:
	var length := Vector2(b.x - a.x, b.z - a.z).length()
	var mid := (a + b) / 2.0
	var yaw := atan2(b.x - a.x, b.z - a.z)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = _box_shape(Vector3(0.5, 0.1, length))
	body.add_child(cs)
	body.add_child(colored(_box(0.12, 0.06, length), "fffaf0", Vector3(0, 0.0, 0), 0.015, 0.1))
	body.position = mid - Vector3(0, 0.05, 0)
	body.rotation.y = yaw
	add_child(body)
	var cloth := ["ff9ab5", "8fd0f5", "ffd86b", "b9a2ee", "a8d8a0"]
	var n := int(length / 1.1)
	for k in n:
		var t := (k + 0.5) / n
		var c := colored(_box(0.55, rng.randf_range(0.5, 0.8), 0.04), cloth[k % cloth.size()],
			Vector3(0, -0.4, -length / 2.0 + t * length), 0.012, 0.1)
		c.rotation.y = PI / 2.0
		body.add_child(c)


## A tall hedge wall from a to b (too tall to hop: 1.6 m).
func _hedge(a: Vector3, b: Vector3) -> void:
	var length := a.distance_to(b) + 0.8
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = _box_shape(Vector3(0.8, 1.6, length))
	body.add_child(cs)
	body.add_child(doodle(_box(0.8, 1.6, length), "8fc98a", Vector3.ZERO, 0.03, true))
	body.position = (a + b) / 2.0 + Vector3(0, 0.8, 0)
	body.rotation.y = atan2(b.x - a.x, b.z - a.z)
	add_child(body)
	_paint(body.get_child(1), true)


## A market stall: a counter you can hop on and a striped awning on posts.
func _stall(pos: Vector3, stripe: String) -> void:
	var g := Node3D.new()
	g.add_child(doodle(_box(2.6, 0.9, 1.0), "e6c79c", Vector3(0, 0.45, 0), 0.025, true))
	for sx in [-1.2, 1.2]:
		g.add_child(doodle(_cyl(0.05, 0.05, 1.7, 6), "c99a6a", Vector3(sx, 0.85, -0.4), 0.015))
	for k in 4:
		g.add_child(colored(_box(0.7, 0.1, 1.6), stripe if k % 2 == 0 else "fffaf0", Vector3(-1.05 + k * 0.7, 1.7, 0.0), 0.015, 0.1))
	for k in 3:  # fruit on the counter
		g.add_child(doodle(_sphere(0.15, 8, 5), _pick(["f2788e", "ffd86b", "a8d8a0"]), Vector3(-0.7 + k * 0.7, 1.0, 0.1), 0.012))
	place(g, pos, 1.0, 1.8, 0.0, _box_shape(Vector3(2.6, 0.9, 1.0)), Vector3(0, 0.45, 0))
	var top := StaticBody3D.new()  # the awning holds a mochi too (Postie's first letter waits up there)
	var cs := CollisionShape3D.new()
	cs.shape = _box_shape(Vector3(2.8, 0.1, 1.6))
	top.add_child(cs)
	top.position = pos + Vector3(0, 1.7, 0)
	add_child(top)


func _lamp_post(pos: Vector3) -> void:
	var g := Node3D.new()
	g.add_child(doodle(_cyl(0.05, 0.08, 1.9, 6), "6b6672", Vector3(0, 0.95, 0), 0.015))
	g.add_child(colored(_sphere(0.18, 10, 6), "ffe9a0", Vector3(0, 2.0, 0), 0.015, 0.6))
	place(g, pos, 1.0, 0.5, 0.0, _cyl_shape(0.1, 1.9), Vector3(0, 0.95, 0))
	_keep.append([pos.x, pos.z, 0.8])


## A Bloom Star locked in a wooden cage; a Stone Mochi stomp on the switch sinks the cage into the ground.
func _cage_star(id: String, pos: Vector3, switch_pos: Vector3) -> void:
	var cage := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = _box_shape(Vector3(1.8, 2.0, 1.8))
	cs.position = Vector3(0, 1.0, 0)
	cage.add_child(cs)
	for bx in [-0.8, 0.0, 0.8]:
		for bz in [-0.8, 0.8]:
			cage.add_child(doodle(_cyl(0.06, 0.06, 2.0, 6), "c99a6a", Vector3(bx, 1.0, bz), 0.02))
			cage.add_child(doodle(_cyl(0.06, 0.06, 2.0, 6), "c99a6a", Vector3(bz, 1.0, bx), 0.02))
	cage.add_child(doodle(_box(1.9, 0.15, 1.9), "e6c79c", Vector3(0, 2.05, 0), 0.02, true))
	cage.position = pos
	add_child(cage)
	bloom(id, pos)
	switch(switch_pos, cage, pos.y - 2.3)


# ================================================================== pages made in the level editor (editor/)
## A page saved by the web level editor as res://levels/<name>.json: a grid of ground heights (-1 = hole,
## each step half a metre, cells `cell` metres wide) plus the things placed on it.
func json_path(page: String) -> String:
	return "res://levels/%s.json" % page


func page_exists(page: String) -> bool:
	return page in PAGES or (page != "" and FileAccess.file_exists(json_path(page)))


func _read_json(page: String) -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path(page)))
	return data if typeof(data) == TYPE_DICTIONARY else {}


## Bloom Stars on a page (without building it).
func page_stars(page: String) -> int:
	if page in PAGE_STARS:
		return PAGE_STARS[page]
	if not page_exists(page):
		return 0
	return _read_json(page).get("objects", []).filter(func(o): return o.get("type") == "star").size()


func page_title(page: String) -> String:
	if page in PAGES:
		return PAGES[page]
	var t: String = _read_json(page).get("title", "") if page_exists(page) else ""
	return t if t != "" else page.capitalize()


func _build_json(page: String) -> void:
	var data := _read_json(page)
	var w: int = data.get("w", 0)
	var h: int = data.get("h", 0)
	var cell: float = data.get("cell", 2.0)
	var heights: Array = data.get("heights", [])
	var ground := String(data.get("ground", "#e3f1d4")).trim_prefix("#")
	if w <= 0 or h <= 0 or heights.size() != w * h:
		push_warning("Level %s is not a valid editor level" % page)
		island(0, 0, 8, 8, 0.0)
		checkpoint(Vector3.ZERO)
		return
	var hat := func(x: int, z: int) -> int: return int(heights[z * w + x])
	var to_world := func(x: float, z: float) -> Vector3: return Vector3((x - w / 2.0 + 0.5) * cell, 0, (z - h / 2.0 + 0.5) * cell)
	# ground: merge cells of the same height into big rectangles (fewer bodies, cleaner ink outlines)
	var used := PackedByteArray()
	used.resize(w * h)
	for z in h:
		for x in w:
			var ht: int = hat.call(x, z)
			if used[z * w + x] or ht < 0:
				continue
			var x1 := x
			while x1 + 1 < w and not used[z * w + x1 + 1] and hat.call(x1 + 1, z) == ht:
				x1 += 1
			var z1 := z
			var grow := true
			while grow and z1 + 1 < h:
				for xx in range(x, x1 + 1):
					if used[(z1 + 1) * w + xx] or hat.call(xx, z1 + 1) != ht:
						grow = false
						break
				if grow:
					z1 += 1
			for zz in range(z, z1 + 1):
				for xx in range(x, x1 + 1):
					used[zz * w + xx] = 1
			var c: Vector3 = (to_world.call(x, z) + to_world.call(x1, z1)) / 2.0
			var top := ht * 0.5
			var body := island(c.x, c.z, (x1 - x + 1) * cell, (z1 - z + 1) * cell, top, ground, top + ISLAND_DEPTH)
			var shade := Color(ground).darkened(ht * 0.05)
			body.get_child(1).set_meta("paint", shade)
			_paint(body.get_child(1), true)
	# the start first (it is checkpoint 0), then everything else
	var objects: Array = data.get("objects", [])
	objects.sort_custom(func(a, b): return a.get("type") == "spawn" and b.get("type") != "spawn")
	if objects.is_empty() or objects[0].get("type") != "spawn":
		objects.push_front({"type": "spawn", "x": w / 2, "z": h / 2})
	var n := {}
	for o: Dictionary in objects:
		var t: String = o.get("type", "")
		var ox := clampi(int(o.get("x", 0)), 0, w - 1)
		var oz := clampi(int(o.get("z", 0)), 0, h - 1)
		var top := maxf(0.0, hat.call(ox, oz) * 0.5)
		var pos: Vector3 = to_world.call(ox, oz) + Vector3(0, top, 0)
		var up := Vector3(0, float(o.get("high", 0.0)), 0)
		var rot := -deg_to_rad(float(o.get("rot", 0.0)))
		n[t] = n.get(t, 0) + 1
		var num: int = n[t]
		var hex := func(key: String, fallback: String) -> String: return String(o.get(key, fallback)).trim_prefix("#")
		match t:
			"spawn", "checkpoint":
				checkpoint(pos)
			"star":
				var reveal: String = o.get("reveal", "none")
				bloom("b_%d" % num, pos + up, reveal != "none")
				if reveal != "none":
					reveals["b_%d" % num] = reveal
			"drop":
				paint_drop("d%d" % num, pos + up, hex.call("color", "ff9ab5"))
			"sticker":
				sticker("s%d" % num, pos + up)
			"power":
				power_doodle(o.get("power", "puffy"), pos)
			"smudgie":
				smudgie("m%d" % num, pos, float(o.get("roam", 2.0)))
			"friend":
				var says: String = o.get("says", "Hello!")
				var fid := "friend%d" % num
				friend(fid, pos, hex.call("color", "c3e2a0"), o.get("name", "Pal"), {"ask": says, "done": says, "thanks": says},
					[], o.get("look", "sprout"))
				friends[fid].star = ""
			"tree":
				_tree(pos, float(o.get("size", 1.0)))
			"bush":
				_bush(pos)
			"rock":
				place(rock(), pos, float(o.get("size", 1.0)) * 1.2, 0.8, rot, _cyl_shape(0.4, 0.5), Vector3(0, 0.25, 0))
			"flowers":
				_scatter(flower, pos, 0.9, 10, 1.0, 1.5)
			"mushrooms":
				_scatter(mushroom, pos, 0.8, 5, 0.9, 1.4)
			"pond":
				_pond(pos, float(o.get("radius", 3.0)))
			"bouncy":
				_bouncy(pos)
			"house":
				place(house(), pos, 1.2, 2.4, rot, _box_shape(Vector3(1.6, 2.0, 1.3)), Vector3(0, 1.0, 0))
			"fence":
				var along := Vector3(cos(rot), 0, -sin(rot)) * cell / 2.0
				_fence(pos - along, pos + along)
			"sign":
				_signpost(pos, o.get("text", ""))
			"platform":
				var s := float(o.get("size", 3.0))
				var cloud_top := top + float(o.get("high", 3.0))
				var pl := island(pos.x, pos.z, s, s, cloud_top, "ffffff", 0.6)
				_paint(pl.get_child(1), true)
				for k in 2:
					pl.add_child(doodle(_sphere(s * 0.3), "ffffff", Vector3((k * 2 - 1) * s * 0.4, -0.1, (k * 2 - 1) * s * 0.2), 0.03))


func _bouncy(pos: Vector3) -> void:
	var mush := Node3D.new()
	mush.add_child(doodle(_cyl(0.35, 0.45, 0.8, 10), "fff1dc", Vector3(0, 0.4, 0), 0.03))
	var cap := doodle(_sphere(1.1, 16, 8, true), "f2788e", Vector3(0, 0.7, 0), 0.04)
	cap.scale = Vector3(1.0, 0.45, 1.0)
	mush.add_child(cap)
	place(mush, pos, 1.0, 1.2, 0.0, _cyl_shape(1.0, 1.2), Vector3(0, 0.6, 0))
	bouncers.append({"pos": pos + Vector3(0, 1.2, 0), "r": 1.05})


# ================================================================== dressing the open Meadow
## Fill the spaces between the Meadow's landmarks: stepping-stone paths that lead to each one, signposts,
## a pond, hedges along the edges, groves, flower beds, fences, a picnic and butterflies. Every prop is
## placed with `_clear()` so nothing lands on a star, a friend, a hoop, a path or a landmark.
func _dress_meadow() -> void:
	_keep = [
		[-16, 2, 4.0], [16, -10, 7.5], [27, -10, 2.0], [-14, -16, 4.6], [4, -20, 2.4], [6.8, -18, 1.4],
		[-4, -5, 2.0], [-4, -9.5, 2.4], [22, 17, 2.8], [26.5, 14, 2.8], [19.8, 19.4, 1.6], [0, -30, 4.5],
		[-24, 22, 5.0], [5, 24, 2.6],
	]
	# paths from the start flag out to every landmark
	var start := Vector3(0, 0, 21)
	_stone_path([start, Vector3(-5, 0, 15), Vector3(-11, 0, 8), Vector3(-14.5, 0, 5.5)])         # giant tree
	_stone_path([Vector3(-11, 0, 8), Vector3(-18, 0, 14), Vector3(-20.5, 0, 19)])                   # pond
	_stone_path([start, Vector3(3, 0, 12), Vector3(5, 0, 0), Vector3(8.5, 0, -6)])                  # hill
	_stone_path([Vector3(5, 0, 0), Vector3(-1, 0, -12), Vector3(-1.5, 0, -25), Vector3(0, 0, -29.5)])  # Ink Trail
	_stone_path([Vector3(-1, 0, -12), Vector3(-6, 0, -15), Vector3(-10, 0, -15.5)])                 # nest
	_stone_path([start, Vector3(10, 0, 20), Vector3(18, 0, 19.5)])                                   # village
	for s in [[Vector3(-4.2, 0, 16.5), "Giant Tree"], [Vector3(-12.5, 0, 10.5), "Pond"],
			[Vector3(4.6, 0, 11.5), "Hill"], [Vector3(-0.6, 0, -10.5), "Ink Trail"],
			[Vector3(-4.5, 0, -13.6), "Ink Puddle"], [Vector3(9.5, 0, 21.5), "Village"]]:
		_signpost(s[0], s[1])
	_pond(Vector3(-24, 0, 22))
	# a picnic by the start: a blanket, a basket and a pie
	var picnic := Node3D.new()
	picnic.add_child(doodle(_box(2.2, 0.03, 1.6), "ffb3c4", Vector3(0, 0.015, 0), 0.02, true))
	picnic.add_child(doodle(_box(0.6, 0.35, 0.4), "d9b38c", Vector3(-0.5, 0.2, 0.2), 0.02, true))
	picnic.add_child(doodle(_cyl(0.3, 0.28, 0.12, 14), "f5c35b", Vector3(0.5, 0.06, -0.2), 0.02))
	place(picnic, Vector3(5, 0, 24), 1.0, 0.0, 0.2, _box_shape(Vector3(0.6, 0.35, 0.4)), Vector3(-0.5, 0.2, 0.2))
	# a garden fence around the village houses, and one along the pond
	_fence(Vector3(17.5, 0, 22.5), Vector3(29, 0, 22.5))
	_fence(Vector3(29.5, 0, 22), Vector3(29.5, 0, 11))
	_fence(Vector3(-28.5, 0, 16.5), Vector3(-19.5, 0, 16.5))
	# hedges along the page edges (with gaps, so careless hops can still fall off the page)
	for x in range(-30, 31, 3):
		if absf(x) > 6.0:  # leave the trail gate open
			_bush(Vector3(x + rng.randf_range(-0.6, 0.6), 0, -29.0))
		if rng.randf() < 0.75:
			_bush(Vector3(x + rng.randf_range(-0.6, 0.6), 0, 29.0))
	for z in range(-27, 28, 3):
		for side in [-31.0, 31.0]:
			if rng.randf() < 0.75:
				_bush(Vector3(side, 0, z + rng.randf_range(-0.6, 0.6)))
	# groves, bushes, rocks, mushroom rings and flower beds in the open spaces
	_sprinkle(func(p): _tree(p, rng.randf_range(0.9, 1.4)), 26, 2.2)
	_sprinkle(func(p): _bush(p), 30, 1.4)
	_sprinkle(func(p): place(rock(), p, rng.randf_range(0.8, 1.6), 0.8, INF, _cyl_shape(0.4, 0.5), Vector3(0, 0.25, 0)), 18, 1.2)
	for k in 6:
		_sprinkle(func(p): _scatter(mushroom, p, 0.9, 6, 0.9, 1.4), 1, 1.5)
	for k in 10:
		_sprinkle(func(p): _scatter(flower, p, 1.8, 14, 1.0, 1.6), 1, 2.0)
	for k in 9:
		_butterfly(Vector3(rng.randf_range(-26, 26), 0, rng.randf_range(-24, 26)))


## Is `p` free for a prop of radius `r`? (on the page, off paths, stars, friends, hoops and landmarks)
func _clear(p: Vector3, r: float) -> bool:
	if absf(p.x) > 30.0 or absf(p.z) > 28.0:
		return false
	for c in _keep:
		if Vector2(p.x - c[0], p.z - c[1]).length() < c[2] + r:
			return false
	var points: Array = []
	for e in edibles:
		points.append(e.home)
	for id in friends:
		points.append(friends[id].home)
	for h in race.hoops:
		points.append(h.position)
	for c in checkpoints:
		points.append(c.pos)
	for q in points:
		if Vector2(p.x - q.x, p.z - q.z).length() < r + 1.2:
			return false
	return true


## Place `count` things where `_clear` allows, at random spots on the page.
func _sprinkle(make: Callable, count: int, r: float) -> void:
	var placed := 0
	for attempt in count * 30:
		if placed >= count:
			return
		var p := Vector3(rng.randf_range(-30, 30), 0, rng.randf_range(-28, 28))
		if _clear(p, r):
			make.call(p)
			_keep.append([p.x, p.z, r * 0.6])
			placed += 1


## Flat stepping stones along a polyline, a little wobbly like a hand-drawn dotted line.
func _stone_path(points: Array) -> void:
	for i in points.size() - 1:
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var steps := int(a.distance_to(b) / 1.05)
		for k in steps:
			var p := a.lerp(b, (k + 0.5) / steps) + Vector3(rng.randf_range(-0.2, 0.2), 0, rng.randf_range(-0.2, 0.2))
			var stone := doodle(_cyl(0.26, 0.29, 0.04, 9), "e6d2aa", p + Vector3(0, 0.02, 0), 0.008)
			stone.scale = Vector3(rng.randf_range(0.8, 1.15), 1.0, rng.randf_range(0.75, 1.0))
			stone.rotation.y = rng.randf() * TAU
			add_child(stone)
			_paint(stone, true)  # paths are always drawn in, so they lead the way even on an ink page
			_keep.append([p.x, p.z, 0.6])


func _signpost(pos: Vector3, text: String) -> void:
	var g := Node3D.new()
	g.add_child(doodle(_cyl(0.06, 0.07, 1.3, 6), "c99a6a", Vector3(0, 0.65, 0), 0.02))
	g.add_child(doodle(_box(1.3, 0.42, 0.08), "f3d9b0", Vector3(0, 1.2, 0), 0.025, true))
	place(g, pos, 1.0, 0.5, 0.0, _cyl_shape(0.12, 1.3), Vector3(0, 0.65, 0))
	var label := Label3D.new()
	label.text = text
	label.font = _ui_font()
	label.font_size = 64
	label.pixel_size = 0.005
	label.modulate = Color("1f1d24")
	label.outline_modulate = Color("f3d9b0")
	label.outline_size = 8
	label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	label.position = pos + Vector3(0, 1.22, 0)
	add_child(label)
	_keep.append([pos.x, pos.z, 0.8])


## A pond with lily pads, reeds and a little dock. Flat, so the mochi just walks across the water.
func _pond(c: Vector3, r := 4.0) -> void:
	var sc := r / 4.0
	var water := doodle(_cyl(r, r, 0.04, 32), "8fd0f5", c + Vector3(0, 0.02, 0), 0.04)
	water.scale = Vector3(1.0, 1.0, 0.8)
	add_child(water)
	for k in 7:
		var a := k / 7.0 * TAU + 0.3
		var pad := doodle(_cyl(0.42, 0.42, 0.03, 12), "8fc98a", c + Vector3(cos(a) * 2.4 * sc, 0.05, sin(a) * 1.8 * sc), 0.015)
		add_child(pad)
		if k % 3 == 0:
			add_child(doodle(_sphere(0.1, 8, 5), "ff9ab5", pad.position + Vector3(0.12, 0.08, 0), 0.012))
	for k in 12:
		var a := rng.randf_range(2.6, 4.4)
		var reed := doodle(_cyl(0.025, 0.035, rng.randf_range(0.7, 1.2), 5), "6fae8c",
			c + Vector3(cos(a) * r, 0.45, sin(a) * r * 0.8) + Vector3(rng.randf_range(-0.3, 0.3), 0, rng.randf_range(-0.3, 0.3)), 0.012)
		add_child(reed)
	var dock := doodle(_box(1.2, 0.12, 2.6), "d9b38c", c + Vector3(2.6, 0.1, -2.6) * sc, 0.025, true)
	dock.rotation.y = 0.6
	add_child(dock)


func _fence(a: Vector3, b: Vector3) -> void:
	var length := a.distance_to(b)
	var dir := (b - a).normalized()
	var posts := int(length / 1.3) + 1
	for k in posts:
		add_child(doodle(_box(0.12, 0.7, 0.12), "fffaf0", a.lerp(b, float(k) / (posts - 1)) + Vector3(0, 0.35, 0), 0.02, true))
	var mid := (a + b) / 2.0
	var yaw := atan2(dir.x, dir.z)
	for h in [0.28, 0.55]:
		var rail := doodle(_box(0.06, 0.1, length), "fffaf0", mid + Vector3(0, h, 0), 0.015, true)
		rail.rotation.y = yaw
		add_child(rail)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = _box_shape(Vector3(0.2, 0.8, length))
	body.add_child(cs)
	body.position = mid + Vector3(0, 0.4, 0)
	body.rotation.y = yaw
	add_child(body)


func _bush(pos: Vector3) -> void:
	var g := Node3D.new()
	var leaf: String = _pick(["a8d8a0", "9fd0b4", "b5dc96"])
	for b in [[0.55, 0.0, 0.0], [0.42, 0.45, 0.1], [0.4, -0.42, -0.05], [0.36, 0.1, 0.4]]:
		g.add_child(doodle(_sphere(b[0], 12, 7), leaf, Vector3(b[1], b[0] * 0.8, b[2]), 0.03))
	if rng.randf() < 0.35:  # some bushes have berries
		for k in 4:
			g.add_child(doodle(_sphere(0.07, 6, 4), "e5485e", Vector3(rng.randf_range(-0.5, 0.5), rng.randf_range(0.4, 0.8), 0.45), 0.01))
	place(g, pos, rng.randf_range(0.9, 1.3), 1.4, INF, _cyl_shape(0.65, 0.9), Vector3(0, 0.45, 0))


## A little butterfly that loops lazily around `home`. Always in colour: it's alive, not a doodle.
func _butterfly(home: Vector3) -> void:
	var g := Node3D.new()
	var wing: String = _pick(["ff9ab5", "ffd86b", "b9a2ee", "8fd0f5"])
	for sx in [-1.0, 1.0]:
		var w := colored(_sphere(0.13, 8, 5), wing, Vector3(sx * 0.11, 0, 0), 0.012, 0.2)
		w.scale = Vector3(1.0, 0.12, 0.8)
		g.add_child(w)
	g.add_child(colored(_cyl(0.02, 0.02, 0.18, 5), "1f1d24", Vector3.ZERO, 0.0, 0.0))
	g.get_child(2).rotation.x = PI / 2.0
	add_child(g)
	flutters.append({"node": g, "home": home + Vector3(0, 1.2, 0), "phase": rng.randf() * TAU, "r": rng.randf_range(1.5, 3.5)})


func _update_flutters() -> void:
	for f in flutters:
		var t: float = time * 0.6 + f.phase
		var n: Node3D = f.node
		var p: Vector3 = f.home + Vector3(cos(t) * f.r, sin(t * 2.7) * 0.4, sin(t * 1.3) * f.r)
		n.rotation.y = atan2(p.x - n.position.x, p.z - n.position.z)
		n.position = p
		var flap := sin(time * 22.0 + f.phase) * 0.9
		n.get_child(0).rotation.z = flap
		n.get_child(1).rotation.z = -flap


# ================================================================== the World Map (playable book map)
## Chapter stamps in play order: id, x, z, colour, chapter, page it opens, title. A page that isn't built yet
## (no builder and no res://levels/<page>.json from the level editor) says "still being drawn".
const STAMPS := [
	["1", -18.0, 10.5, "ff9ab5", 1, "meadow", "The Meadow"], ["2", -17.0, -1.5, "f5c35b", 2, "village", "The Village"],
	["3", 5.5, 11.5, "7fb5ec", 3, "seaside", "Seaside"], ["4", 5.5, -6.5, "a585e0", 4, "snowy", "Snowy Notebook"],
	["E", 0.0, -11.5, "26232b", 0, "castle", "The Eraser's Castle"],
]
const CHAPTER_CENTERS := {1: Vector3(-11, 0, 7), 2: Vector3(-11, 0, -6), 3: Vector3(11, 0, 7), 4: Vector3(11, 0, -6)}
const HOME_STAMP := Vector3(0, 0, 11.0)

var map_done: Array = []        # stamp ids whose chapter has enough Bloom Stars to open the next
var map_stars := {}             # Bloom Stars found per stamp id
var map_at := "1"               # where the mochi stands on the map
var map_new := ""               # a stamp finished just now: its region and next path draw in with a flourish


func stamp_info(id: String) -> Array:
	for s in STAMPS:
		if s[0] == id:
			return s
	return []


func stamp_for_level(page: String) -> String:
	for s in STAMPS:
		if page != "" and s[5] == page:
			return s[0]
	return ""


## A stamp is open when it is the first, or the one before it is painted.
func stamp_open(i: int) -> bool:
	return i == 0 or STAMPS[i - 1][0] in map_done


## The whole book as one walkable map: an open sketchbook whose two pages hold the four chapter regions,
## level stamps joined by dotted ink paths, the Ink Bloom in the middle and the Eraser's castle beyond the
## top edge. Regions stay ink-only until one of their pages is painted.
func _build_worldmap() -> void:
	var top := 0.3
	var y := top
	for c in clouds:  # the page clouds would hang over the map; it gets its own, off the book edges
		c.queue_free()
	clouds.clear()
	# the open book: cover, page stack, two walkable pages, the crease
	add_child(doodle(_box(46, 0.5, 29), "b8665f", Vector3(0, -0.55, 0), 0.06, true))
	add_child(doodle(_box(44.5, 0.5, 27.4), "f3ead8", Vector3(0, -0.15, 0), 0.04, true))
	island(-11.1, 0, 21.8, 26.6, top, "fbf5e6", 0.4)
	island(11.1, 0, 21.8, 26.6, top, "fbf5e6", 0.4)
	add_child(doodle(_box(0.25, 0.05, 26.6), "d8cdb6", Vector3(0, top + 0.01, 0), 0.0, true))
	# --- Chapter 1, Meadow (front left): rolling hills, trees, flowers
	for h in [[-14.8, 7.2, 2.0], [-20.2, 4.2, 1.5], [-4.6, 12.0, 1.3], [-14.0, 1.6, 1.4], [-3.8, 5.0, 1.5]]:
		var hill := Node3D.new()  # wrapped, so the squashed dome never scales the collider
		var dome := doodle(_sphere(h[2], 18, 10, true), "a9dd8f", Vector3.ZERO, 0.05)
		dome.scale = Vector3(1.0, 0.38, 1.0)
		hill.add_child(dome)
		place(hill, Vector3(h[0], y, h[1]), 1.0, 0.0, 0.0, _cyl_shape(h[2] * 0.75, h[2] * 0.38), Vector3(0, h[2] * 0.19, 0))
	for p in [[-20.3, 8.0], [-16.5, 4.0], [-5.0, 2.4], [-10.5, 6.2], [-2.6, 11.8]]:
		_tree(Vector3(p[0], y, p[1]), 1.1)
	_scatter(flower, Vector3(-11.5, y, 7.5), 3.0, 24, 1.3, 1.8)
	_scatter(mushroom, Vector3(-7, y, 4), 1.3, 5, 1.4, 2.0)
	# --- Chapter 2, Village (back left): little houses, a windmill
	for h in [[-16, -4, 0.3], [-13, -2.5, -0.2], [-9.5, -4.5, 0.4], [-15, -8.5, -0.5], [-8, -9, 0.2]]:
		place(house(), Vector3(h[0], y, h[1]), 1.2, 2.4, h[2], _box_shape(Vector3(1.6, 2.0, 1.3)), Vector3(0, 1.0, 0))
	var mill := Node3D.new()
	mill.add_child(doodle(_cyl(0.6, 0.9, 3.0, 10), "f7d9b0", Vector3(0, 1.5, 0), 0.04))
	mill.add_child(doodle(_cyl(0.0, 1.0, 0.9, 10), "e88f8f", Vector3(0, 3.4, 0), 0.04))
	for k in 4:
		var blade := doodle(_box(0.35, 2.4, 0.08), "fffaf0", Vector3(0, 2.9, 0.75), 0.03, true)
		blade.rotation.z = k * PI / 2.0 + 0.3
		blade.position += Vector3(cos(k * PI / 2.0 + 0.3 + PI / 2.0), sin(k * PI / 2.0 + 0.3 + PI / 2.0), 0) * 1.1
		mill.add_child(blade)
	place(mill, Vector3(-19, y, -9.5), 1.0, 2.2, 0.3, _cyl_shape(0.9, 3.0), Vector3(0, 1.5, 0))
	# --- Chapter 3, Seaside (front right): a painted sea with islets, a lighthouse, bubbles
	var sea := colored(_cyl(7.5, 7.5, 0.12, 40), "8fd0f5", Vector3(12, y + 0.06, 7.5), 0.04, 0.2)
	sea.scale = Vector3(1.15, 1.0, 0.75)
	add_child(sea)
	for i in [[8, 6, 1.5], [15, 9, 1.8], [12.5, 4.5, 1.0], [17, 5, 1.1]]:
		var islet := doodle(_sphere(i[2], 16, 8, true), "f6e3b4", Vector3(i[0], y + 0.1, i[1]), 0.04)
		islet.scale = Vector3(1.0, 0.35, 1.0)
		add_child(islet)
	var light := Node3D.new()
	for k in 4:
		light.add_child(doodle(_cyl(0.42 - k * 0.05, 0.47 - k * 0.05, 0.75, 12), "e5485e" if k % 2 == 0 else "ffffff",
			Vector3(0, 0.37 + k * 0.75, 0), 0.03))
	light.add_child(doodle(_cyl(0.32, 0.32, 0.5, 12), "ffe07a", Vector3(0, 3.25, 0), 0.03))
	light.add_child(doodle(_cyl(0.0, 0.45, 0.6, 12), "e5485e", Vector3(0, 3.8, 0), 0.03))
	place(light, Vector3(15, y + 0.4, 9), 1.0, 1.4, 0.0, _cyl_shape(0.5, 3.0), Vector3(0, 1.5, 0))
	for b in 14:
		add_child(colored(_sphere(rng.randf_range(0.18, 0.45)), "dff3ff",
			Vector3(rng.randf_range(6, 18), y + rng.randf_range(1.2, 3.0), rng.randf_range(3, 12)), 0.02, 0.4))
	_tree(Vector3(8, y + 0.4, 6), 0.8)
	# --- Chapter 4, Snowy Notebook (back right): snowy mounds, pines, ice crystals
	for h in [[8, -3.5, 2.0], [15, -3.5, 2.0], [12, -9.5, 2.6], [18.5, -9, 1.6]]:
		var mound := Node3D.new()
		var dome := doodle(_sphere(h[2], 18, 10, true), "f4f8ff", Vector3.ZERO, 0.05)
		dome.scale = Vector3(1.0, 0.5, 1.0)
		mound.add_child(dome)
		place(mound, Vector3(h[0], y, h[1]), 1.0, 0.0, 0.0, _cyl_shape(h[2] * 0.75, h[2] * 0.5), Vector3(0, h[2] * 0.25, 0))
	for p in [[6.5, -1.5, 1.0], [10, -1.5, 1.3], [17.5, -5.5, 1.1], [8.5, -10, 1.2], [15.5, -12.2, 1.0], [19.5, -2.5, 0.9]]:
		var pine := Node3D.new()
		pine.add_child(doodle(_cyl(0.1, 0.14, 0.6, 8), "c99a6a", Vector3(0, 0.3, 0), 0.02))
		for k in 3:
			pine.add_child(doodle(_cyl(0.0, 0.9 - k * 0.2, 0.9, 9), "6fae8c", Vector3(0, 0.9 + k * 0.55, 0), 0.03))
		pine.add_child(doodle(_cyl(0.0, 0.32, 0.35, 9), "ffffff", Vector3(0, 2.35, 0), 0.02))
		place(pine, Vector3(p[0], y, p[1]), p[2], 1.4, INF, _cyl_shape(0.45, 2.4), Vector3(0, 1.2, 0))
	for c in 6:
		var crystal := colored(_cyl(0.0, 0.35, 1.4, 5), "bfe6ff", Vector3(rng.randf_range(9, 18), y + 0.6, rng.randf_range(-11, -6)), 0.025, 0.35)
		crystal.rotation = Vector3(rng.randf_range(-0.3, 0.3), 0, rng.randf_range(-0.3, 0.3))
		add_child(crystal)
	# --- The Eraser's castle, beyond the top edge of the book
	var castle := Node3D.new()
	castle.add_child(doodle(_box(5.0, 2.6, 2.6), "f59ab4", Vector3(0, 1.3, 0), 0.06, true))       # an eraser block
	castle.add_child(doodle(_box(5.1, 0.9, 2.7), "7fb5ec", Vector3(0, 2.4, 0), 0.05, true))       # its paper sleeve
	for sx in [-2.2, 0.0, 2.2]:
		castle.add_child(doodle(_cyl(0.35, 0.35, 2.6 if sx == 0.0 else 1.8, 6), "ffd86b", Vector3(sx, 3.2 + (0.4 if sx == 0.0 else 0.0), 0), 0.04))
		castle.add_child(doodle(_cyl(0.0, 0.35, 0.8, 6), "f3d2a6", Vector3(sx, 4.9 if sx == 0.0 else 4.5, 0), 0.03))
	place(castle, Vector3(0, -0.3, -17.5), 1.0, 0.0, 0.0)
	# --- The Ink Bloom: a giant living doodle flower at the heart of the book
	var bloom := Node3D.new()
	bloom.add_child(doodle(_cyl(0.18, 0.28, 3.2, 10), "8fc98a", Vector3(0, 1.6, 0), 0.04))
	for k in 8:
		var a := k / 8.0 * TAU
		var petal := doodle(_sphere(0.85, 14, 8), "ff9ab5" if k % 2 == 0 else "b9a2ee", Vector3(cos(a) * 1.05, 3.4, sin(a) * 1.05), 0.04)
		petal.scale = Vector3(1.0, 0.45, 0.6)
		petal.rotation.y = -a
		bloom.add_child(petal)
	bloom.add_child(doodle(_sphere(0.65), "ffe07a", Vector3(0, 3.55, 0), 0.04))
	for k in 2:
		var leaf := doodle(_sphere(0.7, 12, 6), "8fc98a", Vector3((k * 2 - 1) * 0.7, 1.2 + k * 0.5, 0), 0.03)
		leaf.scale = Vector3(1.0, 0.25, 0.5)
		leaf.rotation.z = (k * 2 - 1) * -0.5
		bloom.add_child(leaf)
	for k in 7:  # sparkles around it
		var a := k / 7.0 * TAU
		bloom.add_child(colored(_star_mesh(0.3, 0.12, 0.05), "ffe07a", Vector3(cos(a) * 2.6, 3.0 + sin(a * 2.0) * 0.8, sin(a) * 2.6), 0.02, 0.3))
	place(bloom, Vector3(0, y, 1.5), 1.3, 3.0, 0.0, _cyl_shape(0.45, 4.0), Vector3(0, 2.0, 0))
	# --- level stamps and the paths between them
	var prev := Vector3.INF
	for i in STAMPS.size():
		var s: Array = STAMPS[i]
		var pos := Vector3(s[1], y, s[2])
		var open := stamp_open(i)
		var done: bool = s[0] in map_done
		add_child(colored(_cyl(0.75, 0.85, 0.3, 24), s[3] if open else "d6d1dd", pos + Vector3(0, 0.15, 0), 0.04, 0.15))
		var total: int = page_stars(s[5])
		var label: String = s[6] if open else "?"
		if open and total > 0:
			label += "\n★ %d / %d" % [map_stars.get(s[0], 0), total]
		_map_label(label, pos + Vector3(0, 2.4 if total > 0 else 1.4, 0))
		if done:  # a gold star on painted pages
			var st := colored(_star_mesh(0.45, 0.2, 0.08), "ffd86b", pos + Vector3(0, 0.95, 0), 0.03, 0.3)
			add_child(st)
			st.create_tween().set_loops().tween_property(st, "rotation:y", TAU, 2.5).as_relative()
		if open:
			var page: String = s[5] if page_exists(s[5]) else ""
			zones.append({"id": "stamp", "stamp": s[0], "level": page, "pos": pos, "radius": 1.0,
				"prompt": "E  Enter %s" % s[6]})
		if prev != Vector3.INF and open:  # the path to this stamp is drawn once it opens
			var fresh: bool = STAMPS[i - 1][0] == map_new
			_dotted_path(prev, pos, fresh)
		prev = pos
	# the way back to the Home Page: a little house stamp at the front edge
	var hp := Vector3(HOME_STAMP.x, y, HOME_STAMP.z)
	add_child(colored(_cyl(0.75, 0.85, 0.3, 24), "c86b6b", hp + Vector3(0, 0.15, 0), 0.04, 0.15))
	var hut := house()
	hut.scale = Vector3.ONE * 0.35
	hut.position = hp + Vector3(0, 0.3, 0)
	add_child(hut)
	_map_label("Home", hp + Vector3(0, 1.4, 0))
	zones.append({"id": "home", "pos": hp, "radius": 1.0, "prompt": "E  Back to the Home Page"})
	for k in 8:
		var c := cloud()
		var side := 1.0 if k % 2 == 0 else -1.0  # off the edges of the book, so they frame it without hiding regions
		if k < 6:
			c.position = Vector3(side * rng.randf_range(25, 33), rng.randf_range(6, 9), rng.randf_range(-20, 12))
		else:
			c.position = Vector3(rng.randf_range(-18, 18), rng.randf_range(8, 10), rng.randf_range(-26, -20))
		c.scale = Vector3.ONE * rng.randf_range(1.2, 2.2)
		add_child(c)
		clouds.append(c)
	# where the mochi starts: in front of the stamp it last used (or the home stamp)
	var at := stamp_info(map_at)
	var start := Vector3(at[1], y, at[2]) if not at.is_empty() else hp
	checkpoint(start + Vector3(0, 0, 2.2))  # just in front, so the stamp and its label stay in view
	checkpoints[0].node.visible = false
	# colour: a chapter region is painted once one of its pages is; a page finished just now ripples out from
	# its stamp. The cover, crease, Ink Bloom and castle belong to no chapter and are always in colour.
	var fresh_at := Vector3.INF
	var info := stamp_info(map_new)
	if not info.is_empty():
		fresh_at = Vector3(info[1], y, info[2])
	for mi in paintables:
		if mi.get_meta("painted"):
			continue
		var p := mi.global_position
		var ch := _chapter_of(p)
		if ch == 0:
			_paint(mi, true)
		elif STAMPS.any(func(s): return s[4] == ch and s[0] in map_done):
			var fresh: bool = fresh_at != Vector3.INF and _chapter_of(fresh_at) == ch
			_paint(mi, not fresh, 0.4 + Vector2(p.x - fresh_at.x, p.z - fresh_at.z).length() / 8.0 if fresh else 0.0)


## Which chapter region of the book map a point lies in (the nearest centre), or 0 off the regions.
func _chapter_of(p: Vector3) -> int:
	if absf(p.x) < 3.0 or p.z < -14.0 or p.y < 0.0:  # crease and Ink Bloom, the castle, the cover
		return 0
	var best := 0
	for ch in CHAPTER_CENTERS:
		var c: Vector3 = CHAPTER_CENTERS[ch]
		if best == 0 or Vector2(p.x - c.x, p.z - c.z).length() < Vector2(p.x - CHAPTER_CENTERS[best].x, p.z - CHAPTER_CENTERS[best].z).length():
			best = ch
	return best


func _map_label(text: String, pos: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.font = _ui_font()
	label.font_size = 96
	label.pixel_size = 0.0065
	label.modulate = Color("1f1d24")
	label.outline_modulate = Color.WHITE
	label.outline_size = 18
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = pos
	add_child(label)


## Dotted ink path between two stamps; `fresh` dots pop in one after another.
func _dotted_path(a: Vector3, b: Vector3, fresh: bool) -> void:
	var d := a.distance_to(b)
	var steps := int(d / 0.7)
	for k in range(1, steps):
		var t := float(k) / steps
		var p := a.lerp(b, t) + Vector3(0, 0.05, sin(t * PI * 2.0) * 0.4)
		var dot := colored(_sphere(0.11, 8, 5), "1f1d24", p, 0.0, 0.0)
		add_child(dot)
		if fresh:
			dot.scale = Vector3.ONE * 0.01
			var tw := create_tween()
			tw.tween_interval(1.2 + k * 0.08)
			tw.tween_property(dot, "scale", Vector3.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func sticker_ids() -> Array:
	return edibles.filter(func(e): return e.kind == "sticker").map(func(e): return e.id)


# ================================================================== eating
## The closest uneaten edible within reach of `pos`, or {} if none.
func nearest_edible(pos: Vector3) -> Dictionary:
	var best := {}
	var best_d := REACH
	for e in edibles:
		if e.got or not e.node.visible or (e.kind == "smudgie" and e.get("dead", false)):
			continue
		var p: Vector3 = e.node.global_position
		var dist := Vector2(pos.x - p.x, pos.z - p.z).length()
		if dist < best_d and absf(p.y - pos.y) < 1.6:
			best_d = dist
			best = e
	return best


## Inhale `e` toward `mouth`: drifts at first, then whooshes in, squishing thin. True once it's in.
func pull(e: Dictionary, mouth: Vector3, delta: float) -> bool:
	e.sucking = true
	var m: Node3D = e.node
	var to := mouth - m.global_position
	var dist := to.length()
	var near := 1.0 - clampf(dist / REACH, 0.0, 1.0)
	var speed := 0.7 + 4.5 * near * near
	m.global_position += to.normalized() * minf(dist, speed * delta)
	var s := clampf(dist / REACH * 1.3, 0.3, 1.0) * (1.6 if e.kind in ["seal", "bloom"] else 1.0)
	s = minf(s, 1.0)
	m.scale = Vector3(s, s * (2.0 - s), s)
	m.rotation.y += delta * 12.0
	return dist < 0.14


## The mochi stopped inhaling: float it back home (Smudgies just carry on from where they are).
func release(e: Dictionary) -> void:
	if e.is_empty() or e.got:
		return
	e.sucking = false
	var tw := create_tween().set_parallel()
	tw.tween_property(e.node, "scale", Vector3.ONE, 0.4)
	if e.kind != "smudgie":
		tw.tween_property(e.node, "position", e.home, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func collect(e: Dictionary, instant := false) -> void:
	e.got = true
	e.sucking = false
	e.node.visible = false
	e.shadow.visible = false
	var p: Vector3 = e.home if instant else e.node.global_position
	match e.kind:
		"drop":
			paint_around(p, 7.0, instant)
			if not instant:
				_splash(p, e.color)
		"power":  # power doodles grow back so you can always try again
			get_tree().create_timer(3.0).timeout.connect(func():
				e.got = false
				e.node.position = e.home
				e.node.scale = Vector3.ONE
				e.node.visible = true
				e.shadow.visible = true)
		"sticker":
			if not instant:
				_splash(p, Color("ffd86b"))
		"smudgie":
			e.dead = true
			if not instant:
				_splash(p, Color("8f8a99"))
		"seal":
			_paint_all(instant)
			if not instant:
				_splash(p, Color("ff9ab5"))
		"bloom":  # every Bloom Star colours the meadow around it; the last one paints the whole page
			paint_around(p, 9.0, instant)
			if bloom_ids().all(func(id): return edibles.any(func(b): return b.id == id and b.got)):
				_paint_all(instant)
			if not instant:
				_splash(p, Color("ffd86b"))
		"item":
			if not instant:
				_splash(p, Color("ffffff"))
	if not instant:
		ate.emit(e.kind, e)


func drops_left() -> int:
	return drops.filter(func(d): return not d.got).size()


# ================================================================== painting
func paint_around(at: Vector3, radius: float, instant := false) -> void:
	for mi in paintables:
		if not is_instance_valid(mi) or mi.get_meta("painted"):
			continue
		var p := mi.global_position
		var dist := Vector2(p.x - at.x, p.z - at.z).length()
		if dist < radius:
			_paint(mi, instant, dist / 10.0)


func _paint_all(instant := false) -> void:
	for mi in paintables:
		if not mi.get_meta("painted"):
			_paint(mi, instant, rng.randf() * 0.8)


func _paint(mi: GeometryInstance3D, instant := false, delay := 0.0) -> void:
	mi.set_meta("painted", true)
	var target: Color = mi.get_meta("paint")
	if instant or not is_inside_tree():
		mi.set_instance_shader_parameter("albedo", target)
		return
	var tw := create_tween()
	tw.tween_interval(delay)  # ripples outward
	tw.tween_method(func(c: Color):
		if is_instance_valid(mi):
			mi.set_instance_shader_parameter("albedo", c), WHITE, target, 0.6).set_trans(Tween.TRANS_SINE)


func _splash(at: Vector3, color: Color) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.9
	tm.outer_radius = 1.0
	ring.mesh = tm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	ring.material_override = mat
	ring.position = Vector3(at.x, at.y - 0.4, at.z)
	ring.scale = Vector3(1, 0.05, 1)
	add_child(ring)
	var tw := create_tween().set_parallel()
	tw.tween_property(ring, "scale", Vector3(9, 0.05, 9), 1.1).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(mat, "albedo_color:a", 0.0, 1.1)
	tw.chain().tween_callback(ring.queue_free)


# ================================================================== checkpoints, switches, stomps, stars
## Touching a flag makes it the respawn point (and paints it).
func update_checkpoints(pos: Vector3) -> void:
	for i in checkpoints.size():
		var c: Dictionary = checkpoints[i]
		if i != active_checkpoint and pos.distance_to(c.pos) < 1.3 and c.node.visible:
			active_checkpoint = i
			if not c.reached:
				c.reached = true
				_paint(c.flag)
				checkpoint_reached.emit(i)


## A Stone Mochi landed hard at `at`: press switches and stun Smudgies close by.
func pound(at: Vector3) -> void:
	for s in switches:
		if not s.on and Vector2(at.x - s.pos.x, at.z - s.pos.z).length() < 1.0 and absf(at.y - s.pos.y) < 0.5:
			s.on = true
			var tw := create_tween()
			tw.tween_property(s.plate, "scale", Vector3(1, 0.3, 1), 0.15)
			tw.tween_property(s.bridge, "position:y", s.raised_y, 1.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			switch_pressed.emit()
	for m in smudgies:
		if not m.got and m.node.global_position.distance_to(at) < 2.2:
			m.stun = 3.0
	_splash(at + Vector3(0, 0.4, 0), Color("b5b8c6"))


## Spit a star from `from` toward `dir`; it knocks out the first Smudgie it hits.
func spit_star(from: Vector3, dir: Vector3, color: Color) -> void:
	var node := colored(_star_mesh(0.18, 0.08, 0.04), color.to_html(false), from, 0.02, 0.2)
	add_child(node)
	stars.append({"node": node, "vel": dir.normalized() * 9.0, "t": 0.0})


func _poof(node: Node3D) -> void:
	var tw := create_tween()
	tw.tween_property(node, "scale", Vector3.ONE * 0.01, 0.2)
	tw.tween_callback(node.queue_free)


## Called by the game every frame while playing.
func tick(delta: float, player_pos: Vector3) -> void:
	_update_smudgies(delta, player_pos)
	_tick_race(delta, player_pos)
	_check_tasks()
	for i in range(stars.size() - 1, -1, -1):
		var s: Dictionary = stars[i]
		s.t += delta
		var n: Node3D = s.node
		var next: Vector3 = n.global_position + s.vel * delta
		n.rotation.z += delta * 14.0
		var hit_wall := not get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(n.global_position, next, 1)).is_empty()
		n.global_position = next
		var done: bool = hit_wall or s.t > 0.8
		for m in smudgies:
			if not m.got and not m.sucking and m.node.global_position.distance_to(n.global_position) < 0.6:
				m.got = true
				m.dead = true
				m.shadow.visible = false
				_poof(m.node)
				_splash(m.node.global_position + Vector3(0, 0.4, 0), Color("8f8a99"))
				smudgie_cleaned.emit()
				done = true
				break
		if done:
			stars.remove_at(i)
			_poof(n)
			star_poofed.emit()


## A Smudgie touching the mochi right now (and ready to bump again), or {}.
func bumping(pos: Vector3) -> Dictionary:
	for m in smudgies:
		if m.got or m.sucking or m.stun > 0.0 or m.bump_cd > 0.0:
			continue
		if m.node.global_position.distance_to(pos) < 0.55:
			m.bump_cd = 1.2
			return m
	return {}


func _update_smudgies(delta: float, player_pos: Vector3) -> void:
	for m in smudgies:
		if m.got or m.sucking:
			continue
		var n: Node3D = m.node
		m.bump_cd = maxf(0.0, m.bump_cd - delta)
		if m.stun > 0.0:  # flipped over, feet wiggling
			m.stun -= delta
			n.rotation.x = lerpf(n.rotation.x, PI, 1.0 - exp(-delta * 10.0))
			n.position.y = m.center.y + 0.25
			continue
		n.rotation.x = lerpf(n.rotation.x, 0.0, 1.0 - exp(-delta * 10.0))
		var c: Vector3 = m.center
		var chase := player_pos.distance_to(n.global_position) < 3.2 and absf(player_pos.y - c.y) < 0.8
		var goal: Vector3 = player_pos if chase else m.target
		var flat := Vector3(goal.x - n.position.x, 0, goal.z - n.position.z)
		if flat.length() < 0.15 and not chase:
			var a := rng.randf() * TAU
			m.target = c + Vector3(cos(a), 0, sin(a)) * rng.randf() * m.roam
		elif flat.length() > 0.01:
			var step := flat.normalized() * (1.1 if chase else 0.6) * delta
			var nxt: Vector3 = n.position + step
			if Vector2(nxt.x - c.x, nxt.z - c.z).length() < m.roam + 0.6:  # stay on their island
				n.position = nxt
			n.rotation.y = lerp_angle(n.rotation.y, atan2(flat.x, flat.z), 1.0 - exp(-delta * 8.0))
		var hop := absf(sin(time * 7.0 + c.x))
		n.position.y = c.y + hop * 0.07
		n.scale = Vector3(1.0 + 0.06 * (1.0 - hop), 1.0 - 0.06 * (1.0 - hop), 1.0)
		m.shadow.position = Vector3(n.position.x, c.y + 0.012, n.position.z)


func _process(delta: float) -> void:
	time += delta
	for e in edibles:
		if e.got or e.sucking or e.kind == "smudgie":
			continue
		var n: Node3D = e.node
		var slow: bool = e.kind in ["seal", "bloom"]
		n.position.y = e.home.y + sin(time * 2.4 + e.home.x) * (0.05 if slow else 0.08)
		n.rotation.y = time * (0.9 if slow else 1.5) + e.home.z
	_update_flutters()
	for s in spinners:
		s.rotation.z += delta * 0.8
	for id in friends:  # friends bob happily; a "!" bounces over anyone still needing help
		var f: Dictionary = friends[id]
		var hop := absf(sin(time * 3.0 + f.home.x))
		f.node.position.y = f.home.y + hop * 0.06
		f.node.scale = Vector3(1.0 + 0.04 * (1.0 - hop), 1.0 - 0.04 * (1.0 - hop), 1.0 + 0.04 * (1.0 - hop))
		f.mark.visible = f.star != "" and not bloom_shown(f.star)
		f.mark.position.y = f.home.y + 1.9 + absf(sin(time * 4.0)) * 0.15
	for c in clouds:
		c.position.x += delta * 0.25
		if c.position.x > 30.0:
			c.position.x = -30.0
