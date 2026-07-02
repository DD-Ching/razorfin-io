# Razorfin .io 🦈🌊

> Apex predators of the open ocean — every one born with its weapon attached.

### ▶ [Play it in your browser](https://dd-ching.github.io/razorfin-io/) — no install, Godot 4 WebGL build

A 2D top-down, physics-driven **.io brawler** built in **Godot 4.7** (a fork of
[Whole Stone .io](https://github.com/DD-Ching/whole-stone-io) — same momentum engine,
new ocean). You are a predator fish: steer with one finger, hold one button to **boost**,
and hit them with the sharp end. Eat what they spill, and **grow**. Bigger hits harder
and reaches further… but turns slower. Weight versus mobility, all the way up the
food chain.

<p align="center"><em>Placeholder art is drawn entirely in code — the repo runs straight from a clean checkout, no asset pipeline.</em></p>

## One rule

**Damage is WHERE you touch.** Every fish is solid physics; bodies only shove each
other. Only the **weapon part** — the saw, the bill, the tail barb, the hammer —
wounds, and how much is read straight off that part's real speed at contact. Cruise
into someone and you nudge them. **Boost** into them, or **crack a turn** so your
weapon whips across them, and it's a wound.

And the beloved part: rebounds conserve and stack momentum. Clash off enough bodies
and you'll find yourself going *very* fast. That's not a bug — that's fish.

## The predators

Swim into a mutation orb to change species mid-run:

| Species | Weapon | The trick |
| --- | --- | --- |
| **Hammerhead** (錘頭鯊) | the wide hammer head | Heavy ram, huge knockback — wins head-on |
| **Sawfish** (鋸鰩) | the long toothed saw | Reach; every pass opens a **BLEED** |
| **Swordfish** (劍魚) | the rigid bill | Only the **tip** hurts — but it lands like a lance, and it has the fastest boost |
| **Stingray** (魟魚) | the tail whip, anchored *behind* | Sharp turns crack it; the barb **VENOMS** (slow + chip) |
| **Giant Squid** (大王魷魚) | the tentacle club | Balanced, sloshy — and it **inks** when it jets |

Weapon parts have their **own collision layer**, so a saw and a bill **CLASH** and
bounce apart by momentum — the lighter part reverses harder. Nothing is scripted:
every matchup is the same pendulum with different weight and anchor.

## The water

The seafloor is a real **height field** (bathymetric shading + depth contours). The
slope is a **current** that pulls toward the deep. Bright **shoals and sandbanks**
drag at your fins — knock a rival onto the sand and they're beached prey. Getting
pinned against the **reef wall** turns knockback into extra damage.

## Controls

| Input | Action |
| --- | --- |
| **Mouse** (desktop) | Steer — the fish swims toward the cursor |
| **LMB / Space (hold)** | **Boost** (stamina is boost fuel, nothing else) |
| **WASD** / arrows | Steer, if you'd rather |
| **1–5** | Pick / switch species (dev) |
| **R** / click | Respawn after you get eaten |
| **Right thumb** (phone) | Steer (dynamic stick) |
| **Left thumb (hold)** (phone) | Boost |

## Run it

You need [Godot **4.7+**](https://godotengine.org/download) (Standard / GDScript build).

```bash
# From the repo root:
godot .                       # opens the project, press F5 to play
```

**Web build:** the live version is a Godot HTML5/WebGL export (single-threaded, so it
runs on GitHub Pages without special headers). To rebuild it:

```bash
godot --headless --path . --export-release "Web" build/web/index.html
```

The exported `build/web/` is published to the `gh-pages` branch.

## How it's built

- **Godot 4.7**, GDScript 2.0, GL Compatibility renderer.
- **Code-first**: every entity builds its own nodes in `_ready()`. The only scene,
  `scenes/Main.tscn`, is a one-line bootstrap. All art is `_draw()` primitives.
- **Real physics**: fish are `CharacterBody2D` (kinematic momentum), loot is
  `RigidBody2D` that gets batted around, the reef is `StaticBody2D`.
- Tuning, run-state and signals live in one autoload, `scripts/Game.gd`.

```
scripts/
  Game.gd         # autoload: tuning constants, score/best/kills, signals, RNG
  Fighter.gd      # base fish: momentum swim, boost, wounds, growth, death/loot
  Weapon.gd       # the species' weapon part (pendulum physics) + hit resolution
  Player.gd       # steer-toward-pointer + boost + camera
  Bot.gd          # hunt-smaller / flee-bigger / wander-to-loot AI
  Pickup.gd       # RigidBody2D morsels + mutation orbs
  Terrain.gd      # baked bathymetric seafloor + down-slope current
  GameCamera.gd   # follow + shake + zoom-out-as-you-grow
  Hud.gd          # score, leaderboard, bars, death overlay
  Main.gd         # ocean, spawning, population, leaderboard, respawn
```

## License

[MIT](LICENSE)
