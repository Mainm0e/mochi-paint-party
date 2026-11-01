"""Build a chibi low-poly explorer character, render previews, save .blend and .glb.

Run:  blender --background --factory-startup --python make_explorer.py -- <out_dir>
"""
import math
import os
import sys

import bpy

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.dirname(__file__)
os.makedirs(OUT, exist_ok=True)

# ---------- reset scene ----------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------- helpers ----------
MATS = {}


def mat(name, color, rough=0.55, metal=0.0):
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    MATS[name] = m
    return m


CHAR = bpy.data.objects.new("Explorer", None)
scene.collection.objects.link(CHAR)


def finish(obj, material, bevel=0.0, subdiv=0, smooth=True, parent=None):
    obj.data.materials.append(material)
    if bevel:
        b = obj.modifiers.new("Bevel", "BEVEL")
        b.width = bevel
        b.segments = 2
        b.limit_method = "ANGLE"
    if subdiv:
        s = obj.modifiers.new("Subdiv", "SUBSURF")
        s.levels = subdiv
        s.render_levels = subdiv
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    if smooth:
        try:
            bpy.ops.object.shade_smooth_by_angle(angle=math.radians(50))
        except Exception:
            bpy.ops.object.shade_smooth()
    obj.parent = parent or CHAR
    return obj


def box(name, size, loc, material, bevel=0.015, rot=(0, 0, 0), parent=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    return finish(o, material, bevel=bevel, parent=parent)


def ball(name, radii, loc, material, segs=16, rings=10, rot=(0, 0, 0), parent=None):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=rings, radius=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = radii
    bpy.ops.object.transform_apply(scale=True)
    return finish(o, material, parent=parent)


def cyl(name, r, depth, loc, material, rot=(0, 0, 0), verts=12, scale=(1, 1, 1), bevel=0.01, parent=None):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = scale
    bpy.ops.object.transform_apply(scale=True)
    return finish(o, material, bevel=bevel, parent=parent)


def cone(name, r1, r2, depth, loc, material, verts=12, scale=(1, 1, 1), bevel=0.01, parent=None):
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r1, radius2=r2, depth=depth, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = scale
    bpy.ops.object.transform_apply(scale=True)
    return finish(o, material, bevel=bevel, parent=parent)


def pivot(name, loc, rot):
    e = bpy.data.objects.new(name, None)
    scene.collection.objects.link(e)
    e.location = loc
    e.rotation_euler = rot
    e.parent = CHAR
    return e


# ---------- palette (linear RGB) ----------
SKIN = mat("Skin", (0.90, 0.52, 0.38))
HAIR = mat("Hair", (0.04, 0.16, 0.68), rough=0.35)
TUNIC = mat("Tunic", (0.86, 0.82, 0.72))
PANTS = mat("Pants", (0.05, 0.07, 0.18))
BOOT = mat("Boot", (0.24, 0.11, 0.05))
LEATHER = mat("Leather", (0.17, 0.07, 0.03))
GOLD = mat("Gold", (0.95, 0.62, 0.12), rough=0.3, metal=0.8)
SCARF = mat("Scarf", (0.80, 0.07, 0.09))
EYE = mat("Eye", (0.01, 0.01, 0.015), rough=0.2)
WHITE = mat("White", (1.0, 1.0, 1.0), rough=0.3)
BLUSH = mat("Blush", (0.95, 0.30, 0.30))
PACK = mat("Pack", (0.40, 0.19, 0.07))
BLANKET = mat("Blanket", (0.13, 0.38, 0.14))
STEEL = mat("Steel", (0.70, 0.72, 0.76), rough=0.25, metal=0.7)

# ---------- legs & boots ----------
for side, x in (("L", 0.065), ("R", -0.065)):
    cyl(f"Leg.{side}", 0.045, 0.13, (x, 0, 0.15), PANTS)
    box(f"Boot.{side}", (0.09, 0.14, 0.08), (x, -0.015, 0.04), BOOT, bevel=0.025)
    cyl(f"BootCuff.{side}", 0.056, 0.04, (x, 0, 0.098), BOOT)

# ---------- body ----------
cone("Torso", 0.14, 0.11, 0.22, (0, 0, 0.36), TUNIC, scale=(1.1, 0.85, 1))
cone("TunicSkirt", 0.16, 0.14, 0.07, (0, 0, 0.235), TUNIC, scale=(1.1, 0.85, 1))
cyl("Belt", 0.147, 0.035, (0, 0, 0.285), LEATHER, scale=(1.1, 0.85, 1))
box("Buckle", (0.045, 0.02, 0.04), (0, -0.128, 0.285), GOLD, bevel=0.006)

# scarf
bpy.ops.mesh.primitive_torus_add(major_radius=0.1, minor_radius=0.035, major_segments=16, minor_segments=8,
                                 location=(0, 0, 0.47))
o = bpy.context.active_object
o.name = "Scarf"
o.scale = (1.05, 0.9, 1.0)
bpy.ops.object.transform_apply(scale=True)
finish(o, SCARF)
box("ScarfTail", (0.05, 0.025, 0.12), (0.06, -0.1, 0.4), SCARF, bevel=0.012, rot=(0.15, 0, 0.15))

# arms & hands
for side, sx in (("L", 1), ("R", -1)):
    ball(f"Shoulder.{side}", (0.052, 0.052, 0.052), (sx * 0.15, 0, 0.43), TUNIC)
    cyl(f"Arm.{side}", 0.042, 0.17, (sx * 0.172, 0, 0.35), TUNIC, rot=(0, -sx * 0.3, 0))
    cyl(f"Cuff.{side}", 0.047, 0.03, (sx * 0.193, -0.003, 0.295), LEATHER, rot=(0, -sx * 0.3, 0))
    ball(f"Hand.{side}", (0.05, 0.05, 0.05), (sx * 0.2, -0.01, 0.265), SKIN)

# backpack with bedroll
box("Backpack", (0.2, 0.09, 0.19), (0, 0.13, 0.36), PACK, bevel=0.03)
box("PackFlap", (0.205, 0.095, 0.05), (0, 0.13, 0.44), LEATHER, bevel=0.02)
cyl("Bedroll", 0.045, 0.26, (0, 0.13, 0.5), BLANKET, rot=(0, math.pi / 2, 0))
for side, x in (("L", 0.09), ("R", -0.09)):
    box(f"Strap.{side}", (0.03, 0.02, 0.2), (x, -0.115, 0.38), LEATHER, bevel=0.005)

# satchel on left hip
box("Satchel", (0.05, 0.09, 0.08), (0.165, -0.02, 0.24), PACK, bevel=0.015)

# ---------- head ----------
ball("Head", (0.2, 0.18, 0.19), (0, 0, 0.68), SKIN, segs=20, rings=12)
for side, sx in (("L", 1), ("R", -1)):
    ball(f"Eye.{side}", (0.022, 0.012, 0.032), (sx * 0.07, -0.165, 0.655), EYE)
    ball(f"EyeShine.{side}", (0.008, 0.005, 0.008), (sx * 0.07 - 0.008, -0.177, 0.668), WHITE, segs=8, rings=6)
    ball(f"Blush.{side}", (0.025, 0.008, 0.013), (sx * 0.12, -0.141, 0.61), BLUSH, segs=10, rings=6)
ball("Nose", (0.018, 0.016, 0.016), (0, -0.18, 0.625), SKIN, segs=10, rings=6)
bpy.ops.mesh.primitive_torus_add(major_radius=0.018, minor_radius=0.0045, major_segments=16, minor_segments=6,
                                 location=(0, -0.158, 0.6), rotation=(math.pi / 2 + 0.35, 0, 0))
mouth = bpy.context.active_object
mouth.name = "Mouth"
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="DESELECT")
bpy.ops.object.mode_set(mode="OBJECT")
for v in mouth.data.vertices:  # keep only the lower half of the ring -> a smile
    v.select = v.co.y > -0.002
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.delete(type="VERT")
bpy.ops.object.mode_set(mode="OBJECT")
finish(mouth, EYE)

# hair: cap, bangs, side locks, ponytail
ball("HairCap", (0.215, 0.2, 0.19), (0, 0.03, 0.72), HAIR, segs=20, rings=12)
for i, (x, z, h) in enumerate(((-0.15, 0.73, 0.12), (-0.08, 0.75, 0.11), (-0.005, 0.755, 0.12),
                               (0.07, 0.75, 0.1), (0.14, 0.735, 0.11))):
    tuft = pivot(f"BangPivot.{i}", (x, -0.15 + abs(x) * 0.35, z), (math.pi - 0.3, x * 2.2, 0))
    cone(f"Bang.{i}", 0.05, 0.0, h, (0, 0, h / 2 - 0.03), HAIR, verts=8, scale=(1, 0.6, 1), bevel=0.0, parent=tuft)
for side, sx in (("L", 1), ("R", -1)):
    ball(f"SideLock.{side}", (0.042, 0.05, 0.1), (sx * 0.19, -0.05, 0.6), HAIR, segs=10, rings=8)
cyl("HairTie", 0.045, 0.03, (0, 0.225, 0.69), GOLD, rot=(1.2, 0, 0), verts=12)
ball("Ponytail", (0.07, 0.075, 0.13), (0, 0.28, 0.6), HAIR, segs=12, rings=8, rot=(-0.45, 0, 0))

# checkered hair clip
clip = pivot("HairClip", (0.155, -0.105, 0.78), (0, -0.25, -0.65))
for i, (dx, dz) in enumerate(((0, 0), (0.022, 0), (0, 0.022), (0.022, 0.022))):
    m = EYE if i in (0, 3) else WHITE
    box(f"Clip.{i}", (0.022, 0.012, 0.022), (dx - 0.011, 0, dz - 0.011), m, bevel=0.003, parent=clip)

# ---------- short sword in right hand ----------
sword = pivot("Sword", (-0.2, -0.04, 0.265), (0.35, 0, 0.0))
cyl("Grip", 0.015, 0.09, (0, 0, 0), LEATHER, verts=8, parent=sword)
box("Guard", (0.1, 0.03, 0.022), (0, 0, 0.05), GOLD, bevel=0.006, parent=sword)
box("Blade", (0.045, 0.012, 0.22), (0, 0, 0.17), STEEL, bevel=0.006, parent=sword)
cone("BladeTip", 0.032, 0.0, 0.05, (0, 0, 0.305), STEEL, verts=4, scale=(0.7, 0.19, 1), bevel=0.0, parent=sword)
ball("Pommel", (0.02, 0.02, 0.02), (0, 0, -0.05), GOLD, segs=10, rings=6, parent=sword)

# ---------- stage: ground, lights, camera ----------
bpy.ops.mesh.primitive_circle_add(vertices=48, radius=0.45, fill_type="NGON", location=(0, 0, 0))
ground = bpy.context.active_object
ground.name = "Ground"
ground.data.materials.append(mat("GroundMat", (0.35, 0.62, 0.30), rough=0.9))

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.62, 0.78, 1)
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.9

sun_data = bpy.data.lights.new("Sun", "SUN")
sun_data.energy = 3.5
sun_data.angle = math.radians(8)
sun = bpy.data.objects.new("Sun", sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler = (math.radians(50), 0, math.radians(-35))

rim_data = bpy.data.lights.new("Rim", "AREA")
rim_data.energy = 60
rim_data.size = 1.0
rim = bpy.data.objects.new("Rim", rim_data)
scene.collection.objects.link(rim)
rim.location = (-0.8, 1.2, 1.3)
rim.rotation_euler = (math.radians(-55), 0, math.radians(-145))

target = bpy.data.objects.new("CamTarget", None)
scene.collection.objects.link(target)
target.location = (0, 0, 0.47)

cam_data = bpy.data.cameras.new("Camera")
cam_data.lens = 50
cam = bpy.data.objects.new("Camera", cam_data)
scene.collection.objects.link(cam)
track = cam.constraints.new("TRACK_TO")
track.target = target
track.track_axis = "TRACK_NEGATIVE_Z"
track.up_axis = "UP_Y"
scene.camera = cam

# ---------- render settings ----------
engines = bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items.keys()
for e in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
    if e in engines:
        scene.render.engine = e
        break
if scene.render.engine == "CYCLES":
    scene.cycles.samples = 64
scene.render.resolution_x = 1024
scene.render.resolution_y = 1024
try:
    scene.view_settings.view_transform = "Standard"
except TypeError:
    pass

shots = {
    "explorer_3q.png": (0.75, -1.55, 0.72),
    "explorer_front.png": (0.0, -1.7, 0.6),
    "explorer_back.png": (-0.9, 1.45, 0.75),
}
for name, loc in shots.items():
    cam.location = loc
    scene.render.filepath = os.path.join(OUT, name)
    bpy.ops.render.render(write_still=True)

# ---------- save ----------
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "explorer.blend"))

bpy.ops.object.select_all(action="DESELECT")
for o in scene.objects:
    if o.type == "MESH" and o.name != "Ground":
        o.select_set(True)
CHAR.select_set(True)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "explorer.glb"), use_selection=True,
                          export_apply=True)
print("DONE", scene.render.engine)
