# Runner

A small endless runner made with [LÖVE](https://love2d.org) (11.5).
Jump over obstacles, use yellow orbs to get over the tall ones, and run through
five locations that change as you go: Desert, Forest, Antarctic, Mountains and Taiga.

All graphics are generated in code — there are no image files.

## Running

Install LÖVE 11.x, then from this folder:

```
love .
```

## Controls

| Key                    | Action                                     |
| ---------------------- | ------------------------------------------ |
| Space / Up / W / Z     | Jump (tap for a hop, hold for a longer jump) |
| Jump while on an orb   | Orb boost over tall obstacles              |
| Space / R              | Restart after game over                    |
| Esc                    | Quit                                       |

You can land on top of obstacles and run across them; only hitting their side ends the run.

## Files

- `main.lua` — game logic: player, jumping, obstacles, orbs, location changes
- `biomes.lua` — the locations: generated pixel-art textures, parallax backgrounds, weather
- `conf.lua` — window settings

Tuning values (speed, jump, orb strength, how long each location lasts) are at the top of `main.lua`.
