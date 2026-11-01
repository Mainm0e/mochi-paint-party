# Mochi Sketchbook

A cozy single-player 3D **sketchbook adventure** for PC (Windows), built in **Godot 4.7**. A squishy mochi
eats ink drops and doodles to restore a sketchbook's color and borrow doodle powers. Full design:
[docs/game_design.md](docs/game_design.md) (pillars, powers, structure, milestone plan, open questions).

**All characters and assets must be original.** Style references (MapleStory 2 look, Kirby-like inhale)
are for general feel only; never copy their models, textures, characters or levels.

## Folder map

| Path | What it is |
|---|---|
| `godot/` | **The game.** `scripts/` (main, world, mochi, audio), `shaders/`, `assets/` (mochi glb + face layers, audio) |
| `blender/make_mochi.py` | Builds the rigged mochi: body, face decals, toppings, emote faces + FX props, animations, face layer PNGs, `mochi.glb` |
| `blender/mochi/` | Output of `make_mochi.py` (renders, `mochi.blend`, `mochi.glb`, `layers/`) |
| `tools/make_audio.py` | Synthesizes all music + SFX WAVs (numpy) into `godot/assets/audio/` |
| `docs/game_design.md` | Game design doc |
| `creator/`, `game/` | Older three.js web prototypes (Mochi Maker, web "Doodle Mochi", the old title). Not the main game. |
| `blender/make_teen_base.py`, `blender/teen/`, `blender/archive/` | Earlier chibi-human experiments, abandoned for the mochi. Keep, don't extend. |

## Commands (Git Bash)

```bash
# Godot (4.7.2): console exe prints errors
G="/c/Users/mainm/Godot/Godot_v4.7.2-stable_win64_console.exe"
"$G" --headless --path godot --import                 # after adding/changing assets
"$G" --headless --path godot --quit-after 120          # quick script/parse check (look for SCRIPT ERROR)
"$G" --path godot --resolution 1280x720 -- --autotest=<abs dir>   # scripted playthrough + screenshots, prints AUTOTEST lines

# Blender 5.2 asset builds
B="/c/Program Files/Blender Foundation/Blender 5.2/blender.exe"
"$B" --background --factory-startup --python blender/make_mochi.py -- blender/mochi --no-video   # ~2 min; drop --no-video for the emote MP4 (~10 min)
"$B" --background --factory-startup --python tools/make_audio.py -- godot/assets/audio
```

After rebuilding the mochi, copy assets into Godot, then re-import:
`blender/mochi/mochi.glb` -> `godot/assets/mochi/`, `blender/mochi/layers/` -> `godot/assets/mochi/layers/` (delete `layers.json` there).

The autotest writes a save file; delete `%APPDATA%/Godot/app_userdata/Mochi Sketchbook/mochi_sketchbook.json` afterwards so the user starts fresh.

## How the game is put together

- Everything is built in code (`scenes/main.tscn` is just `Main` + `main.gd`). No hand-made scenes.
- `main.gd`: flow (menu -> creator -> Home Page -> pages), input map (registered in code), third-person camera
  (captured mouse, yaw/pitch), HUD/menus (paper cards, ink borders, `Segoe Print` font), thought clouds
  (`think()`), eating loop (`_eat`), save (`user://mochi_sketchbook.json`), the `_autotest` tour.
- `world.gd`: `load_level("home" | "meadow1")` builds paper islands (StaticBody3D), doodle props (white +
  ink outline, painted later via instance uniform `albedo`), edibles (drop / power / sticker / smudgie / seal),
  checkpoints, switches + bridges, Smudgie AI, spat stars, painting ripples.
- `mochi.gd`: `CharacterBody3D`; visual squash/stretch on child `bob`; powers (`puffy` glide, `stone` stomp),
  stamina (shown on the face + thought clouds, **no bars**), eating faces (gape/munch), emotes via glTF
  bone-scale animations, shadow raycast.
- Shaders: `toon` (two-band, unshaded, wobble), `outline` (inverted hull next_pass), `mochi_face` (stacks face
  layers + eye tint), `decal` (emote faces), `paper` (islands with world grid).
- Emote faces/effect props are shrunk to 1/100 on their own bones; animations scale them up (glTF can't animate visibility).

## Gotchas

- Blender `image.save()` silently fails on relative paths: scripts use `os.path.abspath(OUT)`.
- GDScript can't infer types from untyped Dictionary/Array values: write `var x: int = ...` (parse errors otherwise).
- Physics bodies must not be non-uniformly scaled: give boxes their real size.
- Blender keeps un-keyed bones from the previous action; Godot code calls `skeleton.reset_bone_poses()` before emotes.

## Status (2026-11-01)

Playable slice done: Home Page (book, mirror -> creator, sticker board) and **Meadow 1** (8 drops, 5 stickers,
Puffy glide gap, Stone switch + bridge, Smudgies, checkpoints, Paint Seal). Sprint/stamina, double jump,
big-mouth inhale + gulp, 6 emotes, music + SFX, gamepad. Verified by the autotest, **not yet hand-playtested**.

Next candidates: hand playtest + tuning; camera collision (clips through props); spit bounce; more pages /
chapters; the Eraser; doodle NPC friends; decorating the Home Page with stickers; exporting a Windows build.

## Working with the user

- Shows changes by screenshots/renders; always check them before reporting.
- Prefers character-driven feedback (faces, thought clouds, animation) over UI bars and meters.
- Cozy, cute, bouncy feel; sounds soft and round ("boing"), never rapid or harsh.
- Commit with git after finished features (repo on `main`, identity set locally).
