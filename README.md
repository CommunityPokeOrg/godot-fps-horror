# Facility 13 — Godot 4 FPS Horror Starter

A complete, self-contained first-person horror game starter for **Godot 4.3+**.
Explore a procedurally-assembled abandoned facility, collect 4 journal pages,
find the exit key, and escape — while a patrol/chase entity hunts you through
the dark. Everything (level geometry, materials, textures, audio) is generated
or procedural, so the project runs straight from the repository with **no
external assets**.

## Requirements

- **Godot 4.3 or newer** (tested on 4.3-stable). Download: https://godotengine.org/download
- No plugins, no C#, no external dependencies.

## How to run

1. `git clone` this repository.
2. Open Godot's project manager → **Import** → select `project.godot`.
3. Press **F5** (or the Play button). The main scene is `scenes/main.tscn`.

You start in the spawn room. The exit is a locked door on the **east edge of
the lobby** (southeast quadrant).

## Controls

| Input | Action |
|---|---|
| WASD | Move |
| Mouse | Look |
| Shift (hold) | Sprint — drains stamina, makes noise |
| Ctrl or C | Crouch — quieter, harder to spot |
| Space | Jump |
| F | Toggle flashlight (drains battery) |
| E | Interact (doors, notes, key, batteries) |
| Esc | Release/capture mouse |
| Enter | Restart after death/escape |

## Mechanics

- **Flashlight battery** drains while on (~1.4%/s) and slowly crank-recharges
  while off. Below 25% it flickers; at 0% it dies until recharged past 15%.
  Battery pickups restore 45%.
- **Stamina** drains while sprinting; when it hits 0 you're exhausted until it
  recovers past 30.
- **Sanity** drains in darkness and scales with enemy proximity/chase; low
  sanity adds a heartbeat, vignette, and camera sway. Regenerates when lit
  and calm.
- **Interaction** is raycast-based (`InteractRay` → `interact()`/`get_prompt()`):
  doors slide open, notes open a reading overlay, the key unlocks the exit,
  batteries recharge the flashlight.
- **The Orderly** (enemy) patrols waypoints on a runtime-baked navmesh
  (`NavigationAgent3D`), hears footsteps/door noises within its radius,
  spots you inside a view cone (crouching shrinks it, flashlight enlarges it),
  chases, searches on losing you, and triggers a jumpscare + death screen on
  contact. If navmesh baking fails it falls back to whisker-raycast steering.
- **Win condition**: all doors are cosmetic gates — open the locked exit door
  (needs the key) and step through the alcove.

## Project layout

```
project.godot                  Godot 4 project + input map + autoloads
scenes/
  main.tscn                    entry scene: world env, fog, instances below
  player.tscn                  CharacterBody3D FPS rig
  enemy.tscn                   procedural mannequin enemy
  hud.tscn                     one-node CanvasLayer (UI built in code)
  world/facility.tscn          generator root
  props/                       door, note, key, battery, exit trigger
scripts/
  autoload/game_manager.gd     state, objectives, lifecycle (GameManager)
  autoload/audio_manager.gd    ambient loop, SFX, noise events (AudioManager)
  player/player.gd             controller: look/move/sprint/crouch/bob/light
  enemy/enemy.gd               patrol/suspicious/chase/search/kill FSM
  world/facility_generator.gd  level carve, walls, props, lights, navmesh bake
  world/flicker_light.gd       flickering ceiling light
  world/main.gd                scene wiring
  interactables/*.gd           door/note/key/battery/exit logic
  ui/hud.gd                    HUD construction + state screens
assets/audio/*.wav             procedurally generated placeholder audio
tools/generate_audio.py        regenerates the WAVs (pure stdlib Python)
tests/headless_check.*         headless verification scene
```

## Architecture notes

- **Autoloads**: `GameManager` (objectives/state/`noise_emitted` plumbing via
  `AudioManager`) and `AudioManager` (ambient loop, `play_2d`/`play_3d`,
  `footstep()`, and `noise_emitted` — the signal enemies hear).
- **Level generation**: `FacilityGenerator` carves room/corridor rects into a
  cell grid, generates merged wall runs, doors with jambs/lintels, light
  fixtures (`FlickerLight`), props, pickups, then bakes a `NavigationMesh`
  at runtime inside a `NavigationRegion3D`. Change `ROOMS`/`CORRIDORS`/`DOORS`/
  content tables to redesign the facility.
- **Interactables** implement `interact(player)` + `get_prompt()`; the player's
  `InteractRay` walks up the collider's parent chain to find one.
- **Verification**: see below.

## Headless verification

A test scene exercises the input map, autoloads, level connectivity (BFS over
carved cells), movement/sprint/crouch, flashlight battery drain, note/key/
door/exit interactions, and the enemy chase→kill path:

```bash
godot --headless --path . "res://tests/headless_check.tscn"
```

Exit code 0 means all checks passed. CI-friendly; no display required.

## Regenerating audio

```bash
python3 tools/generate_audio.py   # rewrites assets/audio/*.wav
```

## Known limitations (it's a starter)

- Jumpscare is a screen flash + death screen (no animated face lunge).
- Save/load, difficulty options, and a menu are not included.
- The navmesh is baked at runtime each launch (~instant at this scale).
- Placeholder audio is deliberately crude; replace WAVs in `assets/audio/`
  keeping filenames, or extend `AudioManager.SOUNDS`.
- Enemy is a single entity; the FSM supports duplication but the demo ships
  with one.

## Extending

- Add a room: append a `Rect2i` to `ROOMS`/`CORRIDORS` in
  `facility_generator.gd` and connect it via a `DOORS` cell on the seam.
- Add an interactable: extend `Interactable` (Node3D + Area3D for the ray)
  or give any physics body `interact()`/`get_prompt()`.
- Retune difficulty: enemy `view_distance`, `view_half_angle`, `hear_radius`,
  `chase_speed`; player battery/stamina/sanity exports.
