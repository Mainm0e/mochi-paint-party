"""Rigged mochi character: a squishy rice-cake blob with a painted face, toon shading and a cocoa outline.

Slots: Mochi_Body (the blob), Mochi_Face (painted decal: shine, cheeks, mood marks, eyes, mouth) and one
Mochi_Top_<Name> mesh per topping. Rig: root -> body (squash/stretch from the base) -> top (topping sway).
Actions: Idle, Bounce, Wiggle. Also writes the face part layers + layers.json used by the Mochi Maker web app.

Run:  blender --background --factory-startup --python make_mochi.py -- <out_dir>
"""
import base64
import json
import math
import os
import shutil
import sys
import tempfile
from collections import defaultdict

import bmesh
import bpy
import numpy as np
from mathutils import Euler, Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.dirname(__file__)
OUT = os.path.abspath(OUT)  # Blender's image.save() silently fails on relative paths
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = 30


def srgb(h):
    return np.array([int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)])


def lin(h):
    c = srgb(h)
    return tuple(np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4))


def mix_hex(a, b, t):
    return "#" + "".join(f"{round(v * 255):02x}" for v in srgb(a) * (1 - t) + srgb(b) * t)


INK = "#5a3a3a"  # outline + face line colour (warm cocoa)
FLAVORS = {"strawberry": "#f9c4cc", "matcha": "#c3dfa8", "plain": "#fbf7f1", "ube": "#d2bff0",
           "mango": "#ffdc90", "kinako": "#e8c9a2", "sakura": "#fbd9e4", "blueberry": "#bfd0f4"}


def shadow_of(h):
    return mix_hex(h, "#9a6c8c", 0.3)


# ---------------------------------------------------------------- toon materials
MATS = {}


def _mix(nt, blend, fac, a, b):
    n = nt.nodes.new("ShaderNodeMix")
    n.data_type, n.blend_type = "RGBA", blend
    ins = {s.identifier: s for s in n.inputs}
    for sock, val in ((n.inputs[0], fac), (ins["A_Color"], a), (ins["B_Color"], b)):
        if isinstance(val, bpy.types.NodeSocket):
            nt.links.new(val, sock)
        else:
            sock.default_value = val
    return next(s for s in n.outputs if s.type == "RGBA")


def _ramp(nt, src, p0, p1, c0=(0, 0, 0, 1), c1=(1, 1, 1, 1)):
    r = nt.nodes.new("ShaderNodeValToRGB")
    r.color_ramp.interpolation = "EASE"
    e0, e1 = r.color_ramp.elements
    e0.position, e0.color = p0, c0
    e1.position, e1.color = p1, c1
    nt.links.new(src, r.inputs[0])
    return r.outputs[0]


def mat(name, base, shadow=None, img=None, rim=0.14):
    """2-band toon ramp + soft fresnel rim (EEVEE). The Principled BSDF stays for glTF export."""
    if name in MATS:
        return MATS[name]
    shadow = shadow or shadow_of(base)
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf, out = nt.nodes["Principled BSDF"], nt.nodes["Material Output"]
    bsdf.inputs["Roughness"].default_value = 0.8
    if img:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image, tex.interpolation = img, "Cubic"
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
        color = tex.outputs["Color"]
    else:
        rgb = nt.nodes.new("ShaderNodeRGB")
        rgb.name = "BaseRGB"
        color = rgb.outputs[0]
    diff = nt.nodes.new("ShaderNodeBsdfDiffuse")
    s2r = nt.nodes.new("ShaderNodeShaderToRGB")
    nt.links.new(diff.outputs[0], s2r.inputs[0])
    light = _ramp(nt, s2r.outputs["Color"], 0.36, 0.5)
    shade = _mix(nt, "MULTIPLY", 1.0, color, (1, 1, 1, 1))
    shade.node.name = "ShadeMix"
    col = _mix(nt, "MIX", light, shade, color)
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.35
    col = _mix(nt, "ADD", _ramp(nt, lw.outputs["Facing"], 0.7, 0.95, c1=(rim, rim, rim, 1)), col, (1, 0.97, 1, 1))
    emit = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(col, emit.inputs["Color"])
    toon = emit.outputs[0]
    if img:
        mx = nt.nodes.new("ShaderNodeMixShader")
        nt.links.new(tex.outputs["Alpha"], mx.inputs[0])
        nt.links.new(nt.nodes.new("ShaderNodeBsdfTransparent").outputs[0], mx.inputs[1])
        nt.links.new(toon, mx.inputs[2])
        toon = mx.outputs[0]
        m.surface_render_method = "BLENDED"
    nt.links.new(toon, out.inputs["Surface"])
    m["toon_socket"] = toon.node.name
    MATS[name] = m
    set_color(m, base, shadow)
    return m


def set_color(m, base, shadow=None):
    nt = m.node_tree
    shadow = shadow or shadow_of(base)
    if "BaseRGB" in nt.nodes:
        nt.nodes["BaseRGB"].outputs[0].default_value = (*lin(base), 1)
        nt.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*lin(base), 1)
    tint = tuple(s / max(b, 1e-6) for s, b in zip(lin(shadow), lin(base)))
    sm = nt.nodes["ShadeMix"]
    next(s for s in sm.inputs if s.identifier == "B_Color").default_value = (*tint, 1)


def use_export_shading(export):
    for m in MATS.values():
        nt = m.node_tree
        src = nt.nodes["Principled BSDF"] if export else nt.nodes[m["toon_socket"]]
        nt.links.new(src.outputs[0], nt.nodes["Material Output"].inputs["Surface"])


# inverted-hull outline ink. Body/topping hulls are Blender-only objects; the emote effect props bake their hull
# into the exported mesh, so this exports as a single-sided dark-ink material.
OUTLINE = bpy.data.materials.new("Outline")
OUTLINE.use_nodes = True
_ob = OUTLINE.node_tree.nodes["Principled BSDF"]
_ob.inputs["Base Color"].default_value = (*lin(INK), 1)
_ob.inputs["Emission Color"].default_value = (*lin(INK), 1)
_ob.inputs["Emission Strength"].default_value = 1.0
_ob.inputs["Roughness"].default_value = 1.0
OUTLINE.use_backface_culling = True

# ---------------------------------------------------------------- body shape
H, RX, RY = 0.47, 0.36, 0.33  # height, half width, half depth


def body_point(x, y, z):
    """Unit-sphere point -> soft mochi: round dome, slightly saggy and wide near a flat base."""
    t = (1 - z) / 2                                   # 0 at top, 1 at bottom
    spread = 1 + 0.12 * t ** 2.2
    if z < -0.3:                                      # flatten the bottom softly
        z = -0.3 - 0.26 * (1 - math.exp(-(-0.3 - z) / 0.26))
    if y < 0:
        y *= 1 - 0.1 * y * y                          # slightly flatter face
    zmin = -0.3 - 0.26 * (1 - math.exp(-0.7 / 0.26))
    return Vector((x * RX * spread, y * RY * spread, (z - zmin) / (1 - zmin) * H))


# ---------------------------------------------------------------- face painting (texture window over the front)
TEX_N, TEX_X0, TEX_Z0, TEX_S = 1024, -0.36, -0.02, 0.72
_g = (np.arange(TEX_N) + 0.5) / TEX_N * TEX_S
GX, GZ = np.meshgrid(TEX_X0 + _g, TEX_Z0 + _g)
PX = TEX_S / TEX_N
EX, EZ, MZ = 0.1, 0.24, 0.165  # eye centre x/z, mouth z
E, M = 1.32, 1.2                 # eye / mouth size scale


def cov(d):
    return np.clip(0.5 - d / PX, 0, 1)


def ell(dx, dz, a, b):
    r = np.sqrt((dx / a) ** 2 + (dz / b) ** 2) + 1e-9
    gx, gz = dx / (a * a * r), dz / (b * b * r)
    return (r - 1) / np.sqrt(gx * gx + gz * gz + 1e-12), r


def seg(px, pz, p0, p1, r0, r1):
    vx, vz = p1[0] - p0[0], p1[1] - p0[1]
    t = np.clip(((px - p0[0]) * vx + (pz - p0[1]) * vz) / (vx * vx + vz * vz), 0, 1)
    return np.hypot(px - p0[0] - t * vx, pz - p0[1] - t * vz) - (r0 + (r1 - r0) * t)


def heart(cx, cz, s):
    """Signed distance to a heart of half-width ~s centred on (cx, cz)."""
    x, y = np.abs(GX - cx) / (1.25 * s), (GZ - cz) / (1.25 * s) + 0.55
    d1 = np.hypot(x - 0.25, y - 0.75) - math.sqrt(2) / 4
    t = 0.5 * np.maximum(x + y, 0)
    d2 = np.sqrt(np.minimum((x) ** 2 + (y - 1) ** 2, (x - t) ** 2 + (y - t) ** 2)) * np.sign(x - y)
    return np.where(x + y > 1, d1, d2) * 1.25 * s


def star(cx, cz, s):
    return np.minimum(ell(GX - cx, GZ - cz, s, s * 0.22)[0], ell(GX - cx, GZ - cz, s * 0.22, s)[0])


class Canvas:
    def __init__(self, bg="#ffffff"):
        self.c = np.ones((TEX_N, TEX_N, 3)) * srgb(bg)
        self.a = np.zeros((TEX_N, TEX_N))

    def paint(self, cover, col, alpha=1.0):
        a = np.clip(cover * alpha, 0, 1)
        col = srgb(col) if isinstance(col, str) else col
        out = a + self.a * (1 - a)
        w = np.where(out > 0, a / np.maximum(out, 1e-6), 0)[..., None]
        self.c = self.c * (1 - w) + col * w
        self.a = out

    def outlined(self, d, fill, width=0.0026):
        self.paint(cov(d - width), INK)
        self.paint(cov(d), fill)

    def save(self, path):
        img = bpy.data.images.new("tmp", TEX_N, TEX_N, alpha=True)
        img.pixels.foreach_set(np.dstack([self.c, self.a]).astype(np.float32).ravel())
        os.makedirs(os.path.dirname(path), exist_ok=True)
        img.filepath_raw, img.file_format = path, "PNG"
        img.save()
        bpy.data.images.remove(img)


EYES = ["bean", "sparkle", "happy", "sleepy", "wink", "dizzy", "heart", "angry", "teary", "shock"]
MOUTHS = ["smile", "frown", "open", "cat", "grin", "tongue", "wavy", "ooh"]
CHEEKS = ["none", "soft", "rosy", "lines"]
MARKS = ["none", "anger", "sweat", "sparkles", "hearts"]


def paint_eyes(cv, kind, ink):
    """Eyes in `ink`; returns the ink mask (minus highlights) so the web app can recolour the eyes."""
    mask = np.zeros((TEX_N, TEX_N))

    def inked(c, alpha=1.0):
        nonlocal mask
        cv.paint(c, ink, alpha)
        mask = np.maximum(mask, np.clip(c * alpha, 0, 1))

    def white(c, alpha=1.0):
        nonlocal mask
        cv.paint(c, "#ffffff", alpha)
        mask *= 1 - np.clip(c * alpha, 0, 1)

    for sx in (1, -1):
        cx = sx * EX
        dx, dz = GX - cx, GZ - EZ
        k = "happy" if kind == "wink" and sx == 1 else ("bean" if kind == "wink" else kind)
        if k in ("bean", "angry"):
            b = (0.029 if k == "bean" else 0.025) * E
            inked(cov(ell(dx, dz, 0.021 * E, b)[0]))
            white(cov(np.hypot(dx + 0.0065 * E, dz - 0.0105 * E) - 0.0085 * E))
            white(cov(np.hypot(dx - 0.006 * E, dz + 0.012 * E) - 0.0038 * E))
            if k == "angry":  # brow: inner end low
                inked(cov(seg(GX, GZ, (cx - sx * 0.022 * E, EZ + 0.034 * E), (cx + sx * 0.02 * E, EZ + 0.052 * E),
                              0.0042, 0.0034)))
        elif k == "sparkle":
            d, r = ell(dx, dz, 0.027 * E, 0.034 * E)
            inked(cov(d))
            _, rg = ell(dx, dz + 0.016 * E, 0.02 * E, 0.012 * E)
            white(cov(d) * np.clip(1 - rg ** 2, 0, 1), 0.4)
            white(cov(np.hypot(dx + 0.009 * E, dz - 0.012 * E) - 0.0108 * E))
            white(cov(star(cx + 0.0095 * E, EZ - 0.012 * E, 0.0085 * E)))
            white(cov(np.hypot(dx - 0.003 * E, dz - 0.019 * E) - 0.003 * E))
        elif k == "happy":
            d, _ = ell(dx, dz + 0.008 * E, 0.024 * E, 0.021 * E)
            inked(cov(np.abs(d) - 0.005) * np.clip((dz + 0.008 * E) / 0.003, 0, 1))
        elif k == "sleepy":
            d, _ = ell(dx, dz - 0.004 * E, 0.024 * E, 0.013 * E)
            inked(cov(np.abs(d) - 0.005) * np.clip(-(dz - 0.004 * E) / 0.003, 0, 1))
        elif k == "dizzy":
            r, ph = np.hypot(dx, dz), np.mod(np.arctan2(dz, dx * sx), 2 * math.pi)
            kk = 0.027 * E / (2.4 * 2 * math.pi)
            d = np.min([np.abs(r - kk * (ph + 2 * math.pi * n)) for n in range(3)], axis=0)
            inked(cov(d - 0.0028) * (r < 0.029 * E))
        elif k == "teary":  # wobbly glossy eyes with tear streaks
            inked(cov(ell(dx, dz, 0.022 * E, 0.028 * E)[0]))
            white(cov(np.hypot(dx + 0.007 * E, dz - 0.01 * E) - 0.0095 * E))
            white(cov(np.hypot(dx - 0.006 * E, dz + 0.011 * E) - 0.005 * E))
            white(cov(np.hypot(dx - 0.008 * E, dz - 0.008 * E) - 0.0035 * E))
            cv.paint(cov(seg(GX, GZ, (cx + sx * 0.012 * E, EZ - 0.026 * E), (cx + sx * 0.016 * E, EZ - 0.07 * E),
                             0.004, 0.0075)), "#9ed7f7", 0.9)
        elif k == "shock":  # tiny pupils in round whites
            r = np.hypot(dx, dz)
            cv.paint(cov(r - 0.028 * E), "#ffffff")
            inked(cov(np.abs(r - 0.028 * E) - 0.0034))
            inked(cov(r - 0.0075 * E))
        elif k == "squeeze":  # squeezed shut with effort: > <
            tip = (cx - sx * 0.014 * E, EZ)
            for dz in (0.016 * E, -0.016 * E):
                inked(cov(seg(GX, GZ, (cx + sx * 0.016 * E, EZ + dz), tip, 0.0042, 0.0042)))
        elif k == "heart":
            cv.outlined(heart(cx, EZ, 0.026 * E), "#e8566e", 0.0026)
            white(cov(np.hypot(dx + 0.011 * E, dz - 0.008 * E) - 0.006 * E))
    return mask


def paint_mouth(cv, kind):
    mx, mz = GX / M, (GZ - MZ) / M  # mouth space, scaled by M
    mc = lambda d: cov(d * M)
    tm = np.arctan2(mz, mx)
    line, fill, tongue = INK, "#c9505a", "#f28a9a"
    if kind in ("smile", "tongue"):
        cv.paint(mc(np.abs(np.hypot(mx, mz) - 0.014) - 0.0028) * ((tm > -2.5) & (tm < -0.64)), line)
        if kind == "tongue":
            d = np.maximum(ell(mx - 0.004, mz + 0.016, 0.0065, 0.0075)[0], mz + 0.0125)
            cv.paint(mc(d - 0.0024), line)
            cv.paint(mc(d), tongue)
    elif kind == "frown":
        r_c, t_c = np.hypot(mx, mz + 0.012), np.arctan2(mz + 0.012, mx)
        cv.paint(mc(np.abs(r_c - 0.014) - 0.0028) * ((t_c > 0.64) & (t_c < 2.5)), line)
    elif kind in ("open", "grin"):
        d = ell(mx, mz, 0.011, 0.012)[0] if kind == "open" else np.maximum(ell(mx, mz - 0.006, 0.02, 0.019)[0], mz - 0.006)
        cv.paint(mc(d - 0.0028), line)
        cv.paint(mc(d), fill)
        cv.paint(mc(np.maximum(np.hypot(mx, mz + (0.012 if kind == "open" else 0.016)) - 0.008, d)), tongue)
    elif kind == "cat":
        for ox in (-0.0095, 0.0095):
            r_c, t_c = np.hypot(mx - ox, mz - 0.004), np.arctan2(mz - 0.004, mx - ox)
            cv.paint(mc(np.abs(r_c - 0.0095) - 0.0026) * ((t_c > -3.0) & (t_c < -0.14)), line)
    elif kind == "wavy":
        wz = 0.003 * np.sin(mx / 0.0062 * math.pi)
        cv.paint(mc(np.hypot(np.maximum(np.abs(mx) - 0.016, 0), mz - wz) - 0.0026), line)
    elif kind == "ooh":
        cv.paint(mc(np.abs(ell(mx, mz + 0.002, 0.0068, 0.0082)[0]) - 0.0026), line)
    elif kind == "gape":  # eating: a huge mouth stretched wide over most of the lower face
        cy = 0.038  # from just under the eyes almost down to the base
        d, r = ell(mx, mz + cy, 0.108, 0.075)
        cv.paint(mc(d - 0.0045), line)
        cv.paint(mc(d), "#5e1f2a")
        cv.paint(mc(d) * np.clip(1 - r, 0, 1) ** 0.7, "#2a0d14", 0.9)  # dark throat in the middle
        cv.paint(mc(d) * np.clip((r - 0.72) / 0.28, 0, 1), fill, 0.8)  # redder rim inside the lips
        cv.paint(mc(np.maximum(ell(mx, mz + cy + 0.05, 0.066, 0.034)[0], d)), tongue)
    elif kind == "munch":  # chewing with the mouth full: a wide wobbly 'mmm'
        for ox in (-0.011, 0.011):
            r_c, t_c = np.hypot(mx - ox, mz - 0.004), np.arctan2(mz - 0.004, mx - ox)
            cv.paint(mc(np.abs(r_c - 0.011) - 0.003) * ((t_c > -3.0) & (t_c < -0.14)), line)


def paint_cheeks(cv, kind):
    if kind == "none":
        return
    strength, scale = {"soft": (0.55, 1.0), "rosy": (0.85, 1.18), "lines": (0.55, 1.0)}[kind]
    for sx in (1, -1):
        _, r = ell(GX - sx * 0.152, GZ - 0.19, 0.04 * scale, 0.022 * scale)
        cv.paint(np.clip(1 - r ** 2, 0, 1) ** 0.7, "#f59aaa", strength)
        if kind == "lines":
            for i in (-1, 0, 1):
                bx = sx * 0.152 + i * 0.014
                cv.paint(cov(seg(GX, GZ, (bx + 0.005, 0.198), (bx - 0.003, 0.182), 0.0017, 0.0015)), "#e8687e", 0.85)


def paint_marks(cv, kind):
    if kind == "anger":
        for (cx, cz, s) in ((0.215, 0.37, 0.017), (-0.235, 0.13, 0.013)):
            for qx in (1, -1):
                for qz in (1, -1):
                    ccx, ccz = cx + qx * s, cz + qz * s
                    r = np.hypot(GX - ccx, GZ - ccz)
                    diff = np.angle(np.exp(1j * (np.arctan2(GZ - ccz, GX - ccx) - math.atan2(-qz, -qx))))
                    cv.paint(cov(np.abs(r - s * 0.92) - 0.0027) * (np.abs(diff) < 0.72), "#d9465a")
    elif kind == "sweat":
        c, top = (0.205, 0.335), (0.212, 0.372)
        d = np.minimum(np.hypot(GX - c[0], GZ - c[1]) - 0.016, seg(GX, GZ, c, top, 0.0155, 0.001))
        cv.outlined(d, "#a8dbf7")
        cv.paint(cov(np.hypot(GX - c[0] + 0.006, GZ - c[1] - 0.004) - 0.0042), "#ffffff")
    elif kind == "sparkles":
        for cx, cz, s in ((0.205, 0.37, 0.022), (0.245, 0.325, 0.012), (-0.235, 0.34, 0.015)):
            cv.outlined(star(cx, cz, s), "#ffe07a", 0.0024)
    elif kind == "hearts":
        for cx, cz, s in ((0.21, 0.355, 0.019), (-0.232, 0.315, 0.014)):
            cv.outlined(heart(cx, cz, s), "#f2788e", 0.0024)


def paint_shine(cv):
    a = -0.6
    dx, dz = GX + 0.17, GZ - 0.385
    rx, rz = dx * math.cos(a) + dz * math.sin(a), -dx * math.sin(a) + dz * math.cos(a)
    cv.paint(cov(ell(rx, rz, 0.052, 0.03)[0]), "#ffffff", 0.92)
    cv.paint(cov(np.hypot(GX + 0.098, GZ - 0.435) - 0.012), "#ffffff", 0.92)


DEFAULT_LOOK = dict(flavor="strawberry", top="Sprout", eyes="bean", eye_ink=INK, mouth="smile", cheeks="soft",
                    marks="none")


def face_canvas(look):
    cv = Canvas(FLAVORS[look["flavor"]])
    paint_shine(cv)
    paint_cheeks(cv, look["cheeks"])
    paint_marks(cv, look["marks"])
    paint_eyes(cv, look["eyes"], look["eye_ink"])
    paint_mouth(cv, look["mouth"])
    return cv


FACE_IMG = bpy.data.images.new("MochiFace", TEX_N, TEX_N, alpha=True)


def set_face(look):
    cv = face_canvas(look)
    FACE_IMG.pixels.foreach_set(np.dstack([cv.c, cv.a]).astype(np.float32).ravel())
    FACE_IMG.update()


set_face(DEFAULT_LOOK)

# ---------------------------------------------------------------- skeleton
# Emote faces and effect props are hidden by size, not visibility (glTF can't animate visibility): each sits on
# its own bone, modelled at 1/100 scale around FX_C inside the body, and an emote scales that bone up x100.
# Face_main is the normal face; emotes shrink its bone to hide it while their own face is showing.
FX_C = (0, 0, 0.2)
SHRINK, SHOW, GONE = 0.01, 100.0, 0.001
EMOTES = ["happy", "love", "angry", "sad", "surprised", "sleepy"]
EMOTE_LOOKS = {
    "happy": dict(eyes="happy", mouth="open", cheeks="rosy"),
    "love": dict(eyes="heart", mouth="smile", cheeks="rosy"),
    "angry": dict(eyes="angry", mouth="frown", cheeks="soft"),
    "sad": dict(eyes="teary", mouth="wavy", cheeks="soft"),
    "surprised": dict(eyes="shock", mouth="open", cheeks="soft"),
    "sleepy": dict(eyes="sleepy", mouth="ooh", cheeks="soft"),
}
FX_NAMES = ["sparkle1", "sparkle2", "sparkle3", "heart1", "heart2", "heart3", "anger", "tear1", "tear2", "bang",
            "z1", "z2", "z3"]
BONES = {
    "root": ((0, 0, 0), (0, 0, 0.06), None),
    "body": ((0, 0, 0), (0, 0, H), "root"),
    "top": ((0, 0, H), (0, 0, H + 0.08), "body"),
    "face_main": (FX_C, (0, 0, 0.26), "body"),
}
for e in EMOTES:
    BONES[f"face_{e}"] = (FX_C, (0, 0, 0.26), "body")
for n in FX_NAMES:
    BONES[f"fx_{n}"] = (FX_C, (0, 0, 0.25), "root")
arm_data = bpy.data.armatures.new("MochiRig")
rig = bpy.data.objects.new("MochiRig", arm_data)
scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
for name, (h, t, parent) in BONES.items():
    eb = arm_data.edit_bones.new(name)
    eb.head, eb.tail = h, t
    if parent:
        eb.parent = arm_data.edit_bones[parent]
bpy.ops.object.mode_set(mode="OBJECT")
arm_data.display_type = "STICK"

# ---------------------------------------------------------------- mesh helpers
SLOTS = defaultdict(list)


def activate(o):
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    bpy.context.view_layer.objects.active = o


def part(o, slot, bone, material, smooth_angle=60):
    activate(o)
    o.data.materials.append(material)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(smooth_angle))
    except Exception:
        bpy.ops.object.shade_smooth()
    vg = o.vertex_groups.new(name=bone)
    vg.add(range(len(o.data.vertices)), 1.0, "REPLACE")
    SLOTS[slot].append(o)
    return o


def ball(slot, material, radii, loc, rot=(0, 0, 0), segs=20, rings=12, shape=None, bone="top"):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=rings, radius=1)
    o = bpy.context.active_object
    for v in o.data.vertices:
        p = shape(v.co) if shape else v.co
        v.co = Vector((p[0] * radii[0], p[1] * radii[1], p[2] * radii[2]))
    o.rotation_euler, o.location = Euler(rot), loc
    return part(o, slot, bone, material)


def stick(slot, material, p0, p1, r, bone="top"):
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=r, depth=d.length, location=(0, 0, d.length / 2))
    o = bpy.context.active_object
    activate(o)
    bpy.ops.object.transform_apply(location=True)
    o.matrix_world = Matrix.Translation(p0) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
    return part(o, slot, bone, material)


# ---------------------------------------------------------------- BODY + FACE DECAL
BODY = mat("MochiBody", FLAVORS[DEFAULT_LOOK["flavor"]])
FACE = mat("MochiFace", "#ffffff", "#e8d6dc", img=FACE_IMG, rim=0.0)
bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=40, radius=1)
body = bpy.context.active_object
for v in body.data.vertices:
    v.co = body_point(*v.co)

me = body.data.copy()
face = bpy.data.objects.new("FaceDecal", me)
scene.collection.objects.link(face)
bm = bmesh.new()
bm.from_mesh(me)
bm.normal_update()
keep = lambda v: v.co.y < -0.02 and TEX_Z0 < v.co.z < TEX_Z0 + TEX_S and abs(v.co.x) < -TEX_X0
bmesh.ops.delete(bm, geom=[f for f in bm.faces if not all(keep(v) for v in f.verts)], context="FACES")
for v in bm.verts:
    v.co += v.normal * 0.0016
uv = bm.loops.layers.uv.verify()
for f in bm.faces:
    for lp in f.loops:
        lp[uv].uv = ((lp.vert.co.x - TEX_X0) / TEX_S, (lp.vert.co.z - TEX_Z0) / TEX_S)
bm.to_mesh(me)
bm.free()
for e, look in EMOTE_LOOKS.items():  # one painted face shell per emote, shrunk into the body until used
    cv = face_canvas({**DEFAULT_LOOK, **look})
    img = bpy.data.images.new(f"MochiEmote_{e}", TEX_N, TEX_N, alpha=True)
    img.pixels.foreach_set(np.dstack([cv.c, cv.a]).astype(np.float32).ravel())
    img.filepath_raw, img.file_format = os.path.join(OUT, "emotes", f"face_{e}.png"), "PNG"
    os.makedirs(os.path.dirname(img.filepath_raw), exist_ok=True)
    img.save()
    img.pack()
    shell = bpy.data.objects.new(f"Emote_{e}", me.copy())
    scene.collection.objects.link(shell)
    for v in shell.data.vertices:
        v.co = Vector(FX_C) + (v.co - Vector(FX_C)) * SHRINK
    part(shell, f"Emote_{e}", f"face_{e}", mat(f"MochiEmote_{e}", "#ffffff", "#e8d6dc", img=img, rim=0.0))
part(face, "Face", "face_main", FACE)
part(body, "Body", "body", BODY)

# ---------------------------------------------------------------- TOPPINGS (one swappable slot each, on the top bone)
LEAF = mat("Leaf", "#9bcb7e", "#6f9f63")
STEM = mat("Stem", "#7fb36a", "#5d8a52")
PETAL = mat("Petal", "#f9c2d3", "#e092ad")
POLLEN = mat("Pollen", "#ffd76a", "#e0a94a")
BERRY = mat("Berry", "#f2616f", "#c4404f")
ACCENT = mat("Accent", "#f58faa", "#d06686")
GOLD = mat("Gold", "#f5cb5c", "#c99a3c")
GEM = mat("Gem", "#8fd0f5", "#5ea4cf")
DANGO = [mat("DangoPink", "#f7b7c6", "#d98ea1"), mat("DangoWhite", "#fbf7f1", "#ddd2cc"),
         mat("DangoGreen", "#b9d99a", "#8fb276")]
SKEWER = mat("Skewer", "#d9b07c", "#b08656")
T = H - 0.012  # where toppings sit


def leaf_shape(p):
    w = max(0.0, 1 - p.x * p.x) ** 0.65
    return Vector((p.x, p.y * w, p.z * w))


def top_sprout(s):
    stick(s, STEM, (0, -0.005, T - 0.01), (0, -0.002, T + 0.035), 0.008)
    for sx in (1, -1):
        ball(s, LEAF, (0.052, 0.03, 0.009), (sx * 0.044, -0.002, T + 0.052), rot=(0.15, -sx * 0.5, 0), shape=leaf_shape)


def top_sakura(s):
    for i in range(5):  # petals: local x points away from the centre, tips cupped upward
        a = i * 2 * math.pi / 5 + 0.3
        ball(s, PETAL, (0.042, 0.028, 0.011), (math.cos(a) * 0.038, math.sin(a) * 0.038, T + 0.024),
             rot=(0, -0.45, a), shape=lambda p: Vector((p.x, p.y * (1 - 0.3 * max(0.0, p.x)), p.z)))
    ball(s, POLLEN, (0.016, 0.016, 0.011), (0, 0, T + 0.036))


def top_berry(s):
    tip_up = lambda p: Vector((p.x * (1 - 0.42 * max(0.0, p.z) ** 1.2), p.y * (1 - 0.42 * max(0.0, p.z) ** 1.2), p.z))
    ball(s, BERRY, (0.04, 0.04, 0.046), (0, 0, T + 0.04), shape=tip_up)
    for i in range(5):
        a = i * 2 * math.pi / 5
        ball(s, LEAF, (0.022, 0.012, 0.005), (math.cos(a) * 0.024, math.sin(a) * 0.024, T + 0.006),
             rot=(0, -0.25, a), shape=leaf_shape)


def top_bow(s):
    bow_loop = lambda p: Vector((p.x, p.y, p.z * (0.55 + 0.45 * abs(p.x))))  # pinched toward the knot
    for sx in (1, -1):
        ball(s, ACCENT, (0.052, 0.02, 0.038), (sx * 0.05, -0.02, T + 0.03), rot=(0.3, sx * 0.3, 0), shape=bow_loop)
        ball(s, ACCENT, (0.012, 0.01, 0.03), (sx * 0.016, -0.03, T + 0.0), rot=(0.3, -sx * 0.5, 0))  # ribbon tails
    ball(s, ACCENT, (0.017, 0.016, 0.018), (0, -0.03, T + 0.028))


def top_crown(s):
    bpy.ops.mesh.primitive_cone_add(vertices=28, radius1=0.064, radius2=0.072, depth=0.034, location=(0, 0, T + 0.014))
    part(bpy.context.active_object, s, "top", GOLD)
    for i in range(5):
        a = i * 2 * math.pi / 5 + math.pi / 2
        bpy.ops.mesh.primitive_cone_add(vertices=10, radius1=0.017, radius2=0.0, depth=0.04,
                                        location=(math.cos(a) * 0.067, math.sin(a) * 0.067, T + 0.047))
        part(bpy.context.active_object, s, "top", GOLD)
        ball(s, GOLD, (0.0075, 0.0075, 0.0075), (math.cos(a) * 0.067, math.sin(a) * 0.067, T + 0.068))
    ball(s, GEM, (0.014, 0.008, 0.014), (0, -0.072, T + 0.016))


def top_dango(s):
    p0, p1 = Vector((0.0, 0.0, T - 0.02)), Vector((0.04, 0.0, T + 0.15))
    stick(s, SKEWER, p0, p1, 0.004)
    for i, m in enumerate(DANGO):
        c = p0.lerp(p1, 0.3 + i * 0.24)
        ball(s, m, (0.024, 0.024, 0.022), tuple(c))


TOPPINGS = {"Sprout": top_sprout, "Sakura": top_sakura, "Berry": top_berry, "Bow": top_bow,
            "Crown": top_crown, "Dango": top_dango}
for name, build in TOPPINGS.items():
    build(f"Top_{name}")

# ---------------------------------------------------------------- EMOTE EFFECT PROPS (hearts, sparkles, tears...)
FX_HEART = mat("FxHeart", "#f47c95", "#d0566f")
FX_STAR = mat("FxSparkle", "#ffd86b", "#e0ad3e")
FX_ANGER = mat("FxAnger", "#e5485e", "#b8303f")
FX_TEAR = mat("FxTear", "#9ed7f7", "#6aaedb")
FX_Z = mat("FxZ", "#aab4ee", "#7f8ad0")


def new_obj(me):
    o = bpy.data.objects.new(me.name, me)
    scene.collection.objects.link(o)
    return o


def prism(points, depth):
    """Flat shape in the XZ plane (facing the camera at -Y), extruded along Y."""
    bm = bmesh.new()
    f = bm.faces.new([bm.verts.new((x, -depth / 2, z)) for x, z in points])
    ext = bmesh.ops.extrude_face_region(bm, geom=[f])
    bmesh.ops.translate(bm, verts=[g for g in ext["geom"] if isinstance(g, bmesh.types.BMVert)], vec=(0, depth, 0))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("fx")
    bm.to_mesh(me)
    bm.free()
    return new_obj(me)


def heart_prop():
    pts = []
    for i in range(48):
        t = i / 48 * 2 * math.pi
        pts.append((0.0029 * 16 * math.sin(t) ** 3,
                    0.0029 * (13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))))
    return [(prism(pts, 0.022), FX_HEART)]


def sparkle_prop():
    pts = [((0.05 if i % 2 == 0 else 0.014) * math.cos(math.pi / 2 + i * math.pi / 4),
            (0.05 if i % 2 == 0 else 0.014) * math.sin(math.pi / 2 + i * math.pi / 4)) for i in range(8)]
    return [(prism(pts, 0.016), FX_STAR)]


def anger_prop(s=0.036, r=0.031):
    cu = bpy.data.curves.new("anger", "CURVE")
    cu.dimensions, cu.bevel_depth, cu.bevel_resolution, cu.use_fill_caps = "3D", 0.0058, 3, True
    for qx in (1, -1):
        for qz in (1, -1):
            a0 = math.atan2(-qz, -qx)
            sp = cu.splines.new("POLY")
            sp.points.add(9)
            for p, t in zip(sp.points, np.linspace(-0.8, 0.8, 10)):
                p.co = (qx * s + r * math.cos(a0 + t), 0, qz * s + r * math.sin(a0 + t), 1)
    o = new_obj(cu)
    activate(o)
    bpy.ops.object.convert(target="MESH")
    return [(bpy.context.active_object, FX_ANGER)]


def tear_prop():
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=10, radius=0.02)
    o = bpy.context.active_object
    for v in o.data.vertices:
        z = v.co.z / 0.02
        if z > 0:
            v.co.x *= 1 - 0.92 * z ** 1.3
            v.co.y *= 1 - 0.92 * z ** 1.3
            v.co.z *= 1.9
    return [(o, FX_TEAR)]


def bang_prop():
    bpy.ops.mesh.primitive_cone_add(vertices=16, radius1=0.011, radius2=0.019, depth=0.075, location=(0, 0, 0.022))
    bar = bpy.context.active_object
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=10, radius=0.014, location=(0, 0, -0.045))
    return [(bar, FX_ANGER), (bpy.context.active_object, FX_ANGER)]


def z_prop():
    cu = bpy.data.curves.new("z", "FONT")
    cu.body, cu.size, cu.extrude = "Z", 0.1, 0.008
    cu.align_x, cu.align_y = "CENTER", "CENTER"
    o = new_obj(cu)
    o.rotation_euler = (math.pi / 2, 0, 0)  # face the camera
    activate(o)
    bpy.ops.object.convert(target="MESH")
    return [(bpy.context.active_object, FX_Z)]


def fx(name, pieces, ol=0.0045):
    """Prop + baked inverted-hull outline, shrunk to 1/100 around FX_C and weighted to its fx bone."""
    built = []
    for o, m in pieces:
        activate(o)
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        hull = o.copy()
        hull.data = o.data.copy()
        scene.collection.objects.link(hull)
        bm = bmesh.new()
        bm.from_mesh(hull.data)
        bm.normal_update()
        for v in bm.verts:
            v.co += v.normal * ol
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
        bm.to_mesh(hull.data)
        bm.free()
        hull.data.materials.clear()
        built += [(o, m), (hull, OUTLINE)]
    for o, m in built:
        o.data.materials.clear()
        for v in o.data.vertices:
            v.co = v.co * SHRINK + Vector(FX_C)
        part(o, f"FX_{name}", f"fx_{name}", m, smooth_angle=30)


FX_BUILDERS = {"sparkle": sparkle_prop, "heart": heart_prop, "anger": anger_prop, "tear": tear_prop,
               "bang": bang_prop, "z": z_prop}
for n in FX_NAMES:
    fx(n, FX_BUILDERS[n.rstrip("0123456789")]())

# ---------------------------------------------------------------- join slots, skin to rig, outline
SLOT_OBJECTS, OUTLINES = {}, {}
for slot, objs in SLOTS.items():
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    o = bpy.context.active_object
    o.name = o.data.name = f"Mochi_{slot}"
    o.parent = rig
    mod = o.modifiers.new("Armature", "ARMATURE")
    mod.object = rig
    SLOT_OBJECTS[slot] = o
    if slot == "Body" or slot.startswith("Top_"):  # hull outline: render only, no shadow (web app draws its own)
        hull = o.copy()
        hull.data = o.data.copy()
        hull.name = f"Outline_{slot}"
        scene.collection.objects.link(hull)
        bm = bmesh.new()
        bm.from_mesh(hull.data)
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
        bm.to_mesh(hull.data)
        bm.free()
        hull.data.materials.clear()
        hull.data.materials.append(OUTLINE)
        hull.modifiers.clear()
        disp = hull.modifiers.new("Grow", "DISPLACE")
        disp.direction, disp.mid_level = "NORMAL", 0.0
        disp.strength = -(0.009 if slot == "Body" else 0.0045)  # normals are flipped, so negative = outward
        mod = hull.modifiers.new("Armature", "ARMATURE")
        mod.object = rig
        hull.visible_shadow = False
        OUTLINES[slot] = hull
TOP_SLOTS = [s for s in SLOT_OBJECTS if s.startswith("Top_")]


def show_top(name):
    for s in TOP_SLOTS:
        SLOT_OBJECTS[s].hide_render = OUTLINES[s].hide_render = s != f"Top_{name}"


# ---------------------------------------------------------------- stage
GROUND = mat("GroundMat", "#e3d8f3", "#c2b3de", rim=0.0)
bpy.ops.mesh.primitive_circle_add(vertices=64, radius=0.55, fill_type="NGON")
ground = bpy.context.active_object
ground.name = "Ground"
ground.data.materials.append(GROUND)

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
wn = world.node_tree
bg_cam = wn.nodes["Background"]
bg_cam.inputs["Color"].default_value = (*lin("#f1ebf8"), 1)
bg_light = wn.nodes.new("ShaderNodeBackground")
bg_light.inputs["Strength"].default_value = 0.35
lp = wn.nodes.new("ShaderNodeLightPath")
wmix = wn.nodes.new("ShaderNodeMixShader")
wn.links.new(lp.outputs["Is Camera Ray"], wmix.inputs[0])
wn.links.new(bg_light.outputs[0], wmix.inputs[1])
wn.links.new(bg_cam.outputs[0], wmix.inputs[2])
wn.links.new(wmix.outputs[0], wn.nodes["World Output"].inputs["Surface"])

sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
sun.data.energy, sun.data.angle = 3.0, math.radians(14)
sun.rotation_euler = (math.radians(55), 0, math.radians(-28))
scene.collection.objects.link(sun)

target = bpy.data.objects.new("CamTarget", None)
target.location = (0, 0, 0.24)
scene.collection.objects.link(target)
cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
cam.data.lens = 50
scene.collection.objects.link(cam)
tr = cam.constraints.new("TRACK_TO")
tr.target, tr.track_axis, tr.up_axis = target, "TRACK_NEGATIVE_Z", "UP_Y"
scene.camera = cam
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = scene.render.resolution_y = 1024
scene.view_settings.view_transform = "Standard"


def render(path, cam_loc, aim=0.24):
    cam.location = cam_loc
    target.location.z = aim
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def apply_look(look):
    set_color(BODY, FLAVORS[look["flavor"]])
    show_top(look["top"])
    set_face(look)


apply_look(DEFAULT_LOOK)
render(os.path.join(OUT, "mochi_3q.png"), (0.75, -1.45, 0.62))
render(os.path.join(OUT, "mochi_front.png"), (0.0, -1.6, 0.42))

# lineup sheet: flavour x topping x face combinations
LINEUP = [
    dict(flavor="strawberry", top="Sprout", eyes="bean", mouth="smile", cheeks="soft", marks="none"),
    dict(flavor="matcha", top="Sakura", eyes="happy", mouth="cat", cheeks="lines", marks="sparkles"),
    dict(flavor="ube", top="Bow", eyes="sparkle", mouth="open", cheeks="soft", marks="hearts"),
    dict(flavor="mango", top="Crown", eyes="angry", mouth="frown", cheeks="rosy", marks="anger"),
    dict(flavor="plain", top="Dango", eyes="sleepy", mouth="ooh", cheeks="soft", marks="sweat"),
    dict(flavor="blueberry", top="Berry", eyes="heart", mouth="grin", cheeks="rosy", marks="none"),
]
tmp = tempfile.mkdtemp()
scene.render.resolution_x = scene.render.resolution_y = 512
tiles = []
for i, look in enumerate(LINEUP):
    apply_look({**DEFAULT_LOOK, **look})
    tiles.append(os.path.join(tmp, f"{i}.png"))
    render(tiles[-1], (0.55, -1.5, 0.55))
scene.render.resolution_x = scene.render.resolution_y = 1024
cols, n, gap = 3, 512, 12
rows = math.ceil(len(tiles) / cols)
sheet = np.ones(((n + gap) * rows + gap, (n + gap) * cols + gap, 4), np.float32)
for i, p in enumerate(tiles):
    img = bpy.data.images.load(p)
    px = np.array(img.pixels[:], np.float32).reshape(n, n, 4)
    bpy.data.images.remove(img)
    r, c = rows - 1 - i // cols, i % cols
    sheet[gap + r * (n + gap):gap + r * (n + gap) + n, gap + c * (n + gap):gap + c * (n + gap) + n] = px
out = bpy.data.images.new("lineup", sheet.shape[1], sheet.shape[0], alpha=True)
out.pixels.foreach_set(sheet.ravel())
out.filepath_raw, out.file_format = os.path.join(OUT, "mochi_lineup.png"), "PNG"
out.save()
bpy.data.images.remove(out)
shutil.rmtree(tmp, ignore_errors=True)
apply_look(DEFAULT_LOOK)

# ---------------------------------------------------------------- web layers for Mochi Maker
L = os.path.join(OUT, "layers")
shutil.rmtree(L, ignore_errors=True)
for k in EYES + ["squeeze"]:  # squeeze is only used while eating, so it isn't a creator option
    cv = Canvas()
    mask = paint_eyes(cv, k, "#ffffff")
    cv.save(os.path.join(L, "eyes", f"{k}.png"))
    m = Canvas()
    m.a = mask
    m.save(os.path.join(L, "eyes", f"{k}_mask.png"))
for group, kinds, painter in (("mouths", MOUTHS + ["gape", "munch"], paint_mouth), ("cheeks", CHEEKS[1:], paint_cheeks),
                              ("marks", MARKS[1:], paint_marks)):
    for k in kinds:
        cv = Canvas(INK)
        painter(cv, k)
        cv.save(os.path.join(L, group, f"{k}.png"))
cv = Canvas()
paint_shine(cv)
cv.save(os.path.join(L, "shine.png"))
with open(os.path.join(L, "layers.json"), "w") as f:
    json.dump({"eyes": EYES, "mouths": MOUTHS, "cheeks": CHEEKS, "marks": MARKS, "flavors": FLAVORS,
               "toppings": ["None", *TOPPINGS], "ink": INK}, f, indent=1)

# ---------------------------------------------------------------- animations (squash & stretch on bone scale)
pb = rig.pose.bones
for b in pb:
    b.rotation_mode = "XYZ"


def all_fcurves(act):
    if getattr(act, "fcurves", None):
        return list(act.fcurves)
    return [fc for layer in act.layers for strip in layer.strips for cb in strip.channelbags for fc in cb.fcurves]


def make_action(name, keys, sparse=False):
    """keys: list of (frame, {bone: dict(loc=, rot=, squash= | s=)}). Bone local Y = world up for these bones.
    Dense actions key every used bone on every listed frame (missing = rest); sparse ones key only what is listed.
    Face-swap bones always switch instantly (constant interpolation)."""
    rig.animation_data_create()
    rig.animation_data.action = None
    used = sorted({b for _, pose in keys for b in pose})
    for frame, pose in keys:
        for b in (pose if sparse else used):
            p = pose.get(b, {})
            pb[b].location = p.get("loc", (0, 0, 0))
            pb[b].rotation_euler = p.get("rot", (0, 0, 0))
            if "s" in p:
                pb[b].scale = (p["s"],) * 3
            else:
                s = p.get("squash", 1.0)  # >1 = squashed (wider, shorter); volume roughly kept
                pb[b].scale = (math.sqrt(s), 1 / s, math.sqrt(s))
            for path in ("location", "rotation_euler", "scale"):
                pb[b].keyframe_insert(path, frame=frame)
    act = rig.animation_data.action
    act.name = name
    act.use_fake_user = True
    for fc in all_fcurves(act):
        if '"face_' in fc.data_path:
            for k in fc.keyframe_points:
                k.interpolation = "CONSTANT"
    for b in pb:
        b.location, b.rotation_euler, b.scale = (0, 0, 0), (0, 0, 0), (1, 1, 1)
    return act


def W(x, y, z):
    """World position -> location of an fx bone (rest head at FX_C, bones point +Z: local = (x, z, -y))."""
    return (x - FX_C[0], z - FX_C[2], -(y - FX_C[1]))


idle = make_action("Idle", [
    (1, {"body": {}, "top": {}}),
    (30, {"body": {"squash": 1.04}, "top": {"rot": (0, 0, 0.06)}}),
    (60, {"body": {}, "top": {}}),
])
bounce = make_action("Bounce", [
    (1, {"root": {}, "body": {}, "top": {}}),
    (6, {"root": {}, "body": {"squash": 1.18}, "top": {"rot": (0.15, 0, 0)}}),
    (12, {"root": {"loc": (0, 0.1, 0)}, "body": {"squash": 0.84}, "top": {"rot": (-0.2, 0, 0)}}),
    (18, {"root": {"loc": (0, 0.16, 0)}, "body": {"squash": 0.97}, "top": {"rot": (-0.05, 0, 0)}}),
    (24, {"root": {"loc": (0, 0.05, 0)}, "body": {"squash": 0.9}, "top": {"rot": (0.1, 0, 0)}}),
    (28, {"root": {}, "body": {"squash": 1.22}, "top": {"rot": (0.22, 0, 0)}}),
    (34, {"root": {}, "body": {"squash": 0.95}, "top": {"rot": (-0.08, 0, 0)}}),
    (40, {"root": {}, "body": {}, "top": {}}),
])
wiggle = make_action("Wiggle", [
    (1, {"body": {}, "top": {}}),
    (7, {"body": {"rot": (0, 0, 0.16), "squash": 1.03}, "top": {"rot": (0, 0, -0.2)}}),
    (15, {"body": {"rot": (0, 0, -0.16), "squash": 1.03}, "top": {"rot": (0, 0, 0.22)}}),
    (23, {"body": {"rot": (0, 0, 0.1)}, "top": {"rot": (0, 0, -0.14)}}),
    (31, {"body": {"rot": (0, 0, -0.05)}, "top": {"rot": (0, 0, 0.08)}}),
    (40, {"body": {}, "top": {}}),
])

rig.animation_data.action = bounce
scene.frame_set(12)
render(os.path.join(OUT, "mochi_bounce.png"), (0.75, -1.45, 0.62), aim=0.3)
rig.animation_data.action = None
for b in pb:
    b.location, b.rotation_euler, b.scale = (0, 0, 0), (0, 0, 0), (1, 1, 1)
scene.frame_set(1)


# ---------------------------------------------------------------- EMOTES
def face_keys(e, start, end):
    """Swap to emote e's face from `start` until `end` (instant, both ways)."""
    return [(1, {"face_main": {}, f"face_{e}": {}}),
            (start, {"face_main": {"s": GONE}, f"face_{e}": {"s": SHOW}}),
            (end, {"face_main": {}, f"face_{e}": {}})]


def pop(bone, t0, t1, pos, rot=(0, 0, 0), wobble=0.0, size=1.0):
    """Effect that pops in at `pos` on t0, bobs a little, and shrinks away by t1."""
    return [(t0 - 1, {bone: {"loc": W(*pos)}}),
            (t0 + 4, {bone: {"loc": W(*pos), "s": SHOW * size * 1.3, "rot": (0, 0, rot[2] + wobble)}}),
            (t0 + 8, {bone: {"loc": W(*pos), "s": SHOW * size, "rot": rot}}),
            (t1 - 6, {bone: {"loc": W(*pos), "s": SHOW * size, "rot": (0, 0, rot[2] - wobble)}}),
            (t1, {bone: {"loc": W(*pos)}})]


def drift(bone, t0, t1, p0, p1, rot=(0, 0, 0), size=1.0):
    """Effect that grows at p0, floats to p1 and shrinks away."""
    mid = tuple(a + (b - a) * 0.8 for a, b in zip(p0, p1))
    return [(t0, {bone: {"loc": W(*p0)}}),
            (t0 + 6, {bone: {"loc": W(*p0), "s": SHOW * size}}),
            (t1 - 6, {bone: {"loc": W(*mid), "s": SHOW * size * 1.05, "rot": rot}}),
            (t1, {bone: {"loc": W(*p1), "rot": rot}})]


def body_keys(frames):
    return [(f, {"root": pose.get("root", {}), "body": pose.get("body", {}), "top": pose.get("top", {})})
            for f, pose in frames]


EMOTE_LENGTH = {"happy": 60, "love": 72, "angry": 60, "sad": 80, "surprised": 45, "sleepy": 90}
EMOTE_KEYS = {
    "happy": face_keys("happy", 3, 57) + body_keys([
        (1, {}), (6, {"body": {"squash": 1.2}}),
        (12, {"root": {"loc": (0, 0.15, 0)}, "body": {"squash": 0.84}, "top": {"rot": (-0.25, 0, 0)}}),
        (18, {"root": {"loc": (0, 0.2, 0)}, "body": {"squash": 0.97}}),
        (24, {"body": {"squash": 1.18}, "top": {"rot": (0.25, 0, 0)}}),
        (30, {"root": {"loc": (0, 0.08, 0)}, "body": {"squash": 0.9}}),
        (36, {"body": {"squash": 1.1}}), (42, {"body": {"squash": 0.97}}), (60, {})])
        + pop("fx_sparkle1", 10, 54, (0.27, -0.06, 0.5), wobble=0.4)
        + pop("fx_sparkle2", 14, 54, (-0.28, -0.06, 0.4), wobble=-0.4, size=0.75)
        + pop("fx_sparkle3", 18, 54, (0.17, -0.1, 0.68), wobble=0.5, size=0.6),
    "love": face_keys("love", 3, 69) + body_keys([
        (1, {}), (12, {"body": {"rot": (0, 0, 0.12), "squash": 1.05}, "top": {"rot": (0, 0, -0.15)}}),
        (24, {"body": {"rot": (0, 0, -0.12), "squash": 1.05}, "top": {"rot": (0, 0, 0.15)}}),
        (36, {"body": {"rot": (0, 0, 0.12), "squash": 1.05}, "top": {"rot": (0, 0, -0.15)}}),
        (48, {"body": {"rot": (0, 0, -0.12), "squash": 1.05}, "top": {"rot": (0, 0, 0.15)}}),
        (60, {"body": {"rot": (0, 0, 0.05)}}), (72, {})])
        + drift("fx_heart1", 4, 40, (0.12, -0.12, 0.42), (0.2, -0.12, 0.82), rot=(0, 0, -0.25))
        + drift("fx_heart2", 16, 52, (-0.14, -0.12, 0.42), (-0.24, -0.12, 0.78), rot=(0, 0, 0.25), size=0.8)
        + drift("fx_heart3", 30, 68, (0.04, -0.12, 0.45), (0.06, -0.12, 0.86), rot=(0, 0, -0.1), size=0.65),
    "angry": face_keys("angry", 3, 57) + body_keys(
        [(1, {}), (6, {"body": {"squash": 1.16, "rot": (0.08, 0, 0)}, "top": {"rot": (0.2, 0, 0)}})]
        + [(f, {"body": {"squash": 1.13, "rot": (0.08, 0, 0.07 if i % 2 else -0.07)}, "top": {"rot": (0.2, 0, 0)}})
           for i, f in enumerate(range(9, 45, 3))]
        + [(48, {"root": {"loc": (0, 0.07, 0)}, "body": {"squash": 0.9}}),
           (52, {"body": {"squash": 1.22}}), (56, {"body": {"squash": 0.98}}), (60, {})])
        + [(3, {"fx_anger": {"loc": W(0.25, -0.1, 0.47)}})]
        + [(f, {"fx_anger": {"loc": W(0.25, -0.1, 0.47), "s": SHOW * (1.3 if i % 2 == 0 else 0.95)}})
           for i, f in enumerate(range(7, 52, 5))]
        + [(57, {"fx_anger": {"loc": W(0.25, -0.1, 0.47)}})],
    "sad": face_keys("sad", 3, 77) + body_keys([
        (1, {}), (15, {"body": {"squash": 1.15, "rot": (0.12, 0, 0)}, "top": {"rot": (0.45, 0, 0)}}),
        (40, {"body": {"squash": 1.19, "rot": (0.1, 0, 0.05)}, "top": {"rot": (0.5, 0, 0.1)}}),
        (62, {"body": {"squash": 1.15, "rot": (0.12, 0, -0.05)}, "top": {"rot": (0.45, 0, -0.1)}}),
        (75, {"body": {"squash": 1.04}}), (80, {})])
        + [k for t0, n, sx in ((10, "tear1", -1), (18, "tear2", 1), (42, "tear1", -1), (50, "tear2", 1))
           for k in [(t0, {f"fx_{n}": {"loc": W(sx * 0.115, -0.31, 0.19)}}),
                     (t0 + 4, {f"fx_{n}": {"loc": W(sx * 0.118, -0.32, 0.17), "s": SHOW}}),
                     (t0 + 20, {f"fx_{n}": {"loc": W(sx * 0.13, -0.37, 0.04), "s": SHOW * 0.85}}),
                     (t0 + 24, {f"fx_{n}": {"loc": W(sx * 0.13, -0.37, 0.02)}})]],
    "surprised": face_keys("surprised", 3, 42) + body_keys([
        (1, {}), (4, {"body": {"squash": 1.15}}),
        (8, {"root": {"loc": (0, 0.12, 0)}, "body": {"squash": 0.76}, "top": {"rot": (-0.3, 0, 0)}}),
        (14, {"root": {"loc": (0, 0.14, 0)}, "body": {"squash": 0.82}}),
        (20, {"body": {"squash": 1.12}, "top": {"rot": (0.2, 0, 0)}}),
        (26, {"body": {"squash": 0.95}}), (32, {}), (45, {})])
        + pop("fx_bang", 6, 42, (0.24, -0.06, 0.6), rot=(0, 0, -0.15), wobble=0.3),
    "sleepy": face_keys("sleepy", 2, 89) + body_keys([
        (1, {}), (22, {"body": {"squash": 1.08, "rot": (0.04, 0, 0.05)}, "top": {"rot": (0.2, 0, 0.1)}}),
        (45, {"body": {"squash": 0.98, "rot": (0.02, 0, 0)}}),
        (67, {"body": {"squash": 1.08, "rot": (0.04, 0, -0.04)}, "top": {"rot": (0.2, 0, -0.1)}}),
        (90, {})])
        + drift("fx_z1", 6, 40, (0.16, -0.08, 0.47), (0.3, -0.08, 0.74), rot=(0, 0, -0.25), size=0.7)
        + drift("fx_z2", 30, 64, (0.16, -0.08, 0.47), (0.3, -0.08, 0.74), rot=(0, 0, -0.25), size=0.9)
        + drift("fx_z3", 54, 88, (0.16, -0.08, 0.47), (0.3, -0.08, 0.74), rot=(0, 0, -0.25), size=1.1),
}
EMOTE_ACTIONS = {e: make_action(e.capitalize(), sorted(EMOTE_KEYS[e], key=lambda k: k[0]), sparse=True)
                 for e in EMOTES}

# emote sheet (one key frame each) + a video of all six, with a caption under the mochi
cap_mat = bpy.data.materials.new("Caption")
cap_mat.use_nodes = True
_ce = cap_mat.node_tree.nodes.new("ShaderNodeEmission")
_ce.inputs["Color"].default_value = (*lin(INK), 1)
cap_mat.node_tree.links.new(_ce.outputs[0], cap_mat.node_tree.nodes["Material Output"].inputs["Surface"])
caption = bpy.data.objects.new("Caption", bpy.data.curves.new("Caption", "FONT"))
caption.data.align_x, caption.data.size = "CENTER", 0.045
caption.data.materials.append(cap_mat)
scene.collection.objects.link(caption)
caption.parent = cam
caption.location = (0, -0.3, -1.0)  # in front of the lens, near the bottom of the frame
EMOTE_CAM, EMOTE_AIM = (0.45, -1.55, 0.5), 0.32
KEY_FRAME = {"happy": 15, "love": 26, "angry": 21, "sad": 36, "surprised": 12, "sleepy": 60}


def play_emote(e, frame):
    rig.animation_data.action = EMOTE_ACTIONS[e]
    for b in pb:  # Blender keeps un-keyed channels from the last action; engines reset them, so match that
        b.location, b.rotation_euler, b.scale = (0, 0, 0), (0, 0, 0), (1, 1, 1)
    caption.data.body = e.capitalize()
    scene.frame_set(frame)


tmp = tempfile.mkdtemp()
scene.render.resolution_x = scene.render.resolution_y = 512
tiles = []
for e in EMOTES:
    play_emote(e, KEY_FRAME[e])
    tiles.append(os.path.join(tmp, f"key_{e}.png"))
    render(tiles[-1], EMOTE_CAM, EMOTE_AIM)
cols, n, gap = 3, 512, 12
rows = math.ceil(len(tiles) / cols)
sheet = np.ones(((n + gap) * rows + gap, (n + gap) * cols + gap, 4), np.float32)
for i, p in enumerate(tiles):
    img = bpy.data.images.load(p)
    px = np.array(img.pixels[:], np.float32).reshape(n, n, 4)
    bpy.data.images.remove(img)
    r, c = rows - 1 - i // cols, i % cols
    sheet[gap + r * (n + gap):gap + r * (n + gap) + n, gap + c * (n + gap):gap + c * (n + gap) + n] = px
out = bpy.data.images.new("emotes", sheet.shape[1], sheet.shape[0], alpha=True)
out.pixels.foreach_set(sheet.ravel())
out.filepath_raw, out.file_format = os.path.join(OUT, "mochi_emotes.png"), "PNG"
out.save()
bpy.data.images.remove(out)

if "--no-video" not in sys.argv:
    frames = []
    for e in EMOTES:
        for f in range(1, EMOTE_LENGTH[e] + 1):
            play_emote(e, f)
            frames.append(os.path.join(tmp, f"v_{len(frames):05d}.png"))
            render(frames[-1], EMOTE_CAM, EMOTE_AIM)
    enc = bpy.data.scenes.new("Encode")
    enc.render.resolution_x = enc.render.resolution_y = 512
    enc.render.fps = 30
    enc.view_settings.view_transform = "Standard"
    enc.sequence_editor_create()
    se = enc.sequence_editor
    strips = se.strips if hasattr(se, "strips") else se.sequences
    st = strips.new_image(name="frames", filepath=frames[0], channel=1, frame_start=1)
    for p in frames[1:]:
        st.elements.append(os.path.basename(p))
    enc.frame_start, enc.frame_end = 1, len(frames)
    fmt = enc.render.image_settings
    if hasattr(fmt, "media_type"):
        fmt.media_type = "VIDEO"
    fmt.file_format = "FFMPEG"
    enc.render.ffmpeg.format, enc.render.ffmpeg.codec = "MPEG4", "H264"
    enc.render.ffmpeg.constant_rate_factor = "HIGH"
    enc.render.filepath = os.path.join(OUT, "mochi_emotes.mp4")
    bpy.ops.render.render(animation=True, scene=enc.name)
    bpy.data.scenes.remove(enc)
shutil.rmtree(tmp, ignore_errors=True)
scene.render.resolution_x = scene.render.resolution_y = 1024
caption.hide_render = True
rig.animation_data.action = None
for b in pb:
    b.location, b.rotation_euler, b.scale = (0, 0, 0), (0, 0, 0), (1, 1, 1)
scene.frame_set(1)

# ---------------------------------------------------------------- export + save
FACE_IMG.filepath_raw, FACE_IMG.file_format = os.path.join(OUT, "mochi_face.png"), "PNG"
FACE_IMG.save()
use_export_shading(True)
bpy.ops.object.select_all(action="DESELECT")
rig.select_set(True)
for o in SLOT_OBJECTS.values():
    o.select_set(True)
bpy.context.view_layer.objects.active = rig
gl_args = dict(use_selection=True, export_animations=True, export_animation_mode="ACTIONS", export_apply=False)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "mochi.glb"), **gl_args)
tmp = tempfile.mkdtemp()  # self-contained glTF JSON copy for web hosts that only serve .json
bpy.ops.export_scene.gltf(filepath=os.path.join(tmp, "web.gltf"), export_format="GLTF_SEPARATE", **gl_args)
with open(os.path.join(tmp, "web.gltf")) as f:
    gl = json.load(f)
for item, mime in [(b, "application/octet-stream") for b in gl.get("buffers", [])] + \
                  [(i, i.get("mimeType", "image/png")) for i in gl.get("images", []) if "uri" in i]:
    with open(os.path.join(tmp, item["uri"]), "rb") as f:
        item["uri"] = f"data:{mime};base64," + base64.b64encode(f.read()).decode()
with open(os.path.join(OUT, "mochi.gltf.json"), "w") as f:
    json.dump(gl, f, separators=(",", ":"))
shutil.rmtree(tmp, ignore_errors=True)
use_export_shading(False)
show_top(DEFAULT_LOOK["top"])
for s in TOP_SLOTS:
    SLOT_OBJECTS[s].hide_set(s != f"Top_{DEFAULT_LOOK['top']}")
    OUTLINES[s].hide_set(s != f"Top_{DEFAULT_LOOK['top']}")
FACE_IMG.pack()
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "mochi.blend"))
print("DONE", {k: len(v.data.polygons) for k, v in SLOT_OBJECTS.items()})
