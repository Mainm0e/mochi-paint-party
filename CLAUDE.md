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
| `editor/` | **Level editor** web app (grid map maker). `node editor/serve.mjs` -> http://localhost:5175; saves `godot/levels/<name>.json`, Play launches Godot |
| `godot/levels/` | Pages made in the level editor (`sample.json`; `seaside`/`snowy`/`castle` open their World Map stamps; `meadow`/`village` are built in code and reserved) |
| `creator/`, `game/` | Older three.js web prototypes (Mochi Maker, web "Doodle Mochi", the old title). Not the main game. |
| `blender/make_teen_base.py`, `blender/teen/`, `blender/archive/` | Earlier chibi-human experiments, abandoned for the mochi. Keep, don't extend. |

## Commands (Git Bash)

```bash
# Godot (4.7.2): console exe prints errors
G="/c/Users/mainm/Godot/Godot_v4.7.2-stable_win64_console.exe"
"$G" --headless --path godot --import                 # after adding/changing assets
"$G" --headless --path godot --quit-after 120          # quick script/parse check (look for SCRIPT ERROR)
"$G" --path godot --resolution 1280x720 -- --autotest=<abs dir>   # scripted playthrough + screenshots, prints AUTOTEST lines
"$G" --path godot --resolution 1600x900 -- --worldmap=<abs dir>   # world map concept renders (docs/world_concept/)
"$G" --path godot -- --level=<name> [--overview | --look=x,y,z,tx,ty,tz] [--shot=<abs png>]   # straight into a page; --shot saves a picture and quits
node editor/serve.mjs                                              # level editor (GODOT env var overrides the exe path)

# Blender 5.2 asset builds
B="/c/Program Files/Blender Foundation/Blender 5.2/blender.exe"
"$B" --background --factory-startup --python blender/make_mochi.py -- blender/mochi --no-video   # ~2 min; drop --no-video for the emote MP4 (~10 min)
"$B" --background --factory-startup --python tools/make_audio.py -- godot/assets/audio
```

After rebuilding the mochi, copy assets into Godot, then re-import:
`blender/mochi/mochi.glb` -> `godot/assets/mochi/`, `blender/mochi/layers/` -> `godot/assets/mochi/layers/` (delete `layers.json` there).

Test runs (`--autotest`, `--level`, `--worldmap`) save to `user://test_run.json` (wiped at their start), never to the
player's `mochi_sketchbook.json`. **Never delete the player's save.** Continue: `save.last` is the last page entered.

Windows build: `godot/export_presets.cfg` ("Windows Desktop", one exe with the pck embedded, includes `levels/*.json`).
Needs Godot 4.7.2 export templates (Editor > Manage Export Templates). Then:
`"$G" --headless --path godot --export-release "Windows Desktop" build/MochiSketchbook.exe` (output is git-ignored).

## How the game is put together

- Everything is built in code (`scenes/main.tscn` is just `Main` + `main.gd`). No hand-made scenes.
- `main.gd`: flow (menu -> creator -> Home Page -> World Map -> pages), input map (registered in code), third-person camera
  (captured mouse, yaw/pitch), HUD/menus (paper cards, ink borders, `Segoe Print` font), thought clouds
  (`think()`), eating loop (`_eat`), save (`user://mochi_sketchbook.json`), the `_autotest` tour.
- Home Page (`_build_home`): a room with the book (-> map), mirror (-> creator), star jars per chapter (`JARS`),
  a sticker board (slot per sticker), and `HOME_FRIENDS` who move in once their quest/race star is found; main sets
  `world.home_state` before loading it. No HUD Menu button (the mouse is captured): Esc opens the pause menu.
- `world.gd`: `load_level("home" | "worldmap" | "meadow")` builds paper islands (StaticBody3D), doodle props (white +
  ink outline, painted later via instance uniform `albedo`), edibles (drop / power / sticker / smudgie / seal),
  checkpoints, switches + bridges, Smudgie AI, spat stars, painting ripples.
- Open pages (`_build_meadow`): big ground island + landmarks. Bloom Stars (`bloom()`, ids `b_*`, hidden ones
  shown by `reveal_bloom`), doodle friends (`friend()`: zone + `talk()`, quests for `item()`s, `friend_said` ->
  2D speech card), Scribble's hoop race, bouncy mushrooms (`bouncy_at`), Smudgie `nest`, `_check_tasks`.
  Saved in `pages.<id>.eaten` (`b_*` = stars, `reveal:<id>` = revealed). `PAGE_STARS`, `STARS_TO_OPEN` (5).
- World Map (`_build_worldmap`): `STAMPS` = one stamp per chapter (id, pos, colour, chapter, page, title; "" = not built).
  `main.gd` sets `world.map_done` / `map_stars` / `map_at` / `map_new` before loading it; a stamp opens when the one before is
  at 5 Bloom Stars, a chapter region (`_chapter_of`) paints once it reaches that. The mochi is `size` 1.7 there
  (scales body, speed, hop) and the camera/fog pull back. Save keeps `map_at` (last stamp used).
- Editor pages (`_build_json`): `heights` grid (row-major, -1 = hole, step 0.5 m, `cell` m wide; merged into
  rectangles) + `objects` ({type, x, z, rot, props}); types match the editor `CATALOG` (spawn, checkpoint, star
  with `reveal` none/drops/smudgies, drop, sticker, power, smudgie, friend, tree, bush, rock, flowers, mushrooms,
  pond, bouncy, house, fence, sign, platform). Adding a type = add it to `CATALOG` (+ 2D icon, 3D preview) and a
  `match` arm in `_build_json`. `page_exists` / `page_stars` / `page_title` work for both kinds of page.
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
- Editor levels are read with `FileAccess` from `res://levels/`: when exporting a build, add `levels/*.json` to the
  export preset's non-resource include filter or the pages won't ship.

## Status (2026-11-01)

Playable: Home Page (book -> World Map, mirror -> creator, sticker board), a walkable **World Map**
(chapter stamps with star counts, paths, regions painting in) and the open **Meadow** (12 Bloom Stars: climbs, a glide,
nest, cage switch, mushroom bounce, rooftop, 3 doodle-friend quests incl. a hoop race, all drops, and the old
Meadow 1 run as the "Ink Trail" off the north edge; 14 drops, 5 stickers,
Smudgies, checkpoints). Sprint/stamina, double jump,
big-mouth inhale + gulp, 6 emotes, music + SFX, gamepad. Verified by the autotest, **not yet hand-playtested**.

The Meadow is dressed by `_dress_meadow()` (stone paths to each landmark, signposts, pond, picnic, fences,
edge hedges, groves/bushes/rocks/flower beds placed with `_clear()` keep-outs, butterflies).

Chapter 2 **The Village** (`_build_village`): canal, Sketch Mochi (use button draws a 5 m ink bridge,
`world.sketch_bridge`, rubbed out after 6 s, 2 at a time), rooftops + Clock Tower, laundry lines, Windmill Hill,
chimney-yard nest, market cage, hedge maze, friends Glim (spark), Postie (3 letters), Zip (hoop race). 12 stars.
Chapter 3 **Seaside** (`_build_seaside`): beach + sea with a tide (`_tick_tide`, `TIDE_*`, `in_sea` -> splash +
redraw), Bubble Mochi (mochi collides with the sea layer `Mochi.WATER_LAYER` and bounces on big falls), buoy riding
the tide (`floats`), sand bar, Lighthouse Isle, shipwreck reef, coral cave, dune, rock pools, sandcastle cage,
friends Clack (3 shells) and Gale (race). 12 stars.
Audio: per-page music (`main.MUSIC`, `audio.play_music` crossfades), surface footsteps (`world.surface_at`; body
meta "surface" or `PAGE_SURFACE`; wood/sand by paper colour in `SURFACES`).
The full commercial plan (chapters 3-5, polish list, Steam checklist, roadmap) is **docs/level_design.md**.
Polish so far: camera collision (ray from mochi to camera, `_update_camera`), jump buffer + tap-for-short-hop
(`mochi.gd` `_buffer` / `_cuttable`), Bloom Star celebration (`_celebrate`: hit-stop, `_punch` camera lean, confetti),
star light beams (`bloom()`), pause-menu page map (`_draw_page_map`).

Next candidates (see the roadmap in docs/level_design.md): hand playtest + tuning;
camera collision (clips through props); spit bounce; the Village page /
more chapters; the Eraser; friends moving to the Home Page; decorating it with stickers; a Windows build.

## Working with the user

- Shows changes by screenshots/renders; always check them before reporting.
- Prefers character-driven feedback (faces, thought clouds, animation) over UI bars and meters.
- Cozy, cute, bouncy feel; sounds soft and round ("boing"), never rapid or harsh.
- Commit with git after finished features (repo on `main`, identity set locally).
