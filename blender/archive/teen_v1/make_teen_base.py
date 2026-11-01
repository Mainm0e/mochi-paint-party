"""Rigged, modular chibi teen-girl base character.

Each slot (Body, Face, Eyes, Hair, Top, Bottom, Socks, Shoes) is its own mesh, skinned to one
shared armature, so slots can be swapped for new hairstyles, eyes and outfits later.

Run:  blender --background --factory-startup --python make_teen_base.py -- <out_dir>
"""
import math
import os
import sys
from collections import defaultdict

import bpy
from mathutils import Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.dirname(__file__)
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = 30

# ---------------------------------------------------------------- materials
MATS = {}


def mat(name, color, rough=0.55, metal=0.0):
    if name not in MATS:
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        bsdf = m.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = (*color, 1.0)
        bsdf.inputs["Roughness"].default_value = rough
        bsdf.inputs["Metallic"].default_value = metal
        MATS[name] = m
    return MATS[name]


SKIN = mat("Skin", (0.92, 0.60, 0.46))
SUIT = mat("BaseSuit", (0.42, 0.42, 0.46), rough=0.7)
SCLERA = mat("EyeWhite", (0.95, 0.95, 0.97), rough=0.3)
IRIS = mat("EyeIris", (0.05, 0.25, 0.60), rough=0.2)
PUPIL = mat("EyePupil", (0.01, 0.01, 0.02), rough=0.2)
SHINE = mat("EyeShine", (1.0, 1.0, 1.0), rough=0.1)
LASH = mat("Lash", (0.04, 0.02, 0.02), rough=0.4)
BLUSH = mat("Blush", (0.95, 0.32, 0.32))
HAIR = mat("Hair", (0.07, 0.035, 0.02), rough=0.35)
TOP = mat("TopLilac", (0.55, 0.42, 0.88))
TOP_TRIM = mat("TopTrim", (0.95, 0.92, 0.98))
SKIRT = mat("SkirtNavy", (0.04, 0.06, 0.20))
SOCK = mat("Sock", (0.95, 0.95, 0.95), rough=0.7)
SHOE = mat("ShoeWhite", (0.92, 0.92, 0.94), rough=0.45)
SOLE = mat("ShoeSole", (0.85, 0.25, 0.35), rough=0.6)

# ---------------------------------------------------------------- skeleton
# name: (head, tail, parent)   character faces -Y, Z up, ~1 unit tall
BONES = {
    "root": ((0, 0, 0), (0, 0, 0.1), None),
    "hips": ((0, 0, 0.27), (0, 0, 0.33), "root"),
    "spine": ((0, 0, 0.33), (0, 0, 0.41), "hips"),
    "chest": ((0, 0, 0.41), (0, 0, 0.49), "spine"),
    "neck": ((0, 0, 0.49), (0, 0, 0.54), "chest"),
    "head": ((0, 0, 0.54), (0, 0, 0.9), "neck"),
}
for s, sx in (("L", 1), ("R", -1)):
    BONES.update({
        f"upper_arm.{s}": ((sx * 0.115, 0, 0.47), (sx * 0.18, 0, 0.39), "chest"),
        f"forearm.{s}": ((sx * 0.18, 0, 0.39), (sx * 0.225, 0, 0.31), f"upper_arm.{s}"),
        f"hand.{s}": ((sx * 0.225, 0, 0.31), (sx * 0.245, -0.005, 0.255), f"forearm.{s}"),
        f"thigh.{s}": ((sx * 0.062, 0, 0.28), (sx * 0.065, 0, 0.16), "hips"),
        f"shin.{s}": ((sx * 0.065, 0, 0.16), (sx * 0.065, 0, 0.055), f"thigh.{s}"),
        f"foot.{s}": ((sx * 0.065, 0, 0.055), (sx * 0.065, -0.075, 0.03), f"shin.{s}"),
    })

arm_data = bpy.data.armatures.new("TeenRig")
rig = bpy.data.objects.new("TeenRig", arm_data)
scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
for name, (h, t, parent) in BONES.items():
    eb = arm_data.edit_bones.new(name)
    eb.head, eb.tail = h, t
    if parent:
        eb.parent = arm_data.edit_bones[parent]
        eb.use_connect = tuple(arm_data.edit_bones[parent].tail) == tuple(h)
bpy.ops.object.mode_set(mode="OBJECT")
arm_data.display_type = "STICK"
rig.show_in_front = True

# ---------------------------------------------------------------- mesh helpers
SLOTS = defaultdict(list)


def activate(o):
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    bpy.context.view_layer.objects.active = o


def part(o, slot, bone, material, bevel=0.0, smooth_angle=50):
    """Bake modifiers + transforms, smooth, and weight every vertex to one bone."""
    activate(o)
    o.data.materials.append(material)
    if bevel:
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width, b.segments, b.limit_method = bevel, 2, "ANGLE"
        bpy.ops.object.modifier_apply(modifier=b.name)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(smooth_angle))
    except Exception:
        bpy.ops.object.shade_smooth()
    vg = o.vertex_groups.new(name=bone)
    vg.add(range(len(o.data.vertices)), 1.0, "REPLACE")
    SLOTS[slot].append(o)
    return o


def ball(slot, bone, material, radii, loc, segs=16, rings=10, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=rings, radius=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.scale = radii
    return part(o, slot, bone, material)


def box(slot, bone, material, size, loc, rot=(0, 0, 0), bevel=0.01):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.scale = size
    return part(o, slot, bone, material, bevel=bevel)


def tube(slot, bone, material, r1, r2, z0, z1, sy=1.0, sx=1.0, verts=14, smooth_angle=50, x=0.0):
    """Vertical tapered tube from z0 (radius r1) to z1 (radius r2), centred on x."""
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r1, radius2=r2, depth=z1 - z0,
                                    location=(x, 0, (z0 + z1) / 2))
    o = bpy.context.active_object
    o.scale = (sx, sy, 1)
    return part(o, slot, bone, material, smooth_angle=smooth_angle)


def between(slot, bone, material, p0, p1, r0, r1, verts=12, flat_y=1.0, caps=True):
    """Tapered limb/tuft from p0 to p1, optional joint sphere at p0."""
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r0, radius2=r1, depth=d.length,
                                    location=(0, 0, d.length / 2))
    o = bpy.context.active_object
    o.scale = (1, flat_y, 1)
    activate(o)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    o.matrix_world = Matrix.Translation(p0) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
    part(o, slot, bone, material)
    if caps:
        ball(slot, bone, material, (r0, r0, r0), tuple(p0), segs=12, rings=8)
    return o


def bone_pts(name):
    h, t, _ = BONES[name]
    return h, t


# ---------------------------------------------------------------- BODY (neutral bodysuit base)
ball("Body", "head", SKIN, (0.2, 0.185, 0.19), (0, 0, 0.72), segs=24, rings=14)
for s, sx in (("L", 1), ("R", -1)):
    ball("Body", "head", SKIN, (0.025, 0.02, 0.04), (sx * 0.195, 0.0, 0.69), segs=10, rings=6)
tube("Body", "neck", SKIN, 0.038, 0.036, 0.47, 0.57)
tube("Body", "chest", SUIT, 0.105, 0.095, 0.41, 0.5, sy=0.8)
tube("Body", "spine", SUIT, 0.092, 0.105, 0.33, 0.415, sy=0.8)
ball("Body", "hips", SUIT, (0.112, 0.088, 0.075), (0, 0, 0.3))
for s, sx in (("L", 1), ("R", -1)):
    ball("Body", "chest", SUIT, (0.04, 0.04, 0.04), (sx * 0.115, 0, 0.47))
    h, t = bone_pts(f"upper_arm.{s}")
    between("Body", f"upper_arm.{s}", SKIN, h, t, 0.032, 0.029, caps=False)
    h, t = bone_pts(f"forearm.{s}")
    between("Body", f"forearm.{s}", SKIN, h, t, 0.029, 0.026)
    h, t = bone_pts(f"hand.{s}")
    ball("Body", f"hand.{s}", SKIN, (0.032, 0.024, 0.042),
         tuple((Vector(h) + Vector(t)) / 2), rot=(0, -sx * 0.35, 0))
    ball("Body", f"hand.{s}", SKIN, (0.012, 0.012, 0.018),
         (sx * 0.222, -0.022, 0.285), segs=8, rings=6)
    h, t = bone_pts(f"thigh.{s}")
    between("Body", f"thigh.{s}", SUIT, h, t, 0.047, 0.038, caps=False)
    h, t = bone_pts(f"shin.{s}")
    between("Body", f"shin.{s}", SKIN, h, t, 0.037, 0.03)
    box("Body", f"foot.{s}", SKIN, (0.055, 0.1, 0.045), (sx * 0.065, -0.02, 0.028), bevel=0.018)

# ---------------------------------------------------------------- FACE (brows, nose, mouth, blush)
for s, sx in (("L", 1), ("R", -1)):
    box("Face", "head", LASH, (0.045, 0.008, 0.007), (sx * 0.078, -0.163, 0.772), rot=(0, sx * 0.12, 0),
        bevel=0.003)
    ball("Face", "head", BLUSH, (0.024, 0.006, 0.012), (sx * 0.122, -0.146, 0.638), segs=10, rings=6)
ball("Face", "head", SKIN, (0.011, 0.01, 0.009), (0, -0.175, 0.655), segs=8, rings=6)
bpy.ops.mesh.primitive_torus_add(major_radius=0.014, minor_radius=0.0035, major_segments=16, minor_segments=6,
                                 location=(0, -0.155, 0.62), rotation=(math.pi / 2 + 0.45, 0, 0))
mouth = bpy.context.active_object
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="DESELECT")
bpy.ops.object.mode_set(mode="OBJECT")
for v in mouth.data.vertices:  # keep the lower half of the ring -> small smile
    v.select = v.co.y > -0.002
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.delete(type="VERT")
bpy.ops.object.mode_set(mode="OBJECT")
part(mouth, "Face", "head", LASH)

# ---------------------------------------------------------------- EYES
for s, sx in (("L", 1), ("R", -1)):
    x, z = sx * 0.075, 0.69
    ball("Eyes", "head", SCLERA, (0.03, 0.01, 0.038), (x, -0.166, z), segs=16, rings=10)
    ball("Eyes", "head", IRIS, (0.024, 0.01, 0.031), (x - sx * 0.002, -0.17, z - 0.004), segs=16, rings=10)
    ball("Eyes", "head", PUPIL, (0.012, 0.009, 0.016), (x - sx * 0.002, -0.174, z - 0.004), segs=12, rings=8)
    ball("Eyes", "head", SHINE, (0.007, 0.004, 0.007), (x - 0.008, -0.181, z + 0.008), segs=8, rings=6)
    ball("Eyes", "head", SHINE, (0.004, 0.003, 0.004), (x + 0.008, -0.18, z - 0.015), segs=8, rings=6)
    box("Eyes", "head", LASH, (0.064, 0.011, 0.01), (x, -0.168, z + 0.035), rot=(0, -sx * 0.04, 0), bevel=0.004)
    box("Eyes", "head", LASH, (0.012, 0.009, 0.007), (x + sx * 0.036, -0.162, z + 0.036),
        rot=(0, -sx * 0.45, 0), bevel=0.003)

# ---------------------------------------------------------------- HAIR (chin-length bob with bangs)
ball("Hair", "head", HAIR, (0.215, 0.21, 0.2), (0, 0.04, 0.765), segs=24, rings=14)
ball("Hair", "head", HAIR, (0.2, 0.15, 0.17), (0, 0.07, 0.62), segs=20, rings=12)
for s, sx in (("L", 1), ("R", -1)):
    ball("Hair", "head", HAIR, (0.06, 0.1, 0.15), (sx * 0.178, -0.005, 0.62), segs=14, rings=10)
for (b, t, r) in (((-0.15, -0.09, 0.83), (-0.188, -0.1, 0.66), 0.05),
                  ((-0.08, -0.135, 0.85), (-0.1, -0.182, 0.75), 0.055),
                  ((0.0, -0.152, 0.855), (-0.012, -0.192, 0.758), 0.055),
                  ((0.08, -0.135, 0.85), (0.088, -0.182, 0.755), 0.055),
                  ((0.15, -0.09, 0.83), (0.188, -0.1, 0.66), 0.05)):
    between("Hair", "head", HAIR, b, t, r, 0.0, verts=8, flat_y=0.55, caps=False)

# ---------------------------------------------------------------- TOP (short-sleeve tee)
tube("Top", "chest", TOP, 0.116, 0.106, 0.41, 0.502, sy=0.82)
tube("Top", "spine", TOP, 0.104, 0.118, 0.325, 0.415, sy=0.82)
bpy.ops.mesh.primitive_torus_add(major_radius=0.05, minor_radius=0.011, major_segments=16, minor_segments=6,
                                 location=(0, 0, 0.5))
part(bpy.context.active_object, "Top", "chest", TOP_TRIM)
tube("Top", "chest", TOP_TRIM, 0.1145, 0.1135, 0.432, 0.452, sy=0.82)
for s, sx in (("L", 1), ("R", -1)):
    ball("Top", "chest", TOP, (0.048, 0.048, 0.048), (sx * 0.115, 0, 0.47))
    h, t = bone_pts(f"upper_arm.{s}")
    mid = Vector(h).lerp(Vector(t), 0.65)
    between("Top", f"upper_arm.{s}", TOP, h, tuple(mid), 0.043, 0.041, caps=False)

# ---------------------------------------------------------------- BOTTOM (pleated skirt)
tube("Bottom", "hips", SKIRT, 0.165, 0.114, 0.2, 0.33, sy=0.86, verts=16, smooth_angle=15)
tube("Bottom", "hips", TOP_TRIM, 0.117, 0.117, 0.315, 0.338, sy=0.86, verts=16)

# ---------------------------------------------------------------- SOCKS + SHOES (sneakers)
for s, sx in (("L", 1), ("R", -1)):
    tube("Socks", f"shin.{s}", SOCK, 0.036, 0.04, 0.06, 0.135, x=sx * 0.065)
    box("Shoes", f"foot.{s}", SHOE, (0.072, 0.128, 0.058), (sx * 0.065, -0.022, 0.036), bevel=0.022)
    box("Shoes", f"foot.{s}", SOLE, (0.078, 0.134, 0.02), (sx * 0.065, -0.022, 0.01), bevel=0.008)
    box("Shoes", f"foot.{s}", SOLE, (0.04, 0.05, 0.008), (sx * 0.065, -0.05, 0.066), bevel=0.003)

# ---------------------------------------------------------------- join slots + skin to rig
SLOT_OBJECTS = {}
for slot, objs in SLOTS.items():
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    o = bpy.context.active_object
    o.name = o.data.name = f"Teen_{slot}"
    o.parent = rig
    mod = o.modifiers.new("Armature", "ARMATURE")
    mod.object = rig
    SLOT_OBJECTS[slot] = o

# ---------------------------------------------------------------- stage
bpy.ops.mesh.primitive_circle_add(vertices=48, radius=0.45, fill_type="NGON")
ground = bpy.context.active_object
ground.name = "Ground"
ground.data.materials.append(mat("GroundMat", (0.55, 0.45, 0.70), rough=0.9))

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.62, 0.66, 0.82, 1)
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.9

sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
sun.data.energy, sun.data.angle = 3.5, math.radians(8)
sun.rotation_euler = (math.radians(50), 0, math.radians(-35))
scene.collection.objects.link(sun)
rim = bpy.data.objects.new("Rim", bpy.data.lights.new("Rim", "AREA"))
rim.data.energy, rim.data.size = 60, 1.0
rim.location, rim.rotation_euler = (-0.8, 1.2, 1.3), (math.radians(-55), 0, math.radians(-145))
scene.collection.objects.link(rim)

target = bpy.data.objects.new("CamTarget", None)
target.location = (0, 0, 0.47)
scene.collection.objects.link(target)
cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
cam.data.lens = 50
scene.collection.objects.link(cam)
tr = cam.constraints.new("TRACK_TO")
tr.target, tr.track_axis, tr.up_axis = target, "TRACK_NEGATIVE_Z", "UP_Y"
scene.camera = cam

engines = bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items.keys()
scene.render.engine = next(e for e in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES") if e in engines)
scene.render.resolution_x = scene.render.resolution_y = 1024
try:
    scene.view_settings.view_transform = "Standard"
except TypeError:
    pass

CAM_3Q, CAM_FRONT = (0.75, -1.55, 0.72), (0.0, -1.7, 0.6)


def render(name, cam_loc):
    cam.location = cam_loc
    scene.render.filepath = os.path.join(OUT, name)
    bpy.ops.render.render(write_still=True)


render("teen_3q.png", CAM_3Q)
render("teen_front.png", CAM_FRONT)

# base body only (shows the swappable slots)
for slot in ("Hair", "Top", "Bottom", "Socks", "Shoes"):
    SLOT_OBJECTS[slot].hide_render = True
render("teen_base_body.png", CAM_3Q)
for slot in ("Hair", "Top", "Bottom", "Socks", "Shoes"):
    SLOT_OBJECTS[slot].hide_render = False

# ---------------------------------------------------------------- test animations
pb = rig.pose.bones


def reset_pose():
    for b in pb:
        b.rotation_mode = "QUATERNION"
        b.rotation_quaternion = (1, 0, 0, 0)
    bpy.context.view_layer.update()


def turn(bone, axis, deg):
    """Rotate a pose bone about a world axis through its head."""
    bpy.context.view_layer.update()
    b = pb[bone]
    h = b.head.copy()
    b.matrix = Matrix.Translation(h) @ Matrix.Rotation(math.radians(deg), 4, axis) @ Matrix.Translation(-h) @ b.matrix
    bpy.context.view_layer.update()


def key(frame, bones):
    for name in bones:
        pb[name].keyframe_insert("rotation_quaternion", frame=frame)


def make_action(name, frames, bones):
    rig.animation_data_create()
    rig.animation_data.action = None
    for frame, moves in frames:
        reset_pose()
        for bone, axis, deg in moves:
            turn(bone, axis, deg)
        key(frame, bones)
    act = rig.animation_data.action
    act.name = name
    act.use_fake_user = True
    return act


wave_bones = ["upper_arm.R", "forearm.R", "hand.R", "head", "chest"]
up = [("upper_arm.R", "Y", 115), ("upper_arm.R", "X", 30), ("chest", "Y", -4), ("head", "Y", 6)]
wave = make_action("Wave", [
    (1, []),
    (10, up + [("forearm.R", "Y", 25)]),
    (20, up + [("forearm.R", "Y", -15)]),
    (30, up + [("forearm.R", "Y", 25)]),
    (40, up + [("forearm.R", "Y", -15)]),
    (50, []),
], wave_bones)

idle_bones = ["head", "chest", "upper_arm.L", "upper_arm.R"]
idle = make_action("Idle", [
    (1, []),
    (30, [("head", "Y", 4), ("chest", "X", 2), ("upper_arm.L", "Y", -3), ("upper_arm.R", "Y", 3)]),
    (60, []),
], idle_bones)

# render a wave frame to prove the skeleton drives every slot
rig.animation_data.action = wave
scene.frame_set(20)
render("teen_wave.png", CAM_3Q)
rig.animation_data.action = None
reset_pose()
scene.frame_set(1)

# ---------------------------------------------------------------- save + export
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "teen_base.blend"))
bpy.ops.object.select_all(action="DESELECT")
rig.select_set(True)
for o in SLOT_OBJECTS.values():
    o.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "teen_base.glb"), use_selection=True,
                          export_animations=True, export_animation_mode="ACTIONS")
print("DONE", {k: len(v.data.polygons) for k, v in SLOT_OBJECTS.items()})
