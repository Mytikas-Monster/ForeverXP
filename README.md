# ForeverXP

Leveling-efficiency addon for World of Warcraft: Forever (Interface 16001).

- **XP per hour** over the last 60 minutes, with the whole-session average beside it.
- **Grade S to F**: your XP/hour against a par pace for your level and class.
- **Hours to level 60** at the pace you are playing now.
- **Top 5 time losses**: what is slowing you down, in minutes lost per hour, with advice.

The advice is written for a Human Protection Warrior (Arms two-hander to 15,
Protection from 16). The measurements work for every class; other classes get
class-neutral advice and skip the Warrior-only checks.

## Install

Copy `ForeverXP.toc`, the six `.lua` files next to it and this README into
`World of Warcraft\_forever_\Interface\AddOns\ForeverXP\`, or run `tools/deploy.sh`.
New files are only picked up by a full client restart, not by `/reload`.

## Using it

Hover the top half of the window for the full breakdown (par, next grade, XP
sources, where the time went, three estimates of hours to 60). Hover a row for
what was measured and what to do about it. Drag to move, drag the corner to resize.

| Command | |
|---|---|
| `/fxp` | show or hide the window |
| `/fxp report` | print grade, estimate and top factors to chat |
| `/fxp reset` | start a new session |
| `/fxp lock` | lock or unlock the window |
| `/fxp scale 0.5-2` | window scale |
| `/fxp prot on\|off` | Protection Warrior checks (shield, pull size) |
| `/fxp selftest` | which game API calls work on this client |
| `/fxp errors` | stored Lua errors (`/fxp errors clear`) |

A session survives `/reload` and a logout of up to 10 minutes. The grade appears
after 5 minutes of play.

## How the numbers are made

**Grade.** `your XP/hour / par(level, class)`: S 175%+, A 135%+, B 110%+, C 90%+,
D 70%+, E 45%+, F below.

Par is a curve fitted to the only published per-bracket pace for Forever, a
community estimate of about 150 hours to 60 (1-10 6 h, 10-20 14 h, 20-30 22 h,
30-40 28 h, 40-50 36 h, 50-60 44 h), with Warrior 12% slower (about 168 h). **It
is an estimate, not a measured benchmark**; nobody has published one yet. The
one real measurement available (level 28, forum test) lands where it should:
questing only is a B, the best questing-plus-dungeon route a high A.

**Hours to 60.** XP/hour grows about ninefold between level 5 and 55, so
dividing the remaining XP by today's XP/hour overestimates badly. The estimate
keeps your *percentage of par* and walks it along the par curve instead. The
tooltip also shows the naive flat-rate figure.

**Time losses.** Once a second the addon books the time as one activity: dead,
flight path, combat, town, travel (20 s or more of uninterrupted movement),
short movement, recovery (standing still right after a fight), idle (still for
45 s or more, or AFK), or a short stop. Each factor is converted to minutes lost
per hour beyond what efficient play still needs:

| Factor | Measured from |
|---|---|
| Travel on foot / mount | travel time above 12 min/h |
| Long flight paths | flight time above 3 min/h |
| Hearthstone not used | walked 2+ min home to your bind town with the stone ready |
| Too long in town | rest-area and vendor/trainer/AH/mail/bank time above 4 min/h |
| Idle / AFK | idle time above 1 min/h |
| Recovery between pulls | post-fight standing above 8 min/h |
| Deaths and corpse runs | all time dead |
| Slow kills | solo combat seconds per kill above 40 |
| Mobs too low level `~` | solo kill XP under 70% of a same-level mob |
| Pulling one mob at a time `~` | under 1.25 kills per pull (Protection, 16+) |
| Low-value quests `~` | tiny turn-ins, grey and red quests in the log |
| Repeating the same dungeon `~` | third run onwards |
| Mostly grinding `~` | under 25% of XP from quests |
| No rested XP `~` | no rested bonus while most XP is from kills |
| No shield / shield before 16 / bags full / much higher party member `~` | gear, bags, party |

Rows marked `~` are rules of thumb from the leveling meta rather than measured
time, and are shown with a `~` in the window.

## Tuning

Every threshold, allowance and the par curve is a constant at the top of
`Data.lua`. When real Forever benchmarks appear, `BASELINE_ANCHORS` and
`CLASS_PACE` are the two tables to change.

## Limits

- Forever's client gives addons no combat log, so a kill is "XP gained in or
  just after combat that is not a quest turn-in". Group kills near you count.
- Kill XP in a party or dungeon is not compared against same-level mobs.
- Spec is not read from the client: Warrior checks assume Protection from 16
  until you turn them off with `/fxp prot off`.
- If the client hides a value (a "secret value") the addon treats it as unknown
  and skips the checks that need it; it never raises an error for it.

## Development

`tests/run.sh` syntax-checks every file and runs the tests under Lua 5.1
(a local `lua5.1`, otherwise Docker). `tests/wowstub.lua` is a small fake of the
game client, so the whole addon is loaded and played through simulated sessions.

| File | Role |
|---|---|
| `Data.lua` | constants, XP curve, par, grades, estimates (no game API) |
| `Tracker.lua` | rolling one-minute buckets, XP classification (no game API) |
| `Factors.lua` | the factor rules and their advice (no game API) |
| `Core.lua` | guarded API access, events, saved variables, commands |
| `Activity.lua` | the once-a-second activity sampler |
| `UI.lua` | the window and tooltips |

`legacy/v1.2/` is the previous single-file version, kept for reference.
