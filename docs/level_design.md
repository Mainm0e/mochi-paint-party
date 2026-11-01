# Mochi Sketchbook: Level and Gameplay Plan (Steam, €10–20)

*Senior level-design pass, 2026-11-01. Builds on [game_design.md](game_design.md) (pillars, powers, structure).*

## 1. What €10–20 buys, and what we must deliver

Players compare us to cozy 3D collectathons and short indie platformers. At this price they expect:

| Expectation | Our target |
|---|---|
| Length | **5–7 h** to the credits, **10–12 h** for 100% |
| Variety | a new idea every few minutes; every chapter adds a power and a twist |
| Polish | tight controls, juicy feedback, no dead ends, saves that never lose progress |
| Hook | one sentence a streamer can say: *"a squishy mochi eats doodles to paint a sketchbook back to life"* |
| Steam basics | controller support, rebinding, options, achievements, cloud saves, 1080p/60 on a mid laptop |

**Price recommendation: €14.99** (launch discount to €12.74). Below €10 only if we ship 3 chapters.

## 2. The whole game at a glance

| # | Page (open area) | New power | Twist / signature idea | Bloom Stars | Time (first run) |
|---|---|---|---|---|---|
| 0 | Home Page (hub) | — | creator, sticker board, friends move in | — | — |
| 1 | **The Meadow** | Puffy, Stone | learn eating, gliding, stomping | 12 (+3 later) | 45–60 min |
| 2 | **The Village** | **Sketch** (draw ink bridges) | rooftops, canals, a clock tower | 12 (+3 later) | 60 min |
| 3 | **Seaside** | Bubble (float on water, bounce) | tides rise and fall on a timer; lighthouse beam | 15 | 60–75 min |
| 4 | **Snowy Notebook** | Toasty (melt ice), Boing (super jump) | slippery ice, night falls and stars become platforms | 15 | 75 min |
| 5 | **The Eraser's Castle** | all | a page that rubs itself out behind you; final chase | 8 | 45 min |
| ★ | **Bonus pages** (unlocked by stickers) | — | 4 short challenge pages, one per chapter, pure platforming | 4 × 3 | 60 min |

**Total: ~74 Bloom Stars.** The credits need **40**; the castle opens at **30**. The "+3 later" stars in early pages need
powers from later chapters (Sketch, Bubble, Boing), so players have a reason to go back (Metroid-lite revisits).

### Progression gates
- Next chapter opens at **5 stars** from the current one (already built).
- The castle opens at **30 stars total**; the last door needs **40**.
- Stickers (5 per page, 25 + bonus) unlock bonus pages (every 5 stickers) and creator items.

## 3. How every open page is built (the template)

Every page follows the same skeleton, so players learn to read it:

1. **Arrival plaza:** safe, flat, the friend with the first quest is visible, a signpost hub, the page's
   landmark visible on the horizon (Meadow: giant tree; Village: clock tower; Seaside: lighthouse; Snowy: the moon).
2. **3–4 districts** around the plaza, each themed around one idea, each with 2–3 stars.
3. **One power pedestal** near the plaza introduces the chapter's power in a safe spot; the first use of it
   is a free star within sight (teach → test → twist).
4. **Star mix per page** (12–15): 3 climbs/platforming, 2 power puzzles, 2 friend quests, 1 race/timed,
   1 combat (Smudgie nest), 1 "eat every drop", 1 secret nook, 1 Trail (a short linear course), 1–3 revisits.
5. **Paths and signposts** to every district; the ground colours in as stars are found (visible progress).
6. **Trail**: one linear obstacle course per page, the hardest content, ending in a star.

Pacing per page: plaza (calm) → districts (choice, rising difficulty) → Trail (peak) → Bloom moment (reward).

## 4. Chapter 2: The Village (built now)

*Rooftops, chimneys, laundry lines and a canal. Power: **Sketch Mochi** (eat a pencil doodle; press the use
button to draw a short ink bridge in front of you; it fades after a few seconds).*

Layout (64 × 60 m): the **Town Square** in the south with the pencil pedestal; the **Canal** runs east–west across
the middle (fall in and you are redrawn); **Rooftop Row** north-west; **Windmill Hill** north-east; the
**Garden** maze south-east; the **Clock Tower** landmark north-centre.

| Star | District | How you earn it | Teaches / tests |
|---|---|---|---|
| Sketch Start | Square | draw your first bridge over the fountain moat | Sketch (teach) |
| Broken Bridge | Canal | the old bridge is snapped: draw across to the canal islet | Sketch (test) |
| Mill Balcony | Windmill Hill | climb the hill, sketch across to the mill balcony | Sketch + height (twist) |
| Clock Tower | Rooftop Row | hop the rising rooftops to the top of the tower | climbing |
| Laundry Lines | Rooftop Row | walk the thin washing lines between roofs | balance / precision |
| Postie's Letters | town | find 3 letters blown onto roofs, bring them back | exploration quest |
| Glim's Spark | alley | the lamp post lost its spark in the dark alley | exploration quest |
| Zip's Rooftop Race | rooftops | 6 hoops in 35 s, across roofs and a bridge | timed movement |
| Chimney Smudgies | chimney yard | clean every Smudgie | combat |
| Market Cage | market | eat a pebble, stomp the switch, the cage sinks | Stone (revisit power) |
| Garden Maze | garden | find the way through tall hedges | navigation |
| Every Drop | all | eat all paint drops | completion |

## 4b. Chapter 3: Seaside (built)

*A sandy beach, the open sea, the Lighthouse Isle, a shipwreck reef and a coral cave. Power: **Bubble Mochi**
(eat a bubble doodle: walk on water; a big fall bounces you back up). Signature idea: **the tide** turns every
~25 s (22 s high, a 4 s fall, 22 s low, a 4 s rise, with a bell and a warning just before it comes back in). Low
tide uncovers a sand bar, reef rocks and the cave floor; high tide floods them (a plain mochi gets splashed back
to the last flag, a bubble just floats).*

| Star | How you earn it | Teaches / tests |
|---|---|---|
| Buoy | walk on the water to the buoy that rides the tide | Bubble (teach) |
| Sand Bar | walk out along the sand bar at low tide | reading the tide |
| Lighthouse | low tide or Bubble to the isle, then 9 spiral ledges to the lamp | climbing |
| Shipwreck | reef rocks at low tide (or Bubble) to the wreck; the star is in the hull | tide + Bubble |
| Coral Cave | under the coral arch; the floor is dry only at low tide | tide timing |
| Big Dune | sandy terraces to the top | warm-up climb |
| Rock Pools | hidden behind the big boulder | curiosity |
| Sandcastle | eat a pebble, stomp the switch, the castle cage sinks | Stone (revisit) |
| Cove Smudgies | clean every Smudgie in the drift weed | combat |
| Clack's Shells | find 3 shells (dune, wreck, rock pools) | exploration quest |
| Gale's Race | 6 hoops out over the sand bar in 34 s: needs low tide or Bubble | timed + tide |
| Every Drop | eat all paint drops | completion |

Audio: each page has its own theme (Meadow "Paper Stroll", Village "Village Square" waltz, Seaside "Seaside
Breeze"), footsteps change with the ground (grass, stone, wood, sand, water), and the tide rings a bell.

## 5. Chapters 4–5 (plans to build next)

**Seaside (Bubble):** built, see 4b. Ideas left for later: the lighthouse beam as a moving platform at night,
bubble rides up a waterfall, a shipwreck Trail, 3 more stars to reach 15.

**Snowy Notebook (Toasty, Boing).** Slippery ice changes movement (lower grip); Toasty melts ice walls and
icicle gates; Boing super-jumps up the cliffs. Night falls after the third star: constellations become paths
in the sky. Trail: a sledding slope with Smudgie snowballs.

**The Eraser's Castle.** A linear-but-wide final page: rooms that test one power each, a page that rubs itself
out behind you (chase), and the Eraser met three times (stomp its pink sleeve, spit stars at its pencil
towers, then a final "eat the Eraser's shadow" moment that paints the whole book). No game over, ever.

## 6. Moment-to-moment polish checklist (to sell, this matters more than content)

- **Camera:** ✓ collision (stops in front of walls). To do: auto-recentre when walking, a "look at landmark" on entry.
- **Jump feel:** ✓ jump buffering (0.14 s), ✓ coyote time, ✓ variable jump height (release early = lower).
- **Readability:** ✓ every star has a soft light beam visible from far. To do: a soft chime when one is near.
- **Feedback:** ✓ star-get celebration (short freeze, camera push-in, shake, confetti, happy emote).
- **Onboarding:** Meadow first 5 minutes teach move → eat → jump → power, through friends, never text walls.
- **Map/compass:** ✓ the pause menu shows the page map (you, flags, friends needing help, found and spotted stars). To do: star names.
- **Accessibility:** rebinding, text size, colour-blind friendly star markers, "assist" mode (extra glide/jump).
- **Audio:** one music theme per chapter, a calmer version for night; footstep sounds per surface.

## 7. What is still missing to ship on Steam

| Area | Status | Needed |
|---|---|---|
| Chapters | Meadow, Village, Seaside built | Snowy, Castle, 4 bonus pages |
| Powers | Puffy, Stone, Sketch, Bubble | Toasty, Boing |
| Bosses | none | Eraser encounters (3) |
| Menus | main, pause, creator | options (graphics, audio, controls, rebinding, language), save slots, credits |
| Saves | single JSON | 3 slots, Steam Cloud |
| Steam | — | Steamworks (achievements: one per chapter, 100%, spotless pages), store page, capsule art, trailer, demo |
| Testing | scripted autotest | 5–10 outside playtesters per chapter; record where they get stuck |
| Localisation | English | EN + JP + DE/FR/ES text (the UI is small) |

## 8. Roadmap (solo + Claude, part time)

1. **Now:** Village chapter + Sketch (this pass). Hand-playtest Meadow and Village.
2. **Polish sprint:** camera collision, jump buffering, star celebration, pause-menu page map.
3. **Seaside** (Bubble, tides). Then a public **demo** (Meadow + Village) for Steam Next Fest feedback.
4. **Snowy Notebook** (Toasty, Boing), revisit stars in earlier pages.
5. **Castle + Eraser**, bonus pages, credits.
6. Steam integration, options, localisation, trailer; release.
