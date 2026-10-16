-- Endless runner: the player runs in place while obstacles scroll in from the right.
-- Tap jump for a short hop, hold it for a longer, higher jump.
-- Obstacles too tall to jump get a yellow orb in front: press jump while touching it to get boosted.
-- The player can land on and run across the tops of obstacles.
-- Every so often the location changes at random (see biomes.lua).

local Biomes = require("biomes")

local TILE = 32
local SCREEN_W, SCREEN_H = 800, 480
local GROUND_Y = SCREEN_H - 2 * TILE   -- top of the ground
local PLAYER_X = 140

-- Jump tuning
local GRAVITY        = 2200
local JUMP_SPEED     = 600
local HOLD_GRAVITY   = 0.35   -- gravity multiplier while jump is held (rising only)
local MAX_HOLD_TIME  = 0.22   -- how long holding jump keeps extending it (seconds)
local JUMP_BUFFER    = 0.12   -- a press this soon before landing still counts
local MAX_FALL       = 1000

-- World speed tuning (pixels / second)
local START_SPEED    = 320
local SPEED_GAIN     = 8      -- added every second
local MAX_SPEED      = 700

-- Orb tuning
local ORB_SPEED      = 1000   -- upward speed an orb gives
local ORB_RADIUS     = 22     -- drawn size
local ORB_REACH      = 36     -- touch radius (bigger than drawn, so orbs are easy to catch)
local ORB_HEIGHT     = 110    -- orb center height above the ground

-- Tallest obstacle a fully held jump can reliably get over (found by simulating the
-- jump above; re-check if you change the jump tuning). Anything taller gets an orb.
local MAX_JUMP_HEIGHT = 144

-- Distance between location changes (pixels of scrolling)
local BIOME_MIN      = 20000
local BIOME_MAX      = 36000
local BIOME_FADE     = 1.2    -- seconds for the background to crossfade

-- Obstacle kinds (tallest is 208: the orb is tuned to get over that at every speed)
local OBSTACLE_TYPES = {
    { w = 32, h = 32,  kind = "crate" },
    { w = 32, h = 48,  kind = "crate" },
    { w = 64, h = 32,  kind = "crate" },
    { w = 96, h = 32,  kind = "crate" },
    { w = 64, h = 64,  kind = "crate" },
    { w = 40, h = 64,  kind = "pillar" },
    { w = 40, h = 96,  kind = "pillar" },
    { w = 40, h = 128, kind = "pillar" },
    { w = 40, h = 176, kind = "pillar" },
    { w = 40, h = 208, kind = "pillar" },
    { w = 64, h = 176, kind = "crate" },
}
for _, t in ipairs(OBSTACLE_TYPES) do
    t.orb = t.h > MAX_JUMP_HEIGHT
end

local state            -- "ready", "playing", "over"
local player
local obstacles
local orbs
local clouds
local speed
local scroll           -- total distance scrolled
local nextSpawn        -- distance until the next obstacle
local nextType         -- obstacle type that will spawn next
local score, best = 0, 0

-- Locations are laid out along the track: zones[i] = { start = world x, biome = ... }.
-- Ground and obstacles use the zone they are in; the background follows the player.
local zones
local nextBiomeChange  -- scroll distance at which the next location is queued
local bgBiome, prevBgBiome, bgFade
local banner = { text = "", t = 0 }
local bgCanvas
local quad             -- reused for tiling textures over obstacles

local function isJumpKey(key)
    return key == "space" or key == "up" or key == "w" or key == "z"
end

local function jumpHeld()
    return love.keyboard.isDown("space", "up", "w", "z")
end

local function loadBest()
    if love.filesystem.getInfo("best.txt") then
        best = tonumber((love.filesystem.read("best.txt"))) or 0
    end
end

local function saveBest()
    love.filesystem.write("best.txt", tostring(best))
end

local function randomBiome(except)
    local b
    repeat
        b = Biomes.list[love.math.random(#Biomes.list)]
    until b ~= except
    return b
end

local function biomeAt(worldX)
    local b = zones[1].biome
    for _, z in ipairs(zones) do
        if z.start <= worldX then b = z.biome else break end
    end
    return b
end

local function showBanner(text)
    banner.text = text
    banner.t = 2.5
end

local function reset()
    player = {
        x = PLAYER_X, y = GROUND_Y - 32,
        w = 24, h = 32,
        vy = 0,
        onGround = true,
        holdTime = 0,      -- how long the current jump has been held
        holding = false,
        buffer = 0,        -- time left on a buffered jump press
        runAnim = 0,
    }
    obstacles = {}
    orbs = {}
    speed = START_SPEED
    scroll = 0
    nextSpawn = SCREEN_W * 0.6
    nextType = OBSTACLE_TYPES[love.math.random(#OBSTACLE_TYPES)]
    score = 0

    local b = randomBiome()
    zones = { { start = -math.huge, biome = b } }
    nextBiomeChange = love.math.random(BIOME_MIN, BIOME_MAX)
    bgBiome, prevBgBiome, bgFade = b, nil, 1
    showBanner(b.name)
end

local function startJump(p)
    p.vy = -JUMP_SPEED
    p.onGround = false
    p.holding = true
    p.holdTime = 0
    p.buffer = 0
end

local function spawnObstacle()
    local t = nextType
    local o = {
        x = SCREEN_W + 10 + speed * 0.6,
        y = GROUND_Y - t.h,
        w = t.w, h = t.h,
        kind = t.kind,
    }
    o.biome = biomeAt(o.x + scroll)
    if not t.orb then o.x = SCREEN_W + 10 end
    table.insert(obstacles, o)

    if t.orb then
        -- Far enough in front that an orb jump from anywhere on the orb gets over
        -- (or onto) the obstacle
        table.insert(orbs, {
            x = o.x - (40 + speed * 0.22),
            y = GROUND_Y - ORB_HEIGHT,
            used = false,
            fx = 0,    -- time since it was used (for the burst effect)
        })
    end

    -- Gap scales with speed so there is always time to land and jump again.
    -- Obstacles with an orb were pushed further right above, so the player
    -- has room to land before hopping up to the orb.
    nextType = OBSTACLE_TYPES[love.math.random(#OBSTACLE_TYPES)]
    nextSpawn = (o.x - SCREEN_W - 10) + t.w + speed * love.math.random() * 0.8 + speed * 0.75
    if t.orb then
        nextSpawn = nextSpawn + speed * 0.4   -- orb jumps are long; leave room to land after
    end
end

local function touchesOrb(p, orb)
    local nx = math.max(p.x, math.min(orb.x, p.x + p.w))
    local ny = math.max(p.y, math.min(orb.y, p.y + p.h))
    return (nx - orb.x) ^ 2 + (ny - orb.y) ^ 2 <= ORB_REACH ^ 2
end

local function orbJump(p, orb)
    p.vy = -ORB_SPEED
    p.onGround = false
    p.holding = false     -- orb jumps have a fixed height
    p.buffer = 0
    orb.used = true
end

local function overlaps(a, b, shrink)
    shrink = shrink or 0   -- slightly forgiving hitbox
    return a.x + shrink < b.x + b.w and b.x < a.x + a.w - shrink
       and a.y + shrink < b.y + b.h and b.y < a.y + a.h - shrink
end

function love.load()
    love.graphics.setDefaultFilter("nearest", "nearest")
    love.graphics.setFont(love.graphics.newFont(18))
    loadBest()
    Biomes.load(SCREEN_W, GROUND_Y)
    bgCanvas = love.graphics.newCanvas(SCREEN_W, SCREEN_H)
    quad = love.graphics.newQuad(0, 0, 1, 1, 1, 1)
    clouds = {}
    for i = 1, 6 do
        clouds[i] = {
            x = love.math.random(0, SCREEN_W),
            y = love.math.random(30, 180),
            s = love.math.random(80, 140) / 100,
        }
    end
    reset()
    state = "ready"
end

function love.keypressed(key)
    if key == "escape" then
        love.event.quit()
        return
    end
    if not isJumpKey(key) and key ~= "r" then return end

    if state == "ready" then
        state = "playing"
        startJump(player)
    elseif state == "over" then
        reset()
        state = "playing"
    elseif state == "playing" and isJumpKey(key) then
        if player.onGround then
            startJump(player)
        else
            player.buffer = JUMP_BUFFER
        end
    end
end

function love.keyreleased(key)
    if isJumpKey(key) then
        player.holding = false
    end
end

local function updatePlayer(p, dt)
    -- Holding jump while rising (for up to MAX_HOLD_TIME) lowers gravity -> longer jump
    local g = GRAVITY
    if p.holding and p.vy < 0 and p.holdTime < MAX_HOLD_TIME and jumpHeld() then
        p.holdTime = p.holdTime + dt
        g = GRAVITY * HOLD_GRAVITY
    else
        p.holding = false
    end

    local prevBottom = p.y + p.h
    p.vy = math.min(p.vy + g * dt, MAX_FALL)
    p.y = p.y + p.vy * dt

    -- Floor is the ground, or the top of an obstacle the player was above last frame.
    -- The small tolerance forgives clipping the top corner of an obstacle.
    local floor = GROUND_Y
    for _, o in ipairs(obstacles) do
        if p.x < o.x + o.w and p.x + p.w > o.x and prevBottom <= o.y + 6 then
            floor = math.min(floor, o.y)
        end
    end

    if p.vy >= 0 and p.y + p.h >= floor then
        p.y = floor - p.h
        p.vy = 0
        if not p.onGround then
            p.onGround = true
            if p.buffer > 0 then startJump(p) end
        end
    else
        p.onGround = false   -- e.g. ran off the end of an obstacle
    end

    p.buffer = math.max(0, p.buffer - dt)
    if p.onGround then p.runAnim = p.runAnim + dt * speed / 40 end
end

function love.update(dt)
    dt = math.min(dt, 1 / 30)

    -- Clouds drift even on the title / game-over screens
    local cloudSpeed = (state == "playing" and speed or START_SPEED) * 0.15
    for _, c in ipairs(clouds) do
        c.x = c.x - cloudSpeed * dt
        if c.x < -120 then
            c.x = SCREEN_W + love.math.random(0, 200)
            c.y = love.math.random(30, 180)
        end
    end

    bgFade = math.min(1, bgFade + dt / BIOME_FADE)
    banner.t = math.max(0, banner.t - dt)
    Biomes.updateParticles(dt, state == "playing" and speed or START_SPEED, bgBiome)

    if state ~= "playing" then return end

    speed = math.min(MAX_SPEED, speed + SPEED_GAIN * dt)
    local dx = speed * dt
    scroll = scroll + dx
    score = math.floor(scroll / 10)

    -- Queue a new location just past the right edge, so it scrolls in
    if scroll >= nextBiomeChange then
        local start = math.ceil((scroll + SCREEN_W + TILE) / TILE) * TILE
        table.insert(zones, { start = start, biome = randomBiome(zones[#zones].biome) })
        nextBiomeChange = scroll + love.math.random(BIOME_MIN, BIOME_MAX)
    end
    -- Background switches when the boundary reaches the player
    local here = biomeAt(scroll + PLAYER_X)
    if here ~= bgBiome then
        prevBgBiome, bgBiome, bgFade = bgBiome, here, 0
        showBanner(here.name)
    end
    while zones[2] and zones[2].start <= scroll - TILE do
        table.remove(zones, 1)
    end

    nextSpawn = nextSpawn - dx
    if nextSpawn <= 0 then spawnObstacle() end

    for i = #orbs, 1, -1 do
        local orb = orbs[i]
        orb.x = orb.x - dx
        if orb.used then orb.fx = orb.fx + dt end
        if orb.x + ORB_REACH < 0 then table.remove(orbs, i) end
    end

    for i = #obstacles, 1, -1 do
        local o = obstacles[i]
        o.x = o.x - dx
        if o.x + o.w < 0 then table.remove(obstacles, i) end
    end

    -- A jump press (buffered for a moment) while touching an orb triggers it
    for _, orb in ipairs(orbs) do
        if not orb.used and player.buffer > 0 and touchesOrb(player, orb) then
            orbJump(player, orb)
        end
    end

    updatePlayer(player, dt)

    -- Standing on top is fine (no overlap); running into a side is game over
    for _, o in ipairs(obstacles) do
        if overlaps(player, o, 4) then
            state = "over"
            if score > best then
                best = score
                saveBest()
            end
            break
        end
    end
end

local function drawGround()
    love.graphics.setColor(1, 1, 1)
    local first = math.floor(scroll / TILE)
    for c = first, first + math.ceil(SCREEN_W / TILE) + 1 do
        local wx = c * TILE
        local x = math.floor(wx - scroll)
        local b = biomeAt(wx)
        love.graphics.draw(b.groundTop, x, GROUND_Y, 0, 2, 2)
        love.graphics.draw(b.groundFill, x, GROUND_Y + TILE, 0, 2, 2)
    end
end

local function drawClouds(b)
    love.graphics.setColor(b.cloudColor)
    for _, c in ipairs(clouds) do
        love.graphics.ellipse("fill", c.x, c.y, 40 * c.s, 16 * c.s)
        love.graphics.ellipse("fill", c.x + 25 * c.s, c.y - 8 * c.s, 28 * c.s, 16 * c.s)
        love.graphics.ellipse("fill", c.x - 22 * c.s, c.y - 4 * c.s, 22 * c.s, 12 * c.s)
    end
end

-- Textures are 16px-per-tile pixel art drawn at 2x, tiled over the obstacle with a quad
local function drawObstacle(o)
    local b = o.biome
    local x, y = math.floor(o.x), math.floor(o.y)
    love.graphics.setColor(1, 1, 1)
    if o.kind == "pillar" then
        local tw, th = b.pillar:getDimensions()
        quad:setViewport(0, 0, o.w / 2, (o.h - 8) / 2, tw, th)
        love.graphics.draw(b.pillar, quad, x, y + 8, 0, 2, 2)
        love.graphics.draw(b.cap, x, y, 0, 2, 2)
    else
        local tw, th = b.block:getDimensions()
        local vy = (th - (o.h / 2) % th) % th   -- line tiles up with the bottom edge
        quad:setViewport(0, vy, o.w / 2, o.h / 2, tw, th)
        love.graphics.draw(b.block, quad, x, y, 0, 2, 2)
    end
end

local function drawOrb(orb)
    if orb.used then
        -- expanding ring that fades out
        local t = orb.fx / 0.35
        if t < 1 then
            love.graphics.setColor(1, 0.95, 0.3, 1 - t)
            love.graphics.setLineWidth(4)
            love.graphics.circle("line", orb.x, orb.y, ORB_RADIUS + t * 30)
            love.graphics.setLineWidth(1)
        end
        return
    end
    local pulse = math.sin(love.timer.getTime() * 6) * 3
    love.graphics.setColor(1, 0.95, 0.3, 0.35)
    love.graphics.circle("fill", orb.x, orb.y, ORB_RADIUS + 8 + pulse)
    love.graphics.setColor(1, 0.85, 0.1)
    love.graphics.circle("fill", orb.x, orb.y, ORB_RADIUS)
    love.graphics.setColor(1, 1, 0.75)
    love.graphics.setLineWidth(3)
    love.graphics.circle("line", orb.x, orb.y, ORB_RADIUS - 6)
    love.graphics.setLineWidth(1)
end

local function drawPlayer()
    local p = player
    -- little leg bob while running
    local bob = p.onGround and math.floor(math.sin(p.runAnim) * 1.5 + 0.5) or 0
    local y = p.y + bob
    love.graphics.setColor(0.85, 0.15, 0.15)
    love.graphics.rectangle("fill", p.x, y, p.w, p.h - bob)
    love.graphics.setColor(0.15, 0.3, 0.85)
    love.graphics.rectangle("fill", p.x, y + p.h * 0.55, p.w, p.h * 0.45 - bob)
    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("fill", p.x + p.w - 9, y + 6, 6, 6)
    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("fill", p.x + p.w - 6, y + 8, 3, 3)
end

-- White text with a dark shadow, readable on every sky
local function printShadow(text, x, y, alpha)
    alpha = alpha or 1
    love.graphics.setColor(0, 0, 0, 0.6 * alpha)
    love.graphics.print(text, x + 2, y + 2)
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.print(text, x, y)
end

local function printCentered(text, y, alpha)
    local font = love.graphics.getFont()
    printShadow(text, math.floor((SCREEN_W - font:getWidth(text)) / 2), y, alpha)
end

local function drawBackground()
    Biomes.drawBackground(bgBiome, scroll, drawClouds)
    if prevBgBiome and bgFade < 1 then
        -- Crossfade: draw the old location on top, fading out
        love.graphics.setCanvas(bgCanvas)
        love.graphics.clear(0, 0, 0, 0)
        Biomes.drawBackground(prevBgBiome, scroll, drawClouds)
        love.graphics.setCanvas()
        love.graphics.setColor(1, 1, 1, 1 - bgFade)
        love.graphics.draw(bgCanvas)
    end
end

function love.draw()
    drawBackground()
    for _, o in ipairs(obstacles) do drawObstacle(o) end
    for _, orb in ipairs(orbs) do drawOrb(orb) end
    drawGround()
    drawPlayer()
    Biomes.drawParticles(bgBiome)

    printShadow(("Score %d   Best %d"):format(score, best), 12, 10)
    if banner.t > 0 and state ~= "over" then
        printCentered("~ " .. banner.text .. " ~", 50, math.min(1, banner.t))
    end

    if state == "ready" then
        printCentered("Press SPACE to start", 170)
        printCentered("Tap to hop, hold for a longer jump", 200)
        printCentered("Press jump while touching a yellow orb for a boost", 230)
    elseif state == "over" then
        love.graphics.setColor(0, 0, 0, 0.35)
        love.graphics.rectangle("fill", 0, 0, SCREEN_W, SCREEN_H)
        printCentered("GAME OVER", 160)
        printCentered(("Score %d"):format(score), 190)
        printCentered("Press SPACE to try again", 230)
    end
end
