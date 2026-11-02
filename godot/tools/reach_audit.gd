extends SceneTree
## Reachability audit: can a real player get to every star, sticker, lost item, power doodle and switch?
##   godot --headless --path godot -s res://tools/reach_audit.gd -- [page ...]
## Builds each page, samples every standable surface on a grid (ray casts), then floods outward from the start
## the way the mochi can actually move: walking and stepping, single/double/sprint jumps, and, once their
## doodle pedestal has been reached, Boing hops, Puffy glides, Sketch bridges, Bubble water-walking, and
## bouncy mushrooms. Jump distances come from simulating the mochi's own numbers (speed, gravity, jump).
## End-of-page toggles are applied first (switch bridges raised, cages sunk, ice melted, night on, low tide),
## and hidden stars are shown. A target counts when the mochi could stand within eating reach of it.

const GRID := 0.5
const STEP_UP := 0.35         # what walking climbs on its own
const SLACK := 0.55           # capsule radius + half a grid cell: jumping edge to edge, not centre to centre
const PAGES := ["meadow", "village", "seaside", "snowy", "castle"]

var main: Node
var tables := {}              # profile -> PackedFloat32Array of max reach per dy (index = (dy + 14) * 10)


func _init() -> void:
	var pages: Array = Array(OS.get_cmdline_user_args()).filter(func(a): return a in PAGES)
	if pages.is_empty():
		pages = PAGES
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_run.json"))  # audit a fresh game
	main = load("res://scenes/main.tscn").instantiate()
	main.save_path = "user://test_run.json"
	root.add_child(main)
	await create_timer(0.3).timeout
	for p in ["base", "stone", "boing", "puffy", "bounce"]:
		tables[p] = _reach_table(p)
	var problems := 0
	for page in pages:
		problems += await _audit(page)
	print("AUDIT DONE: %d unreachable" % problems)
	quit()


# ------------------------------------------------------------------ jump physics (mirrors mochi.gd)
func _reach_table(profile: String) -> PackedFloat32Array:
	var t := PackedFloat32Array()
	t.resize(200)
	t.fill(-1.0)
	var vy: float = {"base": 3.6, "stone": 3.6 * 0.85, "boing": 3.6 * 1.75, "puffy": 3.6, "bounce": 9.0}[profile]
	var double_ok := profile != "stone"
	var glide := profile == "puffy"
	var dt := 1.0 / 240.0
	var y := 0.0
	var x := 0.0
	var vh := 2.6 * 1.7  # leaving the ground at a sprint
	var used_double := false
	var prev_y := 0.0
	for i in 2400:  # up to 10 s of flight
		var target := 3.3 if glide and vy < 0.0 else 2.6
		vh += (target - vh) * (1.0 - exp(-4.0 * dt))
		vy += -11.0 * dt
		if double_ok and not used_double and vy <= 0.0:  # second hop right at the top
			vy = 3.6 * 0.95
			used_double = true
		if glide and used_double and vy < -0.7:
			vy = -0.7
		prev_y = y
		y += vy * dt
		x += vh * dt
		if y < prev_y:  # coming down: every height we pass on the way down is reachable this far out
			var idx := int(round((y + 14.0) * 10.0))
			if idx >= 0 and idx < 200:
				t[idx] = maxf(t[idx], x)
		if y < -14.0:
			break
	# a landing spot higher up can also be reached on the way up, closer in; fill gaps by carrying the best
	for idx in range(198, -1, -1):
		if t[idx] < 0.0 and t[idx + 1] >= 0.0 and (idx / 10.0 - 14.0) < 0.0:
			t[idx] = t[idx + 1]
	return t


func _reach(profile: String, dy: float) -> float:
	var idx := int(round((dy + 14.0) * 10.0))
	if idx < 0:
		return tables[profile][0]
	if idx >= 200:
		return -1.0
	return tables[profile][idx]


# ------------------------------------------------------------------ one page
func _audit(page: String) -> int:
	main.enter_level(page)
	main.set_mode(2)
	var w = main.world
	await create_timer(0.5).timeout
	# the page as it is once everything has been done
	for s in w.switches:
		s.bridge.position.y = s.raised_y
	for b in w.meltables:
		b.queue_free()
	w.meltables.clear()
	if page == "snowy":
		w.set_night(true)
	if not w.tide.is_empty():
		w.tide.t = w.TIDE_HOLD + w.TIDE_TURN + 1.0  # low tide (the sand bar and reef are out)
	for e in w.edibles:
		if e.kind == "bloom" and not e.node.visible:
			e.node.visible = true
	await create_timer(0.6).timeout
	for i in 3:
		await physics_frame
	var space: PhysicsDirectSpaceState3D = w.get_world_3d().direct_space_state
	# --- sample standable surfaces
	var lo := Vector2(-34, -34)
	var hi := Vector2(34, 32)
	if page == "meadow":
		lo.y = -92
	if page == "castle":
		lo.y = -56
	var cells: Array = []        # [Vector3, water(bool), bouncy(bool)]
	var buckets := {}            # Vector2i -> [cell index]
	var x := lo.x
	while x <= hi.x:
		var z := lo.y
		while z <= hi.y:
			for water in [false, true]:
				var from := Vector3(x, 24.0, z)
				for k in 8:  # several floors stacked at one spot
					var q := PhysicsRayQueryParameters3D.create(from, Vector3(x, -8.0, z), 4 if water else 1)
					var hit := space.intersect_ray(q)
					if hit.is_empty():
						break
					var p: Vector3 = hit.position
					if hit.normal.y > 0.6:
						var up := PhysicsRayQueryParameters3D.create(p + Vector3(0, 0.05, 0), p + Vector3(0, 0.75, 0), 1)
						if space.intersect_ray(up).is_empty():  # room for the mochi to stand
							var bouncy: bool = w.bouncy_at(p)
							var ci := cells.size()
							cells.append([p, water, bouncy])
							var key := Vector2i(floori(p.x), floori(p.z))
							if not buckets.has(key):
								buckets[key] = []
							buckets[key].append(ci)
					from = p - Vector3(0, 0.06, 0)
					if water:
						break
			z += GRID
		x += GRID
	# --- flood out from the start, adding powers as their pedestals are reached
	var start: Vector3 = w.checkpoints[0].pos
	var powers := {}
	var pedestals := {}
	for e in w.edibles:
		if e.kind == "power":
			pedestals[e.power] = e.home
	var reached := PackedByteArray()
	reached.resize(cells.size())
	var frontier: Array = []
	for i in cells.size():
		var p: Vector3 = cells[i][0]
		if not cells[i][1] and p.distance_to(start) < 1.2:
			reached[i] = 1
			frontier.append(i)
	var changed := true
	while changed:
		changed = false
		while not frontier.is_empty():
			var i: int = frontier.pop_back()
			var a: Vector3 = cells[i][0]
			for j in _neighbours(a, buckets, 11 if "sketch" in powers else 6):
				if reached[j]:
					continue
				if cells[j][1] and not "bubble" in powers:
					continue
				if _can_move(space, a, cells[j][0], powers, cells[i][2]):
					reached[j] = 1
					frontier.append(j)
		for pw in pedestals:  # a pedestal in reach gives its power: flood again with it
			if powers.has(pw):
				continue
			if _target_reached(pedestals[pw], cells, reached, buckets):
				powers[pw] = true
				changed = true
				for i in cells.size():
					if reached[i]:
						frontier.append(i)
	# --- report
	var bad := 0
	var lines: Array = []
	var targets: Array = []
	for e in w.edibles:
		if e.kind in ["bloom", "sticker", "item", "power"]:
			targets.append([e.kind, e.id, e.home])
	for s in w.switches:
		targets.append(["switch", "switch", s.pos + Vector3(0, 0.9, 0)])
	for id in w.friends:
		targets.append(["friend", id, w.friends[id].home + Vector3(0, 0.9, 0)])
	for t in targets:
		var ok := _target_reached(t[2], cells, reached, buckets)
		if not ok and powers.has("sketch"):  # out over a gap: stand on a sketched bridge next to it
			ok = _near_reached(t[2], cells, reached, buckets, 5.5)
		if not ok:
			bad += 1
			lines.append("  UNREACHABLE %-7s %-10s at (%.1f, %.1f, %.1f)" % [t[0], t[1], t[2].x, t[2].y, t[2].z])
	var n_reached := 0
	for r in reached:
		n_reached += r
	print("AUDIT %s: %d surfaces sampled, %d reached, powers gained %s, %d/%d targets reachable" % [
		page, cells.size(), n_reached, powers.keys(), targets.size() - bad, targets.size()])
	for l in lines:
		print(l)
	return bad


func _neighbours(a: Vector3, buckets: Dictionary, r: int) -> Array:
	var out: Array = []
	var cx := floori(a.x)
	var cz := floori(a.z)
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var key := Vector2i(cx + dx, cz + dz)
			if buckets.has(key):
				out.append_array(buckets[key])
	return out


## Could the mochi get from standing at a to standing at b in one move?
func _can_move(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, powers: Dictionary, on_bouncer: bool) -> bool:
	var d := Vector2(b.x - a.x, b.z - a.z).length()
	var dy := b.y - a.y
	if d <= GRID * 1.5 + 0.01 and dy <= STEP_UP:  # walk (or step down off a ledge)
		return dy > -0.5 or _clear(space, a, b)
	var best := _reach("base", dy)
	for p in ["stone", "boing", "puffy"]:
		if powers.has(p):
			best = maxf(best, _reach(p, dy))
	if on_bouncer:
		best = maxf(best, _reach("bounce", dy))
	if powers.has("sketch") and dy <= 1.1:  # two 5 m bridges at foot height, then a hop
		best = maxf(best, 10.0 + maxf(_reach("base", dy), 0.0))
	if best < 0.0 or d > best + SLACK:
		return false
	return _clear(space, a, b)


## Nothing solid in the way (checked a little above the feet, and over the top for upward jumps).
func _clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	var top := maxf(a.y, b.y) + 0.5
	for pair in [[a + Vector3(0, 0.4, 0), Vector3(a.x, top, a.z)], [Vector3(a.x, top, a.z), Vector3(b.x, top, b.z)],
			[Vector3(b.x, top, b.z), b + Vector3(0, 0.4, 0)]]:
		var q := PhysicsRayQueryParameters3D.create(pair[0], pair[1], 1)
		if not space.intersect_ray(q).is_empty():
			return false
	return true


func _target_reached(pos: Vector3, cells: Array, reached: PackedByteArray, buckets: Dictionary) -> bool:
	for j in _neighbours(pos, buckets, 2):
		if reached[j] and not cells[j][1] or reached[j]:
			var p: Vector3 = cells[j][0]
			if Vector2(p.x - pos.x, p.z - pos.z).length() < 1.6 and absf(pos.y - p.y) < 1.55:
				return true
	return false


## A reached spot at about the same height within `r` metres (for targets over gaps a bridge can span).
func _near_reached(pos: Vector3, cells: Array, reached: PackedByteArray, buckets: Dictionary, r: float) -> bool:
	for j in _neighbours(pos, buckets, ceili(r)):
		if reached[j]:
			var p: Vector3 = cells[j][0]
			if Vector2(p.x - pos.x, p.z - pos.z).length() < r and pos.y - p.y > -0.3 and pos.y - p.y < 1.55:
				return true
	return false
