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

const REACH := 1.7             # how close something edible must be for the mochi to start inhaling it
const PAPER := Color("f8f6f0")
const WHITE := Color.WHITE
const ISLAND_DEPTH := 0.9
const PAGES := {"meadow1": "Meadow 1"}

var level := ""
var edibles: Array[Dictionary] = []      # kind: drop | power | sticker | smudgie | seal
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


# ================================================================== loading
## Build `name` ("home" or a page id). `eaten` lists edible ids already eaten on this page (they stay gone).
func load_level(name: String, eaten: Array = []) -> void:
	for c in get_children():
		c.queue_free()
	for list in [edibles, drops, smudgies, checkpoints, zones, paintables, clouds, switches, stars]:
		list.clear()
	active_checkpoint = 0
	level = name
	rng.seed = hash(name)
	_build_void()
	if name == "home":
		_build_home()
	elif name == "worldmap":
		_build_worldmap()
	else:
		_build_meadow1()
	for e in edibles:
		if e.id in eaten and e.kind in ["drop", "sticker"]:
			collect(e, true)


func spawn_point() -> Vector3:
	return checkpoints[active_checkpoint].pos + Vector3(0, 0.3, 0)


func page_name() -> String:
	return PAGES.get(level, "Home Page")


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
	zone("book", Vector3(0, 0, -1.6), 1.4, "E  Open the book: Meadow 1")
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
func _build_meadow1() -> void:
	# A: start
	island(0, 0, 8, 8, 0)
	checkpoint(Vector3(0, 0, 2.5))
	_tree(Vector3(-3.0, 0, 2.6))
	_tree(Vector3(3.2, 0, -2.8), 1.2)
	place(pencil(), Vector3(-2.2, 0, -1.4), 1.0, 0.0, -0.5, _box_shape(Vector3(4.6, 0.6, 0.6)), Vector3(0, 0.3, 0))
	_scatter(flower, Vector3(-1.5, 0, -1.5), 2.0, 16)
	paint_drop("d1", Vector3(1.6, 0, -1.8), "ffd86b")
	sticker("s1", Vector3(-3.3, 0, 3.4))  # tucked behind the first tree
	# B, C: little hops
	island(0, -7.5, 4, 4, 0)
	paint_drop("d2", Vector3(0, 0, -7.5), "ff9ab5")
	island(2.2, -12, 3, 3, 0.45)
	paint_drop("d3", Vector3(2.2, 0.45, -12), "b9a2ee")
	# D: Smudgies and the cloud
	island(0, -18.5, 8, 6, 0)
	checkpoint(Vector3(-2.5, 0, -16.3))
	power_doodle("puffy", Vector3(2.6, 0, -19.6))
	smudgie("m1", Vector3(-1.5, 0, -19.5), 1.6)
	smudgie("m2", Vector3(1.0, 0, -17.5), 1.4)
	paint_drop("d4", Vector3(-3.0, 0, -20.6), "8fd0f5")
	paint_drop("d5", Vector3(3.0, 0, -16.4), "a8d8a0")
	_scatter(mushroom, Vector3(-3.0, 0, -20.6), 0.9, 4)
	sticker("s2", Vector3(-3.5, 0, -21.1))  # behind the mushrooms
	_tree(Vector3(3.4, 0, -21.0), 0.9)
	# glide gap -> E: the pebble, the switch and the bridge
	island(0, -31.5, 7, 8, -0.6)
	checkpoint(Vector3(0, -0.6, -28.6))
	power_doodle("stone", Vector3(-2.3, -0.6, -31.0))
	paint_drop("d6", Vector3(0.6, -0.6, -32.2), "e88f8f")
	_scatter(rock, Vector3(2.4, -0.6, -29.5), 0.8, 3, 0.6, 1.0)
	island(7.4, -31.5, 2, 2, -0.2, "f6e3b4")  # a side islet only a glide reaches
	sticker("s3", Vector3(7.4, -0.2, -31.5))
	var br := bridge(0, -38.0, 5.0, -0.6)
	br.position.y -= 4.0  # starts sunk below; the switch raises it
	switch(Vector3(2.0, -0.6, -34.6), br, br.position.y + 4.0)
	# F: more Smudgies, a pillar sticker
	island(0, -44, 7, 7, -0.6)
	checkpoint(Vector3(0, -0.6, -41.4))
	smudgie("m3", Vector3(-1.8, -0.6, -44.0), 1.6)
	smudgie("m4", Vector3(1.8, -0.6, -45.0), 1.6)
	smudgie("m5", Vector3(0.2, -0.6, -42.6), 1.2)
	paint_drop("d7", Vector3(-2.5, -0.6, -42.2), "f5c35b")
	paint_drop("d8", Vector3(2.6, -0.6, -46.4), "9fd0b4")
	island(-2.8, -46.0, 1.0, 1.0, 0.35, "e3e6ef")  # a pillar: double jump up
	sticker("s4", Vector3(-2.8, 0.35, -46.0))
	place(house(), Vector3(2.9, -0.6, -42.0), 0.8, 2.0, -0.6, _box_shape(Vector3(1.6, 1.4, 1.3)), Vector3(0, 0.7, 0))
	# G: the ledge with the Paint Seal
	island(0, -50.5, 4, 4, 0.3)
	paint_seal(Vector3(0, 0.3, -51.2))
	sticker("s5", Vector3(1.5, 0.3, -52.1))  # peek behind the seal
	_tree(Vector3(-1.4, 0.3, -52.0), 0.8)


# ================================================================== world map (concept diorama)
## The whole book as one map: an open sketchbook whose two pages hold the four chapter regions,
## linked by dotted ink paths between level stamps, the Eraser's castle beyond the top edge and a
## giant Ink Bloom in the middle. Built for concept renders (`-- --worldmap=<dir>`).
func _build_worldmap() -> void:
	var top := 0.3
	# the open book: cover, page stack, two pages, the crease
	var cover := doodle(_box(46, 0.5, 29), "b8665f", Vector3(0, -0.55, 0), 0.06, true)
	add_child(cover)
	add_child(doodle(_box(44.5, 0.5, 27.4), "f3ead8", Vector3(0, -0.15, 0), 0.04, true))
	island(-11.1, 0, 21.8, 26.6, top, "fbf5e6", 0.4)
	island(11.1, 0, 21.8, 26.6, top, "fbf5e6", 0.4)
	add_child(doodle(_box(0.25, 0.05, 26.6), "d8cdb6", Vector3(0, top + 0.01, 0), 0.0, true))
	var y := top
	for h in [[-14.8, 7.2, 2.0], [-20.2, 4.2, 1.5], [-4.6, 12.0, 1.3], [-14.0, 1.6, 1.4], [-3.8, 5.0, 1.5]]:
		var hill := doodle(_sphere(h[2], 18, 10, true), "a9dd8f", Vector3(h[0], y, h[1]), 0.05)
		hill.scale = Vector3(1.0, 0.38, 1.0)
		add_child(hill)
	for p in [[-20.3, 8.0], [-16.5, 4.0], [-5.0, 2.4], [-10.5, 6.2], [-2.6, 11.8]]:
		place(tree(), Vector3(p[0], y, p[1]), 1.1, 1.6)
	_scatter(flower, Vector3(-12, y, 9.5), 3.5, 40, 1.4, 2.0)
	_scatter(mushroom, Vector3(-7, y, 4), 1.3, 5, 1.4, 2.0)
	# --- Chapter 2, Village (back left): little houses, fences, a windmill
	for h in [[-16, -4, 0.3], [-13, -2.5, -0.2], [-9.5, -4.5, 0.4], [-15, -8.5, -0.5], [-8, -9, 0.2]]:
		place(house(), Vector3(h[0], y, h[1]), 1.2, 2.4, h[2])
	var mill := Node3D.new()
	mill.add_child(doodle(_cyl(0.6, 0.9, 3.0, 10), "f7d9b0", Vector3(0, 1.5, 0), 0.04))
	mill.add_child(doodle(_cyl(0.0, 1.0, 0.9, 10), "e88f8f", Vector3(0, 3.4, 0), 0.04))
	for k in 4:
		var blade := doodle(_box(0.35, 2.4, 0.08), "fffaf0", Vector3(0, 2.9, 0.75), 0.03, true)
		blade.rotation.z = k * PI / 2.0 + 0.3
		blade.position += Vector3(cos(k * PI / 2.0 + 0.3 + PI / 2.0), sin(k * PI / 2.0 + 0.3 + PI / 2.0), 0) * 1.1
		mill.add_child(blade)
	place(mill, Vector3(-19, y, -9.5), 1.0, 2.2, 0.3)
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
	place(light, Vector3(15, y + 0.4, 9), 1.0, 1.4, 0.0)
	for b in 14:
		add_child(colored(_sphere(rng.randf_range(0.18, 0.45)), "dff3ff",
			Vector3(rng.randf_range(6, 18), y + rng.randf_range(0.6, 3.0), rng.randf_range(3, 12)), 0.02, 0.4))
	place(tree(), Vector3(8, y + 0.4, 6), 0.8, 1.0)
	# --- Chapter 4, Snowy Notebook (back right): snowy mounds, pines, ice crystals
	for h in [[8, -5, 2.6], [15, -3.5, 2.2], [12, -9.5, 3.0], [18, -9, 1.8]]:
		var mound := doodle(_sphere(h[2], 18, 10, true), "f4f8ff", Vector3(h[0], y, h[1]), 0.05)
		mound.scale = Vector3(1.0, 0.5, 1.0)
		add_child(mound)
	for p in [[6, -2, 1.0], [10, -3, 1.3], [17.5, -5.5, 1.1], [7, -10, 1.2], [15.5, -11, 1.0], [19.5, -2.5, 0.9]]:
		var pine := Node3D.new()
		pine.add_child(doodle(_cyl(0.1, 0.14, 0.6, 8), "c99a6a", Vector3(0, 0.3, 0), 0.02))
		for k in 3:
			pine.add_child(doodle(_cyl(0.0, 0.9 - k * 0.2, 0.9, 9), "6fae8c", Vector3(0, 0.9 + k * 0.55, 0), 0.03))
		pine.add_child(doodle(_cyl(0.0, 0.32, 0.35, 9), "ffffff", Vector3(0, 2.35, 0), 0.02))
		place(pine, Vector3(p[0], y, p[1]), p[2], 1.4)
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
		var st := colored(_star_mesh(0.3, 0.12, 0.05), "ffe07a", Vector3(cos(a) * 2.6, 3.0 + sin(a * 2.0) * 0.8, sin(a) * 2.6), 0.02, 0.3)
		bloom.add_child(st)
	place(bloom, Vector3(0, y, 1.5), 1.3, 3.0, 0.0)
	# --- level stamps joined by dotted ink paths, in play order
	var nodes := [
		["1-1", -18, 10.5, "ff9ab5"], ["1-2", -12.5, 12.0, "ff9ab5"], ["1-3", -7.5, 9.0, "ff9ab5"], ["1-E", -9.5, 3.0, "26232b"],
		["2-1", -17.0, -1.5, "f5c35b"], ["2-2", -11.5, -6.5, "f5c35b"], ["2-3", -6.0, -7.0, "f5c35b"], ["2-E", -12.5, -11.0, "26232b"],
		["3-1", 5.5, 11.5, "7fb5ec"], ["3-2", 10.5, 11.8, "7fb5ec"], ["3-3", 18.5, 11.0, "7fb5ec"], ["3-E", 18.0, 2.5, "26232b"],
		["4-1", 5.5, -6.5, "a585e0"], ["4-2", 11.0, -6.8, "a585e0"], ["4-3", 16.0, -12.0, "a585e0"], ["4-E", 6.0, -11.5, "26232b"],
	]
	var prev := Vector3.INF
	for n in nodes:
		var pos := Vector3(n[1], y, n[2])
		var stamp := colored(_cyl(0.75, 0.85, 0.3, 24), n[3], pos + Vector3(0, 0.15, 0), 0.04, 0.15)
		add_child(stamp)
		var label := Label3D.new()
		label.text = n[0]
		label.font = _ui_font()
		label.font_size = 96
		label.pixel_size = 0.008
		label.modulate = Color("1f1d24")
		label.outline_modulate = Color.WHITE
		label.outline_size = 18
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position = pos + Vector3(0, 1.3, 0)
		add_child(label)
		if prev != Vector3.INF:
			var d: float = prev.distance_to(pos)
			var steps := int(d / 0.7)
			for k in range(1, steps):
				var t := float(k) / steps
				var p: Vector3 = prev.lerp(pos, t) + Vector3(0, 0.05 + sin(t * PI) * 0.0, sin(t * PI * 2.0) * 0.4)
				add_child(colored(_sphere(0.11, 8, 5), "1f1d24", p, 0.0, 0.0))
		prev = pos
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
	checkpoint(Vector3(-18, y, 12.6))
	checkpoints[0].node.visible = false
	_paint_all(true)


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
	var s := clampf(dist / REACH * 1.3, 0.3, 1.0) * (1.6 if e.kind == "seal" else 1.0)
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
		n.position.y = e.home.y + sin(time * 2.4 + e.home.x) * (0.05 if e.kind == "seal" else 0.08)
		n.rotation.y = time * (0.6 if e.kind == "seal" else 1.5) + e.home.z
	for c in clouds:
		c.position.x += delta * 0.25
		if c.position.x > 30.0:
			c.position.x = -30.0
