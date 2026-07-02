extends Node
## Game — the single global tuning + run-state hub (autoloaded as "Game").
##
## Everything the ocean and the HUD need to agree on lives here: the shared tuning
## constants, the run's score/best/kills, the collision-bit layout, and a small pool
## of rival names + colours. Keeping the numbers in one place means the whole game can
## be re-tuned from a single file, and the HUD only ever listens to THIS node — the
## ocean pushes state up through here, so nothing reaches across the scene tree.

# --- signals the HUD listens to --------------------------------------------------
signal score_changed(score: int, best: int)
signal kills_changed(kills: int)
signal rank_changed(rank: int, total: int)
signal leaderboard_changed(entries: Array)   ## Array of {name, score, is_player, alive}
signal player_died(final_score: int, rank: int)
signal player_spawned()
signal feed_event(text: String, gold: bool)   ## kill-feed / crown lines for the HUD

# --- collision bits (kept here so every entity agrees) ---------------------------
const L_FIGHTER := 1   ## bodies that can be hit / detected by weapon parts
const L_PICKUP := 2    ## loose plankton morsels + mutation orbs
const L_WALL := 4      ## reef bounds
const L_FIELD := 8     ## force-field areas (shelved, kept for later)
const L_WEAPON := 16   ## the weapon body part (saw/bill/tail…) — its own layer so parts CLASH
const L_WEAPON_SOLID := 32   ## the SOLID part body that physically pushes fish (no overlap; excludes own wielder)

# --- ocean arena -------------------------------------------------------------------
const ARENA_SIZE := Vector2(4400.0, 3100.0)   ## a big ocean — you should feel small in it
const WALL_THICK := 120.0
const BOT_TARGET := 13         ## how many rival predators to keep alive

# --- growth (the .io hook) ---------------------------------------------------------
const START_MASS := 1.0
const MAX_MASS := 1000000.0    ## effectively no cap — you can grow without limit (speed/agility fall off naturally)
const GEM_MASS := 0.16         ## mass gained per morsel absorbed
const KILL_ABSORB := 0.4       ## fraction of a victim's mass the killer gains outright
const SPILL_FRACTION := 0.75   ## fraction of a victim's mass that scatters as morsels
const AMBIENT_GEMS := 80       ## free morsels in the ocean (kept modest for perf)

# --- body / movement (heavy, momentum-based swimming) ------------------------------
const BASE_BODY_RADIUS := 15.0
const BASE_MAX_SPEED := 440.0
const SPEED_MASS_EXP := -0.32  ## bigger => slower (weight vs mobility)
const ACCEL := 900.0           ## dead-weight pickup — slow to get going
const FRICTION := 560.0        ## keeps gliding when you let go (momentum)
const BASE_HEALTH := 60.0
const HEALTH_PER_MASS := 30.0
const HEALTH_REGEN := 5.0
const KNOCK_FRICTION := 620.0  ## how fast a knockback shove bleeds off

# --- boost (the ONE button: stamina is boost fuel, nothing else) --------------------
const BOOST_SPEED_MULT := 1.7  ## top-speed multiplier while boosting (× the species' own boost factor)
const BOOST_ACCEL_MULT := 2.3  ## surge harder, not just faster
const BOOST_DRAIN := 32.0      ## stamina per second while the boost is held
const BOOST_MIN := 6.0         ## can't START a boost below this (prevents 1-frame stutter-boosts)
const STAMINA_MAX := 100.0
const STAMINA_REGEN := 30.0

# --- combat (damage is WHERE you touch: weapon part hurts, body only shoves) --------
const HIT_SPEED_MIN := 300.0   ## part speed (px/s) below which contact only nudges, never wounds
const REF_HEAD_SPEED := 1200.0 ## part speed that reads as a "full power" hit
const BASE_DMG := 24.0
const BASE_KNOCK := 480.0
const HIT_INTERVAL := 0.32     ## a sustained-fast part re-bites the same target this often
const INVULN := 0.18           ## i-frames after taking a hit
const PIN_DAMAGE := 0.06       ## bonus damage per unit of knockback absorbed when a victim is pinned to the reef

# --- wounds (the only two status effects — readable, no rule salad) ------------------
const BLEED_TIME := 3.0        ## the saw opens a wound: damage-over-time, refreshed by re-hits
const VENOM_TIME := 2.4        ## the ray's barb: slow + light damage-over-time
const VENOM_SLOW := 0.62       ## steering-speed multiplier while envenomed
const VENOM_DPS := 3.0

# --- terrain: sandbanks are the hazard now (normalized elevation t in 0..1) ---------
const SHOAL_T := 0.74          ## above this you are over a bright shoal (draggy)
const SAND_T := 0.86           ## above this you are nearly BEACHED (very slow — open water is safety)
const SHOAL_SLOW := 0.82       ## steering-speed multiplier over a shoal (knockback unaffected —
const SAND_SLOW := 0.55        ##  ramming a rival ONTO a sandbank stays a legitimate setup)

# --- run state -------------------------------------------------------------------
var score := 0
var best := 0
var kills := 0
var picking := false   ## true while the start species-picker overlay is up
var player_mass := 1.0 ## the living player's mass — read by nameplate threat tints
var fx: FxLayer        ## the single shared spark layer (set by Main at build time)

const NAMES := [
	"Mako", "Bruce", "Razor", "Riptide", "Barb", "Sawyer", "Marlin", "Gill",
	"Kraken", "Abyss", "Torpedo", "Reef", "Dorsal", "Undertow", "Scylla",
	"Moby", "Tempest", "Drift", "Snapper", "Current",
]

const PALETTE := [
	Color("e05a4d"), Color("e0904d"), Color("d9c24a"), Color("74c04a"),
	Color("4ac0a3"), Color("4a9ec0"), Color("6a6ae0"), Color("a85ce0"),
	Color("e05ca8"), Color("7a8ea8"), Color("58c07a"), Color("50b8c8"),
]

var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()

func rng() -> RandomNumberGenerator:
	return _rng

func random_name() -> String:
	return NAMES[_rng.randi() % NAMES.size()]

func random_color() -> Color:
	return PALETTE[_rng.randi() % PALETTE.size()]

## Called by the player only — bump the run score and keep the best.
func set_player_score(s: int) -> void:
	score = s
	if score > best:
		best = score
	score_changed.emit(score, best)

func add_kill() -> void:
	kills += 1
	kills_changed.emit(kills)

func reset_run() -> void:
	score = 0
	kills = 0
	score_changed.emit(score, best)
	kills_changed.emit(kills)

## Derived stats shared by every fish, so player and bots scale identically.
static func speed_for_mass(mass: float) -> float:
	return BASE_MAX_SPEED * pow(mass, SPEED_MASS_EXP)

static func body_radius_for_mass(mass: float) -> float:
	return BASE_BODY_RADIUS * sqrt(mass)

static func health_for_mass(mass: float) -> float:
	return BASE_HEALTH + HEALTH_PER_MASS * mass

## Agility multiplier: heavier => laggier turns, slower weapon whip.
static func agility_for_mass(mass: float) -> float:
	return pow(mass, -0.22)

# --- hit-stop ---------------------------------------------------------------------
# One shared real-time deadline: overlapping stops EXTEND the freeze, and scale
# never goes below 0.05 (delta-division code NaNs at 0). The restore is POLLED in
# _process against the wall clock — a one-shot timer callback can wake a few ms
# early (frame-delta drift), skip its restore, and leave the game in slow motion
# forever; a per-frame check self-heals on the next frame no matter what.
var _hitstop_deadline := 0.0

## Freeze the game briefly — ONLY for player-involved moments (a global time_scale
## freeze for an off-screen bot fight reads as a frame hitch, not as impact).
func hitstop(scale: float, duration: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_hitstop_deadline = maxf(_hitstop_deadline, now + duration)
	Engine.time_scale = clampf(minf(Engine.time_scale, scale), 0.05, 1.0)

func _process(_delta: float) -> void:
	if Engine.time_scale < 1.0 and Time.get_ticks_msec() / 1000.0 >= _hitstop_deadline:
		Engine.time_scale = 1.0

## Spawn a short floating label at a world position in the current scene.
func popup(text: String, pos: Vector2, color: Color = Color.WHITE, scale := 1.0) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var ft := FloatingText.new()
	scene.add_child(ft)
	ft.global_position = pos
	ft.setup(text, color, scale)
