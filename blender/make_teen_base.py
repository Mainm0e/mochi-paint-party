"""Rigged, modular chibi teen-girl base character (v2: big-head toy-chibi style, soft toon shading).

Each slot (Body, Face, Eyes, Hair, Top, Bottom, Socks, Shoes) is its own mesh, skinned to one
shared armature, so slots can be swapped for new hairstyles, eyes and outfits later.
Face and Eyes are thin decal shells over the flattened front of the head, painted with
generated textures (teen_face.png, teen_eyes.png) so expressions can be swapped as images.

Run:  blender --background --factory-startup --python make_teen_base.py -- <out_dir>
"""
import math
import os
import sys
from collections import defaultdict

import bmesh
import bpy
import numpy as np
from mathutils import Euler, Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.dirname(__file__)
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = 30


def srgb(h):
    return np.array([int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)])


def lin(h):
    c = srgb(h)
    return tuple(np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4))


# ---------------------------------------------------------------- toon materials
# Rendered look: 2-band soft toon ramp + faint fresnel rim (EEVEE Shader-to-RGB).
# The Principled BSDF in each material is kept for glTF export (see use_export_shading).
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


def _ramp(nt, src, p0, p1, c0=(0, 0, 0, 1), c1=(1, 1, 1, 1), interp="EASE"):
    r = nt.nodes.new("ShaderNodeValToRGB")
    r.color_ramp.interpolation = interp
    e0, e1 = r.color_ramp.elements
    e0.position, e0.color = p0, c0
    e1.position, e1.color = p1, c1
    nt.links.new(src, r.inputs[0])
    return r.outputs[0]


def mat(name, base, shadow, img=None, rim=0.16, band=None):
    """base/shadow are sRGB hex; band=(hex, strength) adds a glossy 'halo' ring (hair)."""
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf, out = nt.nodes["Principled BSDF"], nt.nodes["Material Output"]
    bsdf.inputs["Roughness"].default_value = 0.8
    tint = tuple(s / max(b, 1e-6) for s, b in zip(lin(shadow), lin(base))) + (1,)
    if img:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image, tex.interpolation = img, "Cubic"
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
        color = tex.outputs["Color"]
    else:
        bsdf.inputs["Base Color"].default_value = (*lin(base), 1)
        rgb = nt.nodes.new("ShaderNodeRGB")
        rgb.outputs[0].default_value = (*lin(base), 1)
        color = rgb.outputs[0]
    diff = nt.nodes.new("ShaderNodeBsdfDiffuse")
    s2r = nt.nodes.new("ShaderNodeShaderToRGB")
    nt.links.new(diff.outputs[0], s2r.inputs[0])
    light = _ramp(nt, s2r.outputs["Color"], 0.36, 0.52)
    shade = _mix(nt, "MULTIPLY", 1.0, color, tint)
    col = _mix(nt, "MIX", light, shade, color)
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.35
    col = _mix(nt, "ADD", _ramp(nt, lw.outputs["Facing"], 0.7, 0.95, c1=(rim, rim, rim, 1)), col,
               (1.0, 0.97, 1.0, 1))
    if band:
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Normal"], sep.inputs[0])
        z = sep.outputs["Z"]
        lo = _ramp(nt, z, 0.42, 0.56)
        hi = _ramp(nt, z, 0.7, 0.84, c0=(1, 1, 1, 1), c1=(0, 0, 0, 1))
        ring = _mix(nt, "MULTIPLY", 1.0, lo, hi)
        ring = _mix(nt, "MULTIPLY", 1.0, ring, light)
        bw = nt.nodes.new("ShaderNodeRGBToBW")
        nt.links.new(ring, bw.inputs[0])
        col = _mix(nt, "MIX", bw.outputs[0], col, (*lin(band[0]), 1))
    emit = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(col, emit.inputs["Color"])
    toon = emit.outputs[0]
    if img:
        mix = nt.nodes.new("ShaderNodeMixShader")
        nt.links.new(tex.outputs["Alpha"], mix.inputs[0])
        nt.links.new(nt.nodes.new("ShaderNodeBsdfTransparent").outputs[0], mix.inputs[1])
        nt.links.new(toon, mix.inputs[2])
        toon = mix.outputs[0]
        m.surface_render_method = "BLENDED"
    nt.links.new(toon, out.inputs["Surface"])
    m["toon_socket"] = toon.node.name
    MATS[name] = m
    return m


def use_export_shading(export):
    """Swap every material between the toon render graph and plain Principled (for glTF)."""
    for m in MATS.values():
        nt = m.node_tree
        src = nt.nodes["Principled BSDF"] if export else nt.nodes[m["toon_socket"]]
        nt.links.new(src.outputs[0], nt.nodes["Material Output"].inputs["Surface"])


# ---------------------------------------------------------------- painted face textures
TEX_N, TEX_X0, TEX_Z0, TEX_S = 1024, -0.2, 0.42, 0.4  # texture covers x[-.2,.2] z[.42,.82] of the face
_g = (np.arange(TEX_N) + 0.5) / TEX_N * TEX_S
GX, GZ = np.meshgrid(TEX_X0 + _g, TEX_Z0 + _g)
PX = TEX_S / TEX_N


def cov(d):
    return np.clip(0.5 - d / PX, 0, 1)


def ell(dx, dz, a, b):
    """Signed distance (approx.) to an ellipse, plus its normalised radius."""
    r = np.sqrt((dx / a) ** 2 + (dz / b) ** 2) + 1e-9
    gx, gz = dx / (a * a * r), dz / (b * b * r)
    return (r - 1) / np.sqrt(gx * gx + gz * gz + 1e-12), r


def seg(px, pz, p0, p1, r0, r1):
    """Distance to a tapered capsule from p0 (radius r0) to p1 (radius r1)."""
    vx, vz = p1[0] - p0[0], p1[1] - p0[1]
    t = np.clip(((px - p0[0]) * vx + (pz - p0[1]) * vz) / (vx * vx + vz * vz), 0, 1)
    return np.hypot(px - p0[0] - t * vx, pz - p0[1] - t * vz) - (r0 + (r1 - r0) * t)


class Canvas:
    def __init__(self, bg):
        self.c = np.ones((TEX_N, TEX_N, 3)) * srgb(bg)  # transparent pixels keep bg colour (no dark fringes)
        self.a = np.zeros((TEX_N, TEX_N))

    def paint(self, cover, col, alpha=1.0):
        a = np.clip(cover * alpha, 0, 1)
        col = srgb(col) if isinstance(col, str) else col
        out = a + self.a * (1 - a)
        w = np.where(out > 0, a / np.maximum(out, 1e-6), 0)[..., None]
        self.c = self.c * (1 - w) + col * w
        self.a = out

    def image(self, name, sub="faces", keep=True):
        img = bpy.data.images.new(name, TEX_N, TEX_N, alpha=True)
        img.pixels.foreach_set(np.dstack([self.c, self.a]).astype(np.float32).ravel())
        os.makedirs(os.path.join(OUT, sub), exist_ok=True)
        img.filepath_raw = os.path.join(OUT, sub, name + ".png")
        img.file_format = "PNG"
        img.save()
        if not keep:  # web layer only: written to disk, not stored in the .blend
            bpy.data.images.remove(img)
            return None
        img.pack()
        return img


SKIN_HEX, SKIN_SHADOW = "#FFE4D6", "#F2B9B0"
EX, EZ, MZ = 0.088, 0.596, 0.512  # eye centre x/z, mouth z (face texture space, before HEAD_DROP)
LASH_HEX = "#2B1B24"

# Face presets: each is a pair of textures (eyes_<name>.png on Teen_Eyes, face_<name>.png on Teen_Face).
FACE_DEFAULT = dict(
    ea=0.046, ebt=0.053, ebb=0.053,  # eye half width, half height above / below centre
    tilt=0.0,                        # radians, + lifts the outer corner
    iris=("#8FD9FF", "#2C3E8E"),     # bottom / top of the iris gradient
    pupil=1.0, hl="round", lash=1.0, lower=True, crease=True, closed=False,
    brow=dict(z=0.094, x=0.0, len=0.021, th=0.0034, slope=0.0, arch=0.005),
    mouth="smile", blush=0.5, blush_lines=False,
)
FACES = {
    "sunny": dict(),
    "sleepy": dict(ebt=0.03, tilt=-0.08, iris=("#FFD48A", "#9A5A1E"), lash=0.8, crease=False,
                   brow=dict(z=0.09, slope=-0.06, arch=0.003), mouth="o", blush=0.35),
    "sharp": dict(ea=0.049, ebt=0.044, ebb=0.046, tilt=0.18, iris=("#C4F59A", "#2E6B3A"), pupil=0.85, lash=1.2,
                  brow=dict(z=0.088, slope=0.12, arch=0.002, th=0.0038), mouth="cat", blush=0.3),
    "sparkle": dict(ea=0.048, ebt=0.058, ebb=0.058, iris=("#FFC4EC", "#8C3A9E"), hl="star",
                    mouth="open", blush=0.6),
    "calm": dict(ebt=0.048, ebb=0.05, iris=("#DCD8F7", "#5B5590"), lash=0.7, lower=False,
                 brow=dict(z=0.09, slope=0.0, arch=0.002), mouth="line", blush=0.4),
    "happy": dict(closed=True, brow=dict(z=0.098, arch=0.007), mouth="open", blush=0.7, blush_lines=True),
    "determined": dict(ebt=0.046, tilt=0.1, iris=("#FFAE8A", "#7A2224"), lash=1.15,
                       brow=dict(z=0.082, slope=0.22, arch=0.0, th=0.0046, len=0.024), mouth="line", blush=0.3),
    "shy": dict(ebt=0.05, ebb=0.055, tilt=-0.04, iris=("#A6F2E8", "#1F6E78"), hl="sparkle",
                brow=dict(z=0.096, slope=-0.16, arch=0.003), mouth="wavy", blush=0.85, blush_lines=True),
}


def face_style(name):
    st = {**FACE_DEFAULT, **FACES[name]}
    st["brow"] = {**FACE_DEFAULT["brow"], **FACES[name].get("brow", {})}
    return st


def paint_eyes(name):
    return paint_eyes_canvas(face_style(name))[0].image(f"eyes_{name}")


def paint_eyes_canvas(st):
    """Eyes for style st; also returns the iris mask (minus highlights) so the web creator can recolour it."""
    ea, ebt, ebb = st["ea"], st["ebt"], st["ebb"]
    cv = Canvas("#FFFFFF")
    iris_mask, hl_mask = np.zeros((TEX_N, TEX_N)), np.zeros((TEX_N, TEX_N))
    for sx in (1, -1):
        dx0, dz0 = sx * GX - EX, GZ - EZ  # dx > 0 points to the outer corner
        c, s = math.cos(st["tilt"]), math.sin(st["tilt"])
        dx, dz = dx0 * c + dz0 * s, -dx0 * s + dz0 * c
        if st["closed"]:  # happy closed eye: a bold upward arc
            d, _ = ell(dx, dz + ebt * 0.25, ea * 0.95, ebt * 0.6)
            cv.paint(cov(np.abs(d) - 0.0045) * np.clip((dz + ebt * 0.25) / 0.004, 0, 1), LASH_HEX)
            continue
        eb = np.where(dz > 0, ebt, ebb)
        d_eye, r_eye = ell(dx, dz, ea, eb)
        th = np.arctan2(dz / eb, dx / ea)
        inside = cov(d_eye)
        cv.paint(inside, "#FFFFFF")
        cv.paint(inside * ((r_eye > 0.72) & (th > 0.25) & (th < 2.85)), "#CBC8EA", 0.55)  # lid shadow
        ia, ib = 0.84 * ea, 0.93 * ebb
        d_i, r_i = ell(dx + 0.09 * ea, dz + 0.09 * ebb, ia, ib)
        iris = cov(np.maximum(d_i, d_eye))
        iris_mask = np.maximum(iris_mask, iris)
        t = np.clip((dz + 0.09 * ebb + ib) / (2 * ib), 0, 1)[..., None] ** 0.9
        cv.paint(iris, srgb(st["iris"][0]) * (1 - t) + srgb(st["iris"][1]) * t)
        cv.paint(iris * np.clip((r_i - 0.8) / 0.12, 0, 1), srgb(st["iris"][1]) * 0.7, 0.85)
        p = st["pupil"]
        cv.paint(cov(np.maximum(ell(dx + 0.09 * ea, dz, 0.36 * ea * p, 0.45 * ebb * p)[0], d_eye)),
                 srgb(st["iris"][1]) * 0.45)
        _, r_g = ell(dx + 0.09 * ea, dz + 0.55 * ebb, 0.55 * ea, 0.23 * ebb)
        cv.paint(iris * np.clip(1 - r_g ** 2, 0, 1), "#FFFFFF", 0.45)
        # thick upper lash line, thicker toward the outer corner, plus a small wing
        w = np.clip((th + 0.2) / 0.7, 0, 1) * (0.3 + 0.7 * np.clip((2.95 - th) / 2.3, 0, 1))
        out_r = 0.96 + 0.3 * w * st["lash"]
        d_lash = np.maximum((r_eye - out_r) * ea, (0.9 - r_eye) * ea)
        ends = np.clip((2.95 - th) / 0.15, 0, 1) * (th > -0.25)
        cv.paint(cov(d_lash) * ends, LASH_HEX)
        cv.paint(cov(seg(dx, dz, (ea * 0.9, ebt * 0.28), (ea * 1.3, ebt * 0.28 + 0.017), 0.0075 * st["lash"],
                         0.0018)), LASH_HEX)
        if st["lower"]:
            cv.paint(((r_eye > 1.0) & (r_eye < 1.07) & (th > -1.35) & (th < -0.4)).astype(float), "#7B4B55", 0.75)
        if st["crease"]:
            cv.paint(((r_eye > 1.33) & (r_eye < 1.37) & (th > 0.75) & (th < 2.25)).astype(float), "#D99A92", 0.6)
        # highlights stay on the same (screen-left, upper) side for both eyes
        xc, hz = sx * EX, EZ + 0.36 * min(ebt, ebb) * (1 if ebt > 0.04 else 0.3)
        hx, sz = xc - 0.27 * ea, 0.3 * ea
        if st["hl"] == "star":
            star = np.minimum(ell(GX - hx, GZ - hz, sz * 1.25, sz * 0.22)[0], ell(GX - hx, GZ - hz, sz * 0.22, sz * 1.25)[0])
            hls = [inside * cov(np.minimum(star, np.hypot(GX - hx, GZ - hz) - sz * 0.42))]
        else:
            hls = [inside * cov(np.hypot(GX - hx, GZ - hz) - sz)]
        hls.append(inside * cov(np.hypot(GX - xc - 0.3 * ea, GZ - EZ + 0.43 * ebb) - 0.13 * ea))
        if st["hl"] == "sparkle":
            for ox, oz, r in ((0.05 * ea, 0.62, 0.07), (-0.45 * ea, -0.2, 0.06)):
                hls.append(inside * cov(np.hypot(GX - xc - ox, GZ - EZ - oz * ebb) - r * ea))
        for h in hls:
            cv.paint(h, "#FFFFFF")
            hl_mask = np.maximum(hl_mask, h)
    return cv, iris_mask * (1 - hl_mask)


def paint_blush(cv, strength, lines=False):
    for sx in (1, -1):
        d, r = ell(sx * GX - 0.138, GZ - 0.536, 0.034, 0.018)
        cv.paint(np.clip(1 - r ** 2, 0, 1) ** 0.8, "#FF8DA1", strength)
        if lines:
            for i in (-1, 0, 1):
                bx = sx * (0.138 + i * 0.011)
                cv.paint(cov(seg(GX, GZ, (bx + sx * 0.004, 0.543), (bx - sx * 0.002, 0.531), 0.0013, 0.0011)),
                         "#F0708A", 0.8)


def paint_brows(cv, b, color="#7A4A3E"):
    for sx in (1, -1):
        u = sx * GX - (EX + b["x"])
        uc = np.clip(u / b["len"], -1, 1)
        zc = EZ + b["z"] + b["arch"] * (1 - uc ** 2) + b["slope"] * u
        d_b = np.hypot(np.maximum(np.abs(u) - b["len"], 0), GZ - zc) - b["th"] * (1 - 0.45 * np.clip(uc, 0, 1))
        cv.paint(cov(d_b), color)


def paint_mouth(cv, kind):
    mx, mz = GX, GZ - MZ
    tm = np.arctan2(mz, mx)
    lip = "#A2544F"
    if kind in ("smile", "tongue"):
        cv.paint(cov(np.abs(np.hypot(mx, mz) - 0.0105) - 0.0021) * ((tm > -2.45) & (tm < -0.7)), lip)
        if kind == "tongue":
            cv.paint(cov(np.maximum(ell(mx - 0.003, mz + 0.0118, 0.0046, 0.0052)[0], mz + 0.0095)), "#F28A9A")
    elif kind in ("open", "grin"):
        w = 0.0125 if kind == "open" else 0.017
        d_m = np.maximum(ell(mx, mz - 0.004, w, 0.0125)[0], mz - 0.004)
        cv.paint(cov(d_m), "#9C3B44")
        cv.paint(cov(np.maximum(np.hypot(mx, mz + 0.0095) - 0.0065, d_m)), "#F08A96")
        if kind == "grin":  # top teeth
            cv.paint(cov(np.maximum(d_m, -(mz - 0.0005))), "#FFFFFF")
    elif kind == "cat":
        for ox in (-0.0072, 0.0072):
            r_c = np.hypot(mx - ox, mz - 0.003)
            t_c = np.arctan2(mz - 0.003, mx - ox)
            cv.paint(cov(np.abs(r_c - 0.0072) - 0.0018) * ((t_c > -3.0) & (t_c < -0.14)), lip)
    elif kind == "line":
        cv.paint(cov(np.hypot(np.maximum(np.abs(mx) - 0.008, 0), mz) - 0.0018), lip)
    elif kind == "o":
        cv.paint(cov(np.abs(ell(mx, mz + 0.002, 0.0058, 0.0068)[0]) - 0.0017), lip)
    elif kind == "wavy":
        wz = 0.0022 * np.sin(mx / 0.0045 * math.pi)
        cv.paint(cov(np.hypot(np.maximum(np.abs(mx) - 0.0115, 0), mz - wz) - 0.0017), lip)


def paint_face(name):
    st = face_style(name)
    cv = Canvas(SKIN_HEX)
    paint_blush(cv, st["blush"], st["blush_lines"])
    paint_brows(cv, st["brow"])
    paint_mouth(cv, st["mouth"])
    return cv.image(f"face_{name}")


# ---------------------------------------------------------------- web creator layers (layers/*.png + layers.json)
# Eyes are painted with a grey iris plus an iris mask, so the creator can tint any eye shape any colour.
# Brows are white (tinted from the hair colour in the creator); mouths and blush keep their own colours.
WEB_EYES = {"round": "sunny", "sleepy": "sleepy", "cat": "sharp", "starry": "sparkle", "gentle": "calm",
            "smile": "happy", "fierce": "determined", "dewy": "shy"}
WEB_BROWS = {"soft": {}, "flat": dict(arch=0.0015), "arched": dict(z=0.099, arch=0.009),
             "worried": dict(slope=-0.16, arch=0.003), "fierce": dict(z=0.084, slope=0.2, arch=0.0, th=0.0045, len=0.024),
             "bold": dict(th=0.0056, len=0.023, arch=0.004)}
WEB_MOUTHS = ["smile", "open", "grin", "cat", "tongue", "line", "o", "wavy"]
WEB_BLUSH = {"soft": (0.5, False), "rosy": (0.85, False), "lines": (0.6, True)}
WEB_IRIS = {"sky": "#7FC8F8", "honey": "#F2B35A", "leaf": "#8FD46A", "berry": "#D98BE8", "lilac": "#B9B2EE",
            "ember": "#F08A6A", "lagoon": "#6ED8CC", "ash": "#B8BCC8"}


def export_web_layers():
    import json
    for name, preset in WEB_EYES.items():
        st = face_style(preset)
        st["iris"] = ("#F4F4F4", "#454545")
        cv, mask = paint_eyes_canvas(st)
        cv.image(name, "layers/eyes", keep=False)
        m = Canvas("#FFFFFF")
        m.a = mask
        m.image(f"{name}_iris", "layers/eyes", keep=False)
    for name, over in WEB_BROWS.items():
        cv = Canvas("#FFFFFF")
        paint_brows(cv, {**FACE_DEFAULT["brow"], **over}, "#FFFFFF")
        cv.image(name, "layers/brows", keep=False)
    for name in WEB_MOUTHS:
        cv = Canvas("#A2544F")
        paint_mouth(cv, name)
        cv.image(name, "layers/mouths", keep=False)
    for name, (strength, lines) in WEB_BLUSH.items():
        cv = Canvas("#FF8DA1")
        paint_blush(cv, strength, lines)
        cv.image(name, "layers/blush", keep=False)
    with open(os.path.join(OUT, "layers", "layers.json"), "w") as f:
        json.dump({"eyes": list(WEB_EYES), "brows": list(WEB_BROWS), "mouths": WEB_MOUTHS,
                   "blush": ["none", *WEB_BLUSH], "iris": WEB_IRIS, "hair": list(HAIR_STYLES)}, f, indent=1)


SKIN = mat("Skin", SKIN_HEX, SKIN_SHADOW)
SUIT = mat("BaseSuit", "#A3A3B4", "#7C7C94")
FACE_IMAGES = {n: (paint_eyes(n), paint_face(n)) for n in FACES}
DEFAULT_FACE = "sunny"
EYES = mat("EyesDecal", SKIN_HEX, SKIN_SHADOW, img=FACE_IMAGES[DEFAULT_FACE][0], rim=0.0)
FACE = mat("FaceDecal", SKIN_HEX, SKIN_SHADOW, img=FACE_IMAGES[DEFAULT_FACE][1], rim=0.0)


def set_face(name):
    for m, img in zip((EYES, FACE), FACE_IMAGES[name]):
        next(n for n in m.node_tree.nodes if n.type == "TEX_IMAGE").image = img


HAIR = mat("Hair", "#8F5E4A", "#5F3A36", band=("#C49478", 1))
HAIR_TIE = mat("HairTie", "#F59AB4", "#CF7090")
TOP = mat("TopLavender", "#CBB6F2", "#9F8BD2")
TOP_TRIM = mat("TopTrim", "#FFFFFF", "#D9D2EE")
SKIRT = mat("SkirtBlue", "#7E95D3", "#5C6DAA")
SKIRT_BAND = mat("SkirtBand", "#6A7FC0", "#4E5C98")
SOCK = mat("Sock", "#FFFFFF", "#D9D4EA")
SHOE = mat("ShoeWhite", "#FFFFFF", "#D6D1E8")
SOLE = mat("ShoePink", "#F7A2B8", "#D47892")

# ---------------------------------------------------------------- skeleton
# name: (head, tail, parent)   character faces -Y, Z up, ~0.95 unit tall, head ~half the height
BONES = {
    "root": ((0, 0, 0), (0, 0, 0.08), None),
    "hips": ((0, 0, 0.19), (0, 0, 0.24), "root"),
    "spine": ((0, 0, 0.24), (0, 0, 0.3), "hips"),
    "chest": ((0, 0, 0.3), (0, 0, 0.38), "spine"),
    "neck": ((0, 0, 0.38), (0, 0, 0.43), "chest"),
    "head": ((0, 0, 0.43), (0, 0, 0.88), "neck"),
}
for s, sx in (("L", 1), ("R", -1)):
    BONES.update({
        f"upper_arm.{s}": ((sx * 0.072, 0, 0.36), (sx * 0.103, 0, 0.305), "chest"),
        f"forearm.{s}": ((sx * 0.103, 0, 0.305), (sx * 0.125, 0, 0.255), f"upper_arm.{s}"),
        f"hand.{s}": ((sx * 0.125, 0, 0.255), (sx * 0.134, -0.004, 0.215), f"forearm.{s}"),
        f"thigh.{s}": ((sx * 0.042, 0, 0.2), (sx * 0.044, 0, 0.115), "hips"),
        f"shin.{s}": ((sx * 0.044, 0, 0.115), (sx * 0.045, 0, 0.045), f"thigh.{s}"),
        f"foot.{s}": ((sx * 0.045, 0, 0.045), (sx * 0.045, -0.06, 0.02), f"shin.{s}"),
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


def clamp_z(o, lo=None, hi=None):
    """Flatten a part below lo / above hi (flat shoe soles etc.)."""
    for v in o.data.vertices:
        if lo is not None:
            v.co.z = max(v.co.z, lo)
        if hi is not None:
            v.co.z = min(v.co.z, hi)
    return o


def ball(slot, bone, material, radii, loc, segs=20, rings=12, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=rings, radius=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.scale = radii
    return part(o, slot, bone, material)


def box(slot, bone, material, size, loc, rot=(0, 0, 0), bevel=0.01):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.scale = size
    return part(o, slot, bone, material, bevel=bevel)


def tube(slot, bone, material, r1, r2, z0, z1, sy=1.0, sx=1.0, verts=20, smooth_angle=50, x=0.0):
    """Vertical tapered tube from z0 (radius r1) to z1 (radius r2), centred on x."""
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r1, radius2=r2, depth=z1 - z0,
                                    location=(x, 0, (z0 + z1) / 2))
    o = bpy.context.active_object
    o.scale = (sx, sy, 1)
    return part(o, slot, bone, material, smooth_angle=smooth_angle)


def ring(slot, bone, material, major, minor, loc, sy=1.0):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor, major_segments=24,
                                     minor_segments=8, location=loc)
    o = bpy.context.active_object
    o.scale = (1, sy, 1)
    return part(o, slot, bone, material)


def between(slot, bone, material, p0, p1, r0, r1, verts=16, flat_y=1.0, caps=True):
    """Tapered limb from p0 to p1, optional joint sphere at p0."""
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
        ball(slot, bone, material, (r0, r0, r0), tuple(p0), segs=14, rings=8)
    return o


def bone_pts(name):
    h, t, _ = BONES[name]
    return Vector(h), Vector(t)


# ---------------------------------------------------------------- HEAD (round mochi head: full cheeks, broad soft chin)
# Head parts are modelled around z=0.655 and then all dropped by HEAD_DROP so the neck stays hidden.
HC, HR, HEAD_DROP = Vector((0, 0, 0.655)), Vector((0.24, 0.21, 0.22)), 0.022
bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=40, radius=1, location=(0, 0, -HEAD_DROP))
head = bpy.context.active_object
for v in head.data.vertices:
    x, y, z = v.co
    if z < 0:
        t = -z
        x *= 1 + 0.09 * math.sin(math.pi * min(t / 0.9, 1.0))  # full cheeks, widest just below the eyes
        y *= 1 + 0.04 * math.sin(math.pi * min(t / 0.9, 1.0))
        z *= 1 - 0.1 * t * t                                     # broader, softer chin
    else:
        x *= 1 - 0.05 * z * z                                    # slightly narrower crown
    if y < 0:  # flatten the face plane
        y *= 1 - 0.3 * y * y
    v.co = Vector((x * HR.x, y * HR.y, z * HR.z)) + HC


def decal(slot, src, material, offset):
    """Thin shell over the face front, planar-UV'd to the face texture window."""
    me = src.data.copy()
    o = bpy.data.objects.new(f"{slot}Decal", me)
    o.location.z = -HEAD_DROP
    scene.collection.objects.link(o)
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.normal_update()
    keep = lambda v: v.co.y < -0.05 and TEX_Z0 < v.co.z < TEX_Z0 + TEX_S and abs(v.co.x) < -TEX_X0
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if not all(keep(v) for v in f.verts)], context="FACES")
    for v in bm.verts:
        v.co += v.normal * offset
    uv = bm.loops.layers.uv.verify()  # overwrite the sphere's own UVs
    for f in bm.faces:
        for lp in f.loops:
            lp[uv].uv = ((lp.vert.co.x - TEX_X0) / TEX_S, (lp.vert.co.z - TEX_Z0) / TEX_S)
    bm.to_mesh(me)
    bm.free()
    return part(o, slot, "head", material)


decal("Face", head, FACE, 0.0007)
decal("Eyes", head, EYES, 0.0014)
part(head, "Body", "head", SKIN)

# ---------------------------------------------------------------- BODY (tiny neutral bodysuit base)
for sx in (1, -1):
    ball("Body", "head", SKIN, (0.022, 0.016, 0.034), (sx * 0.232, 0.01, 0.62 - HEAD_DROP), segs=12, rings=8)
tube("Body", "neck", SKIN, 0.03, 0.03, 0.36, 0.47)
tube("Body", "chest", SUIT, 0.074, 0.068, 0.3, 0.385, sy=0.8)
tube("Body", "spine", SUIT, 0.06, 0.074, 0.24, 0.305, sy=0.8)
ball("Body", "hips", SUIT, (0.076, 0.062, 0.055), (0, 0, 0.215))
for s, sx in (("L", 1), ("R", -1)):
    ball("Body", "chest", SUIT, (0.03, 0.03, 0.03), (sx * 0.07, 0, 0.36))
    h, t = bone_pts(f"upper_arm.{s}")
    between("Body", f"upper_arm.{s}", SKIN, h, t, 0.024, 0.022, caps=False)
    h, t = bone_pts(f"forearm.{s}")
    between("Body", f"forearm.{s}", SKIN, h, t, 0.022, 0.02)
    h, t = bone_pts(f"hand.{s}")
    ball("Body", f"hand.{s}", SKIN, (0.027, 0.024, 0.028), tuple(h.lerp(t, 0.55)))
    ball("Body", f"hand.{s}", SKIN, (0.009, 0.009, 0.012), tuple(h.lerp(t, 0.45) + Vector((-sx * 0.012, -0.018, 0))),
         segs=10, rings=6)
    h, t = bone_pts(f"thigh.{s}")
    between("Body", f"thigh.{s}", SUIT, h, t, 0.034, 0.029, caps=False)
    h, t = bone_pts(f"shin.{s}")
    between("Body", f"shin.{s}", SKIN, h, t, 0.029, 0.025)
    clamp_z(ball("Body", f"foot.{s}", SKIN, (0.03, 0.048, 0.026), (sx * 0.045, -0.014, 0.024)), lo=0.002)

# ---------------------------------------------------------------- HAIR OPTIONS (swappable Hair_<Style> slots)
# Each style = one soft metaball mass (cap, volumes, tails) + mesh bang locks + optional ties, all on the head bone.


def head_front_y(x, z):
    """Front surface of the (undropped) head above its centre line."""
    zu = (z - HC.z) / HR.z
    xu = x / (HR.x * (1 - 0.05 * zu * zu))
    yu = -math.sqrt(max(0.0, 1 - xu * xu - zu * zu))
    return yu * (1 - 0.3 * yu * yu) * HR.y


class Hair:
    def __init__(self, style):
        self.slot = f"Hair_{style}"
        self.mb = bpy.data.metaballs.new(f"MB{style}")
        self.mb.resolution = self.mb.render_resolution = 0.006
        self.mb.threshold = 0.6
        self.obj = bpy.data.objects.new(f"MB{style}", self.mb)  # unique name = its own metaball family
        self.obj.location.z = -HEAD_DROP
        scene.collection.objects.link(self.obj)

    def blob(self, co, axes, rot=(0, 0, 0), neg=False, stiff=5.0, quat=None):
        """Ellipsoid element whose lone surface has the given semi-axes (stiffer = less blending)."""
        k = math.sqrt(1 - (self.mb.threshold / stiff) ** (1 / 3))  # field = stiff * (1 - (d/R)^2)^3
        e = self.mb.elements.new()
        e.type = "ELLIPSOID"
        m = max(axes)
        e.radius = m / k
        e.size_x, e.size_y, e.size_z = (a / m for a in axes)
        e.co, e.rotation = co, quat or Euler(rot).to_quaternion()
        e.stiffness, e.use_negative = stiff, neg

    def tail(self, pts, radii, flat=0.85):
        """A thick lock/tail through pts: one stretched ellipsoid per segment, tapering by radii."""
        pts = [Vector(p) for p in pts]
        for (a, b), (ra, rb) in zip(zip(pts, pts[1:]), zip(radii, radii[1:])):
            d = b - a
            r = (ra + rb) / 2
            self.blob(tuple((a + b) / 2), (r, r * flat, d.length / 2 + r * 0.45), quat=d.to_track_quat("Z", "Y"))

    def cap(self, top=0.205, temples=True):
        self.blob((0, 0.07, 0.715), (0.25, 0.212, top))           # crown (kept behind the forehead)
        self.blob((0, -0.062, 0.8), (0.212, 0.1, 0.085))          # hairline: buries the bang roots
        if temples:
            for sx in (1, -1):
                self.blob((sx * 0.205, -0.045, 0.69), (0.048, 0.07, 0.095), rot=(0, sx * 0.25, 0))

    def bob_back(self, length=1.0):
        self.blob((0, 0.075, 0.6), (0.228, 0.165, 0.17))
        for sx in (1, -1):
            self.blob((sx * 0.2, 0.025, 0.585), (0.068, 0.12, 0.13 * length))     # side volume
            self.blob((sx * 0.13, 0.125, 0.5 - 0.03 * (length - 1)), (0.07, 0.062, 0.08 * length))
        self.blob((0, 0.145, 0.495 - 0.03 * (length - 1)), (0.075, 0.062, 0.08 * length))

    def lock(self, x, z, w, d, h, tilt, lean, taper=0.5):
        """Thick bang lock: flattened ellipsoid hugging the forehead, tapering to a rounded tip."""
        bpy.ops.mesh.primitive_uv_sphere_add(segments=20, ring_count=14, radius=1)
        o = bpy.context.active_object
        for v in o.data.vertices:
            k = 1 - taper * max(0.0, -v.co.z) ** 1.4
            v.co = Vector((v.co.x * w * k, v.co.y * d * k, v.co.z * h))
        yaw = math.asin(max(-1, min(1, x / HR.x))) * 0.85
        o.rotation_euler = Euler((-tilt, lean, yaw), "YXZ")
        o.location = (x, head_front_y(x, z) - d * 0.35, z - HEAD_DROP)
        return part(o, self.slot, "head", HAIR)

    def bangs(self, kind):
        if kind == "soft":  # rounded locks, soft part left of centre
            for x, dz, lean in ((-0.172, 0.012, -0.32), (-0.112, -0.002, -0.16), (-0.05, -0.008, -0.04),
                                (0.022, -0.004, 0.06), (0.088, 0.0, 0.18), (0.15, 0.014, 0.32)):
                self.lock(x, 0.748 + dz, 0.047, 0.024, 0.085, 0.5, lean)
        elif kind == "blunt":  # heavy straight fringe down to the brows
            for i in range(7):
                x = -0.17 + i * 0.0567
                self.lock(x, 0.745, 0.044, 0.025, 0.083, 0.48, x * 1.4, taper=0.22)
        elif kind == "swept":  # long side-swept fringe falling to the character's left
            for i, x in enumerate((-0.16, -0.09, -0.02, 0.05, 0.12, 0.175)):
                self.lock(x, 0.765 - i * 0.008, 0.055, 0.025, 0.09 + i * 0.006, 0.55, 0.55 + x * 0.6)
        elif kind == "parted":  # centre part, locks curving outward
            for x in (-0.165, -0.105, -0.045, 0.045, 0.105, 0.165):
                self.lock(x, 0.752 + abs(x) * 0.05, 0.05, 0.024, 0.08, 0.5, x * 3.2)
        elif kind == "short":  # short tousled fringe, high on the forehead
            for x, lean in ((-0.16, -0.5), (-0.1, 0.35), (-0.035, 0.5), (0.03, 0.4), (0.095, 0.55), (0.155, 0.3)):
                self.lock(x, 0.785, 0.045, 0.024, 0.06, 0.6, lean, taper=0.6)

    def tie(self, loc, normal, major=0.03, minor=0.011, material=None):
        bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor, major_segments=24, minor_segments=8)
        o = bpy.context.active_object
        o.rotation_mode = "QUATERNION"
        o.rotation_quaternion = Vector(normal).to_track_quat("Z", "Y")
        o.location = Vector(loc) - Vector((0, 0, HEAD_DROP))
        return part(o, self.slot, "head", material or HAIR_TIE)

    def finish(self, carve=True):
        if carve:
            self.blob((0, -0.3, 0.56), (0.15, 0.13, 0.11), neg=True, stiff=12.0)  # keep the cheeks clear
        bpy.context.view_layer.update()
        activate(self.obj)
        bpy.ops.object.convert(target="MESH")
        o = bpy.context.active_object
        dec = o.modifiers.new("Decimate", "DECIMATE")
        dec.ratio = 0.18
        bpy.ops.object.modifier_apply(modifier=dec.name)
        part(o, self.slot, "head", HAIR, smooth_angle=80)


def hair_bob():
    h = Hair("Bob")
    h.cap()
    h.bob_back()
    for sx in (1, -1):
        h.blob((sx * 0.214, -0.08, 0.53), (0.042, 0.042, 0.115), rot=(0.12, sx * 0.1, 0))  # face-framing lock
    h.bangs("soft")
    h.finish()


def hair_long():
    h = Hair("Long")
    h.cap()
    h.blob((0, 0.08, 0.6), (0.23, 0.17, 0.17))
    for x in (-0.12, -0.04, 0.04, 0.12):  # back curtain falling to the waist in four soft locks
        h.tail([(x, 0.12, 0.6), (x * 1.15, 0.15, 0.42), (x * 1.1, 0.14, 0.27), (x * 1.0, 0.12, 0.17)],
               [0.07, 0.065, 0.055, 0.035], flat=0.7)
    for sx in (1, -1):
        h.tail([(sx * 0.2, 0.0, 0.66), (sx * 0.215, -0.03, 0.5), (sx * 0.19, -0.04, 0.36), (sx * 0.17, -0.03, 0.27)],
               [0.05, 0.045, 0.038, 0.022], flat=0.8)  # front locks over the shoulders
    h.bangs("blunt")
    h.finish()


def hair_buns():
    h = Hair("Buns")
    h.cap(top=0.2)
    h.blob((0, 0.075, 0.6), (0.225, 0.16, 0.16))
    for sx in (1, -1):
        h.blob((sx * 0.2, 0.02, 0.6), (0.062, 0.11, 0.11))
        h.blob((sx * 0.135, 0.09, 0.885), (0.05, 0.048, 0.048), stiff=8.0)  # bun
        h.tie((sx * 0.118, 0.08, 0.848), (sx * 0.5, 0.3, 1.0), major=0.032, minor=0.009)
        h.tail([(sx * 0.21, -0.06, 0.62), (sx * 0.222, -0.075, 0.5), (sx * 0.215, -0.07, 0.43)],
               [0.03, 0.026, 0.016])  # thin face-framing strand
    h.bangs("parted")
    h.finish()


def hair_ponytail():
    h = Hair("Ponytail")
    h.cap(top=0.2)
    h.blob((0, 0.08, 0.63), (0.222, 0.16, 0.15))
    for sx in (1, -1):
        h.blob((sx * 0.198, 0.02, 0.62), (0.058, 0.1, 0.1))
        h.tail([(sx * 0.21, -0.06, 0.64), (sx * 0.222, -0.078, 0.52), (sx * 0.212, -0.07, 0.45)],
               [0.032, 0.027, 0.016])
    h.tie((0, 0.255, 0.8), (0, 1, 0.35), major=0.034, minor=0.012)
    h.tail([(0, 0.26, 0.8), (0, 0.33, 0.78), (0, 0.36, 0.66), (0, 0.34, 0.53), (0, 0.3, 0.43)],
           [0.06, 0.068, 0.06, 0.045, 0.026])
    h.bangs("swept")
    h.finish()


def hair_crop():
    h = Hair("Crop")
    h.cap(top=0.208, temples=False)
    h.blob((0, 0.07, 0.62), (0.225, 0.16, 0.14))
    for sx in (1, -1):
        h.blob((sx * 0.19, 0.04, 0.665), (0.065, 0.12, 0.1))     # sides over the ears
        h.blob((sx * 0.2, -0.03, 0.66), (0.045, 0.07, 0.075))    # short sideburn
    h.bangs("short")
    h.finish()


def hair_twintails():
    h = Hair("Twintails")
    h.cap(top=0.2)
    h.blob((0, 0.075, 0.6), (0.225, 0.16, 0.16))
    for sx in (1, -1):
        h.blob((sx * 0.2, 0.025, 0.6), (0.062, 0.11, 0.11))
        h.tie((sx * 0.205, 0.105, 0.6), (sx * 1.0, 0.45, 0.1), major=0.03, minor=0.011)
        h.tail([(sx * 0.22, 0.11, 0.6), (sx * 0.27, 0.12, 0.52), (sx * 0.285, 0.1, 0.4), (sx * 0.27, 0.08, 0.3),
                (sx * 0.245, 0.06, 0.23)], [0.05, 0.06, 0.055, 0.042, 0.022])
    h.bangs("soft")
    h.finish()


HAIR_STYLES = {"Bob": hair_bob, "Long": hair_long, "Buns": hair_buns, "Ponytail": hair_ponytail,
               "Crop": hair_crop, "Twintails": hair_twintails}
DEFAULT_HAIR = "Bob"
for build in HAIR_STYLES.values():
    build()
export_web_layers()

# ---------------------------------------------------------------- TOP (fitted tee, puff sleeves, round collar)
tube("Top", "chest", TOP, 0.081, 0.075, 0.24, 0.392, sy=0.82)
for sx in (1, -1):
    ball("Top", "chest", TOP, (0.037, 0.037, 0.037), (sx * 0.07, 0, 0.36))
ring("Top", "chest", TOP_TRIM, 0.034, 0.008, (0, 0, 0.388), sy=0.9)
for sx in (1, -1):
    ball("Top", "chest", TOP_TRIM, (0.026, 0.008, 0.017), (sx * 0.02, -0.058, 0.372), rot=(0.35, 0, sx * 0.35))
ball("Top", "chest", SOLE, (0.009, 0.006, 0.009), (0, -0.064, 0.345), segs=12, rings=8)
for s, sx in (("L", 1), ("R", -1)):
    h, t = bone_pts(f"upper_arm.{s}")
    ball("Top", f"upper_arm.{s}", TOP, (0.04, 0.04, 0.036), tuple(h.lerp(t, 0.3)))
    between("Top", f"upper_arm.{s}", TOP_TRIM, h.lerp(t, 0.55), h.lerp(t, 0.68), 0.03, 0.029, caps=False)

# ---------------------------------------------------------------- BOTTOM (pleated skirt)
bpy.ops.mesh.primitive_cone_add(vertices=28, radius1=0.118, radius2=0.077, depth=0.115, location=(0, 0, 0.1875))
sk = bpy.context.active_object
for v in sk.data.vertices:  # pleats: every other bottom vertex tucked in
    i = round(math.atan2(v.co.y, v.co.x) / (2 * math.pi / 28))
    if i % 2 and v.co.z < 0:
        v.co.x *= 0.9
        v.co.y *= 0.9
sk.scale = (1, 0.86, 1)
part(sk, "Bottom", "hips", SKIRT, smooth_angle=20)
tube("Bottom", "hips", SKIRT_BAND, 0.085, 0.084, 0.232, 0.256, sy=0.86)

# ---------------------------------------------------------------- SOCKS + SHOES (rounded, slightly oversized)
for s, sx in (("L", 1), ("R", -1)):
    tube("Socks", f"shin.{s}", SOCK, 0.03, 0.031, 0.03, 0.095, x=sx * 0.0445)
    ring("Socks", f"shin.{s}", SOCK, 0.03, 0.007, (sx * 0.0445, 0, 0.095))
    clamp_z(ball("Shoes", f"foot.{s}", SHOE, (0.043, 0.064, 0.037), (sx * 0.045, -0.016, 0.034)), lo=0.012)
    clamp_z(ball("Shoes", f"foot.{s}", SOLE, (0.047, 0.068, 0.024), (sx * 0.045, -0.016, 0.02)), lo=0.0, hi=0.022)
    ball("Shoes", f"foot.{s}", SOLE, (0.013, 0.011, 0.011), (sx * 0.045, -0.052, 0.058), segs=12, rings=8)

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
GROUND = mat("GroundMat", "#DCCFF3", "#B6A6DC", rim=0.0)
bpy.ops.mesh.primitive_circle_add(vertices=64, radius=0.4, fill_type="NGON")
ground = bpy.context.active_object
ground.name = "Ground"
ground.data.materials.append(GROUND)

world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
wn = world.node_tree
bg_cam = wn.nodes["Background"]
bg_cam.inputs["Color"].default_value = (*lin("#EAE4F7"), 1)
bg_light = wn.nodes.new("ShaderNodeBackground")  # what the toon ramp sees: dim, neutral fill
bg_light.inputs["Color"].default_value = (1, 1, 1, 1)
bg_light.inputs["Strength"].default_value = 0.35
lp = wn.nodes.new("ShaderNodeLightPath")
wmix = wn.nodes.new("ShaderNodeMixShader")
wn.links.new(lp.outputs["Is Camera Ray"], wmix.inputs[0])
wn.links.new(bg_light.outputs[0], wmix.inputs[1])
wn.links.new(bg_cam.outputs[0], wmix.inputs[2])
wn.links.new(wmix.outputs[0], wn.nodes["World Output"].inputs["Surface"])

sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
sun.data.energy, sun.data.angle = 3.0, math.radians(14)
sun.rotation_euler = (math.radians(57), 0, math.radians(-28))
scene.collection.objects.link(sun)

target = bpy.data.objects.new("CamTarget", None)
target.location = (0, 0, 0.47)
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

CAM_3Q, CAM_FRONT, CAM_BACK = (0.72, -1.5, 0.66), (0.0, -1.65, 0.56), (-0.6, 1.55, 0.66)


def render(name, cam_loc, aim=0.47):
    cam.location = cam_loc
    target.location.z = aim
    scene.render.filepath = os.path.join(OUT, name)
    bpy.ops.render.render(write_still=True)


HAIR_SLOTS = [s for s in SLOT_OBJECTS if s.startswith("Hair_")]


def show_hair(style):
    for s in HAIR_SLOTS:
        SLOT_OBJECTS[s].hide_render = s != f"Hair_{style}"


show_hair(DEFAULT_HAIR)
render("teen_3q.png", CAM_3Q)
render("teen_front.png", CAM_FRONT)
render("teen_back.png", CAM_BACK)
render("teen_face_close.png", (0.12, -0.8, 0.64), aim=0.62)

# base body only (shows the swappable slots)
show_hair(None)
for slot in ("Top", "Bottom", "Socks", "Shoes"):
    SLOT_OBJECTS[slot].hide_render = True
render("teen_base_body.png", CAM_3Q)
for slot in ("Top", "Bottom", "Socks", "Shoes"):
    SLOT_OBJECTS[slot].hide_render = False

# ---------------------------------------------------------------- option contact sheets (hair_options.png, face_options.png)
label_mat = bpy.data.materials.new("Label")
label_mat.use_nodes = True
label_emit = label_mat.node_tree.nodes.new("ShaderNodeEmission")
label_emit.inputs["Color"].default_value = (*lin("#5E5378"), 1)
label_mat.node_tree.links.new(label_emit.outputs[0], label_mat.node_tree.nodes["Material Output"].inputs["Surface"])
label = bpy.data.objects.new("Label", bpy.data.curves.new("Label", "FONT"))
label.data.align_x = "CENTER"
label.data.materials.append(label_mat)
label.rotation_euler = (math.pi / 2, 0, 0)
scene.collection.objects.link(label)
label.hide_render = True


def render_sheet(name, items, apply, cam_loc, aim, scale, cols=4):
    """Render one ortho tile per option with a caption, then tile them into a single PNG."""
    import shutil
    import tempfile
    tmp = tempfile.mkdtemp()
    cam.data.type, cam.data.ortho_scale = "ORTHO", scale
    scene.render.resolution_x = scene.render.resolution_y = 512
    d = (Vector(cam_loc) - Vector((0, 0, aim))).normalized()
    label.data.size = scale * 0.075
    label.location = Vector((0, 0, aim)) + d * 0.5 - Vector((0, 0, scale * 0.45))
    label.rotation_euler = (math.pi / 2, 0, math.atan2(d.x, -d.y))
    label.hide_render = False
    tiles = []
    for item in items:
        apply(item)
        label.data.body = item.capitalize()
        tiles.append(os.path.join(tmp, f"{item}.png"))
        render(tiles[-1], cam_loc, aim)
    label.hide_render = True
    cam.data.type = "PERSP"
    scene.render.resolution_x = scene.render.resolution_y = 1024
    gap, n = 12, 512
    rows = math.ceil(len(tiles) / cols)
    sheet = np.ones(((n + gap) * rows + gap, (n + gap) * cols + gap, 4), np.float32)
    for i, p in enumerate(tiles):
        img = bpy.data.images.load(p)
        px = np.array(img.pixels[:], np.float32).reshape(n, n, 4)
        bpy.data.images.remove(img)
        r, c = rows - 1 - i // cols, i % cols  # pixel rows are bottom-up
        sheet[gap + r * (n + gap):gap + r * (n + gap) + n, gap + c * (n + gap):gap + c * (n + gap) + n] = px
    out = bpy.data.images.new(name, sheet.shape[1], sheet.shape[0], alpha=True)
    out.pixels.foreach_set(sheet.ravel())
    out.filepath_raw, out.file_format = os.path.join(OUT, name), "PNG"
    out.save()
    bpy.data.images.remove(out)
    shutil.rmtree(tmp, ignore_errors=True)


render_sheet("hair_options.png", list(HAIR_STYLES), show_hair, (1.2, -1.2, 0.74), 0.6, 0.72, cols=3)
show_hair(None)
render_sheet("face_options.png", list(FACES), set_face, (0.0, -1.6, 0.575), 0.575, 0.3, cols=4)
set_face(DEFAULT_FACE)
show_hair(DEFAULT_HAIR)

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
up = [("upper_arm.R", "Y", 125), ("upper_arm.R", "X", 35), ("chest", "Y", -4), ("head", "Y", 6)]
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

# ---------------------------------------------------------------- export + save
# The .glb carries every hair option (Teen_Hair_<Style>); the game shows one. Face options are the
# eyes_<name>.png / face_<name>.png pairs in faces/, swapped onto the Teen_Eyes / Teen_Face materials.
use_export_shading(True)
bpy.ops.object.select_all(action="DESELECT")
rig.select_set(True)
for o in SLOT_OBJECTS.values():
    o.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "teen_base.glb"), use_selection=True,
                          export_animations=True, export_animation_mode="ACTIONS")
# same scene as self-contained glTF JSON, for web hosts that only serve .json (the Mochi Maker artifact)
import base64
import json
import tempfile
tmp = tempfile.mkdtemp()
bpy.ops.export_scene.gltf(filepath=os.path.join(tmp, "web.gltf"), export_format="GLTF_SEPARATE",
                          use_selection=True, export_animations=True, export_animation_mode="ACTIONS")
with open(os.path.join(tmp, "web.gltf")) as f:
    gl = json.load(f)
for item, mime in [(b, "application/octet-stream") for b in gl.get("buffers", [])] + \
                  [(i, i.get("mimeType", "image/png")) for i in gl.get("images", []) if "uri" in i]:
    with open(os.path.join(tmp, item["uri"]), "rb") as f:
        item["uri"] = f"data:{mime};base64," + base64.b64encode(f.read()).decode()
with open(os.path.join(OUT, "teen_base.gltf.json"), "w") as f:
    json.dump(gl, f, separators=(",", ":"))
use_export_shading(False)
for s in HAIR_SLOTS:
    SLOT_OBJECTS[s].hide_set(s != f"Hair_{DEFAULT_HAIR}")
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "teen_base.blend"))
print("DONE", {k: len(v.data.polygons) for k, v in SLOT_OBJECTS.items()})
