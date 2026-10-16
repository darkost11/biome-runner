-- Locations ("biomes"): pixel-art textures generated in code, parallax backgrounds and weather.
-- Every biome provides:
--   groundTop, groundFill  16x16 textures for the two ground rows (drawn at 2x)
--   block                  16x16 texture tiled over box obstacles
--   pillar, cap            20x16 / 20x8 textures for 40px-wide pillar obstacles
--   sky                    gradient mesh, layers(scroll) draws the scenery
--   particles              "snow", "sand" or nil

local Biomes = {}

local W, GROUND_Y

-- 0xRRGGBB -> r, g, b (0..1), optionally brightened/darkened by k
local function hex(c, k)
    k = k or 1
    local r = math.floor(c / 65536) % 256
    local g = math.floor(c / 256) % 256
    local b = c % 256
    return math.min(1, r / 255 * k), math.min(1, g / 255 * k), math.min(1, b / 255 * k)
end

-- Blend two 0xRRGGBB colors (t = 0 -> a, t = 1 -> b)
local function mix(a, b, t)
    local out = 0
    for _, sh in ipairs({ 65536, 256, 1 }) do
        local ca, cb = math.floor(a / sh) % 256, math.floor(b / sh) % 256
        out = out + math.floor(ca + (cb - ca) * t + 0.5) * sh
    end
    return out
end

-- Random brightness wobble around 1
local function j(rng, amount)
    return 1 + (rng:random() - 0.5) * amount
end

-- Builds a texture from fn(x, y, rng) -> color, brightness, alpha (return nil for transparent)
local seed = 1
local function texture(w, h, fn)
    local data = love.image.newImageData(w, h)
    local rng = love.math.newRandomGenerator(seed)
    seed = seed + 1
    data:mapPixel(function(x, y)
        local c, k, a = fn(x, y, rng)
        if not c then return 0, 0, 0, 0 end
        local r, g, b = hex(c, k)
        return r, g, b, a or 1
    end)
    local img = love.graphics.newImage(data)
    img:setFilter("nearest", "nearest")
    img:setWrap("repeat", "repeat")
    return img
end

---------------------------------------------------------------------------
-- Texture patterns
---------------------------------------------------------------------------

-- Ground top: a layer of `top` with a wavy lower edge over `fill`
local function surface(top, edge, fill, depth, var)
    return function(x, y, rng)
        local d = depth + math.floor(love.math.noise(x * 0.35, depth + var) * var)
        if y < d then return top, j(rng, 0.12) * (y == 0 and 1.08 or 1) end
        if y == d then return edge, j(rng, 0.1) end
        return fill, j(rng, 0.18)
    end
end

local function speckled(base, speck, chance)
    return function(x, y, rng)
        if rng:random() < chance then return speck, j(rng, 0.2) end
        return base, j(rng, 0.15) * (0.9 + 0.2 * love.math.noise(x * 0.3, y * 0.3))
    end
end

local function bricks(fill, mortar, bw, bh)
    return function(x, y, rng)
        local row = math.floor(y / bh)
        local ox = (row % 2) * math.floor(bw / 2)
        if y % bh == bh - 1 or (x + ox) % bw == bw - 1 then return mortar, j(rng, 0.1) end
        return fill, j(rng, 0.12) * (y % bh == 0 and 1.12 or 1)
    end
end

local function planks(fill, line, border)
    return function(x, y, rng)
        if x == 0 or y == 0 or x == 15 or y == 15 then return border, j(rng, 0.1) end
        if y % 5 == 0 then return line, j(rng, 0.1) end
        if (x == 2 or x == 13) and (y == 2 or y == 13) then return border end   -- nails
        return fill, j(rng, 0.1) * (0.92 + 0.16 * love.math.noise(x * 0.15, y * 1.3))
    end
end

local function bark(fill, dark)
    return function(x, y, rng)
        if x == 0 or x == 19 then return dark, 0.85 end
        local n = love.math.noise(x * 0.9, y * 0.12)
        if n > 0.7 then return dark, j(rng, 0.1) end
        return fill, j(rng, 0.12) * (0.9 + 0.2 * n) * (x < 6 and 1.1 or 1)
    end
end

-- Pillar top with rounded corners
local function roundedCap(color, spot)
    return function(x, y, rng)
        local inset = ({ 3, 1 })[y + 1] or 0
        if x < inset or x > 19 - inset then return nil end
        if rng:random() < 0.2 then return spot end
        return color, j(rng, 0.12) * (y < 2 and 1.15 or 1) * (x < 6 and 1.08 or 1)
    end
end

-- Snow lying on top of a pillar, with icicle-like drips
local function snowCap(color, shade)
    return function(x, y, rng)
        local depth = 3 + math.floor(love.math.noise(x * 0.7, 2.5) * 5)
        if y > depth then return nil end
        if y == depth then return shade end
        return color, j(rng, 0.04)
    end
end

---------------------------------------------------------------------------
-- Background helpers
---------------------------------------------------------------------------

local function hash(i, k)
    local v = math.sin(i * 127.1 + (k or 0) * 311.7) * 43758.5453
    return v - math.floor(v)
end

-- Calls fn(i, x) for repeating scenery items spaced `spacing` apart, scrolling at `factor`
local function layer(s, factor, spacing, fn)
    local off = s * factor
    for i = math.floor(off / spacing) - 1, math.floor((off + W) / spacing) + 1 do
        fn(i, i * spacing - off)
    end
end

-- Rolling hills/dunes made of thin columns
local function hills(s, factor, baseY, amp, freq, color)
    love.graphics.setColor(hex(color))
    local off = s * factor
    for x = 0, W, 4 do
        local wx = x + off
        local y = baseY - amp * (0.6 * math.sin(wx * freq) + 0.4 * math.sin(wx * freq * 2.3 + 1.7))
        love.graphics.rectangle("fill", x, y, 4, GROUND_Y - y)
    end
end

local function pine(x, baseY, h, color, snow, trunk)
    love.graphics.setColor(hex(trunk or 0x3A2A1A))
    love.graphics.rectangle("fill", x - h * 0.04, baseY - h * 0.15, h * 0.08, h * 0.15)
    local w = h * 0.4
    for k = 0, 2 do
        local ty = baseY - h * (0.12 + k * 0.25)
        local tw = w * (1 - k * 0.25)
        local th = h * 0.4
        love.graphics.setColor(hex(color))
        love.graphics.polygon("fill", x - tw, ty, x + tw, ty, x, ty - th)
        if snow then
            love.graphics.setColor(hex(0xF4F8FF))
            love.graphics.polygon("fill", x - tw * 0.35, ty - th * 0.65, x + tw * 0.35, ty - th * 0.65, x, ty - th)
        end
    end
end

local function roundTree(x, baseY, h, leaf, trunk)
    love.graphics.setColor(hex(trunk))
    love.graphics.rectangle("fill", x - h * 0.05, baseY - h * 0.5, h * 0.1, h * 0.5)
    love.graphics.setColor(hex(leaf))
    love.graphics.circle("fill", x, baseY - h * 0.68, h * 0.3)
    love.graphics.circle("fill", x - h * 0.2, baseY - h * 0.5, h * 0.22)
    love.graphics.circle("fill", x + h * 0.2, baseY - h * 0.52, h * 0.22)
end

-- A dense row of small, single-color trees (already blended toward the fog color)
local function distantTrees(s, factor, spacing, baseY, h, color, isPine, salt)
    layer(s, factor, spacing, function(i, x)
        local th = h * (0.7 + 0.6 * hash(i, salt))
        x = x + hash(i, salt + 1) * spacing
        if isPine then
            pine(x, baseY, th, color, false, color)
        else
            love.graphics.setColor(hex(color))
            love.graphics.rectangle("fill", x - th * 0.05, baseY - th * 0.4, th * 0.1, th * 0.4)
            love.graphics.circle("fill", x, baseY - th * 0.6, th * 0.35)
            love.graphics.circle("fill", x + th * 0.2, baseY - th * 0.45, th * 0.28)
        end
    end)
end

-- Fog: fades in from transparent at topY to solid at solidY, solid down to the ground
local function fogMesh(color, topY, solidY)
    local r, g, b = hex(color)
    return love.graphics.newMesh({
        { 0, topY, 0, 0, r, g, b, 0 },
        { W, topY, 0, 0, r, g, b, 0 },
        { W, solidY, 0, 0, r, g, b, 1 },
        { 0, solidY, 0, 0, r, g, b, 1 },
    }, "fan", "static")
end

local function drawFog(mesh, color, solidY)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(mesh)
    love.graphics.setColor(hex(color))
    love.graphics.rectangle("fill", 0, solidY, W, GROUND_Y - solidY)
end

-- Flat-topped desert butte
local function mesa(x, baseY, h, w, color)
    love.graphics.setColor(hex(color))
    love.graphics.polygon("fill", x - w, baseY, x - w * 0.7, baseY - h * 0.75,
        x + w * 0.65, baseY - h * 0.75, x + w, baseY)
    love.graphics.polygon("fill", x - w * 0.55, baseY - h * 0.74, x - w * 0.45, baseY - h,
        x + w * 0.35, baseY - h, x + w * 0.5, baseY - h * 0.74)
end

-- A lone obelisk, or a broken colonnade (r picks which)
local function ruins(x, baseY, h, color, r)
    love.graphics.setColor(hex(color))
    if r < 0.5 then
        love.graphics.polygon("fill", x - 6, baseY, x - 4, baseY - h, x + 4, baseY - h, x + 6, baseY)
        love.graphics.polygon("fill", x - 4, baseY - h, x + 4, baseY - h, x, baseY - h - 8)
    else
        for k = 0, 3 do
            local ch = k < 2 and h or h * (0.3 + 0.5 * hash(k, r * 100))
            love.graphics.rectangle("fill", x + k * 14 - 21, baseY - ch, 7, ch)
        end
        love.graphics.rectangle("fill", x - 24, baseY - h - 4, 27, 5)   -- surviving lintel
    end
end

-- Slowly drifting aurora ribbons, fading downward
local function aurora(s, colors)
    local t = love.timer.getTime()
    for k, c in ipairs(colors) do
        local r, g, b = hex(c)
        for x = 0, W, 6 do
            local wx = x + s * 0.01
            local y = 30 + k * 30 + 22 * math.sin(wx * 0.008 + t * 0.25 + k * 2) + 10 * math.sin(wx * 0.021 - t * 0.4)
            local len = 55 + 25 * math.sin(wx * 0.013 + t * 0.3 + k)
            local a = 0.12 + 0.07 * math.sin(wx * 0.017 + t * 0.5 + k * 1.3)
            love.graphics.setColor(r, g, b, a)
            love.graphics.rectangle("fill", x, y, 6, len * 0.4)
            love.graphics.setColor(r, g, b, a * 0.6)
            love.graphics.rectangle("fill", x, y + len * 0.4, 6, len * 0.35)
            love.graphics.setColor(r, g, b, a * 0.3)
            love.graphics.rectangle("fill", x, y + len * 0.75, 6, len * 0.25)
        end
    end
end

local function peak(x, baseY, h, w, color, snowColor)
    love.graphics.setColor(hex(color))
    love.graphics.polygon("fill", x - w, baseY, x + w, baseY, x, baseY - h)
    if snowColor then
        local f = 0.3
        local sy = baseY - h * (1 - f)
        love.graphics.setColor(hex(snowColor))
        love.graphics.polygon("fill", x - w * f, sy, x, sy - h * 0.04, x, baseY - h)
        love.graphics.polygon("fill", x, sy - h * 0.04, x + w * f, sy, x, baseY - h)
        love.graphics.polygon("fill", x - w * f * 0.5, sy + h * 0.06, x - w * f, sy, x, sy - h * 0.04)
    end
end

local function iceberg(x, baseY, h, w)
    love.graphics.setColor(hex(0xEAF6FF))
    love.graphics.polygon("fill",
        x - w, baseY, x - w * 0.7, baseY - h * 0.7, x - w * 0.2, baseY - h,
        x + w * 0.3, baseY - h * 0.85, x + w * 0.8, baseY - h * 0.4, x + w, baseY)
    love.graphics.setColor(hex(0xBFDDF0))
    love.graphics.polygon("fill",
        x + w * 0.1, baseY, x + w * 0.3, baseY - h * 0.85, x + w * 0.8, baseY - h * 0.4, x + w, baseY)
end

local function skyMesh(top, bottom)
    local tr, tg, tb = hex(top)
    local br, bg, bb = hex(bottom)
    return love.graphics.newMesh({
        { 0, 0, 0, 0, tr, tg, tb, 1 },
        { W, 0, 0, 0, tr, tg, tb, 1 },
        { W, GROUND_Y, 0, 0, br, bg, bb, 1 },
        { 0, GROUND_Y, 0, 0, br, bg, bb, 1 },
    }, "fan", "static")
end

---------------------------------------------------------------------------
-- Biome definitions
---------------------------------------------------------------------------

local function makeBiomes()
    local FOREST_FOG = 0xD6ECF2
    local forestFog = fogMesh(FOREST_FOG, GROUND_Y - 105, GROUND_Y - 58)
    local TAIGA_FOG = 0xA9BACB
    local taigaFog = fogMesh(TAIGA_FOG, GROUND_Y - 115, GROUND_Y - 52)
    local DESERT_HAZE = 0xF4DDB0
    local desertHazeFar = fogMesh(DESERT_HAZE, GROUND_Y - 150, GROUND_Y - 55)
    local desertHazeNear = fogMesh(DESERT_HAZE, GROUND_Y - 75, GROUND_Y - 36)
    local ICE_FOG = 0xEAF5FF
    local iceFogFar = fogMesh(ICE_FOG, GROUND_Y - 140, GROUND_Y - 60)
    local iceFogNear = fogMesh(ICE_FOG, GROUND_Y - 60, GROUND_Y - 28)
    local MOUNTAIN_MIST = 0xD6E8F5
    local mountainMistFar = fogMesh(MOUNTAIN_MIST, GROUND_Y - 180, GROUND_Y - 95)
    local mountainMistNear = fogMesh(MOUNTAIN_MIST, GROUND_Y - 95, GROUND_Y - 30)

    return {
        {
            name = "Desert",
            sky = skyMesh(0x5BA8E0, 0xF7E3B5),
            cloudColor = { 1, 1, 1, 0.5 },
            particles = "sand", particleCount = 40,
            groundTop = texture(16, 16, surface(0xF7DC9A, 0xE0B868, 0xE8C27A, 2, 2)),
            groundFill = texture(16, 16, function(x, y, rng)
                if (y + math.floor(math.sin(x * 0.4) * 1.5 + 0.5)) % 5 == 0 then return 0xD4A85E, j(rng, 0.08) end
                return 0xE8C27A, j(rng, 0.1)
            end),
            block = texture(16, 16, bricks(0xD9A55B, 0xA87A3A, 8, 4)),
            pillar = texture(20, 16, function(x, y, rng)   -- cactus
                if x == 0 or x == 19 then return 0x2E6B2E end
                if x % 4 == 2 then return 0x3E8E3E, 0.9 end
                if x % 4 == 0 and y % 6 == 3 then return 0xF4F0C0 end   -- spines
                return 0x4FAF4F, j(rng, 0.08) * (x < 6 and 1.1 or 1)
            end),
            cap = texture(20, 8, function(x, y, rng)
                local inset = ({ 4, 2, 1 })[y + 1] or 0
                if x < inset or x > 19 - inset then return nil end
                if x == inset or x == 19 - inset then return 0x2E6B2E end
                if x % 4 == 2 then return 0x3E8E3E, 0.9 end
                return 0x4FAF4F, j(rng, 0.08) * (y < 2 and 1.15 or 1)
            end),
            layers = function(s)
                love.graphics.setColor(1, 0.95, 0.75, 0.35)
                love.graphics.circle("fill", 640, 90, 58)
                love.graphics.setColor(hex(0xFFF3C4))
                love.graphics.circle("fill", 640, 90, 40)
                -- deep layers: distant red buttes and lone ruins swallowed by heat haze
                layer(s, 0.015, 260, function(i, x)
                    if hash(i, 8) < 0.35 then return end
                    mesa(x + hash(i, 9) * 80, GROUND_Y - 50, 60 + hash(i, 10) * 55, 70 + hash(i, 11) * 70,
                        mix(0xC07E52, DESERT_HAZE, 0.62))
                end)
                layer(s, 0.03, 380, function(i, x)
                    if hash(i, 12) < 0.55 then return end
                    ruins(x + hash(i, 13) * 150, GROUND_Y - 52, 40 + hash(i, 14) * 30,
                        mix(0x9A6E44, DESERT_HAZE, 0.5), hash(i, 15))
                end)
                drawFog(desertHazeFar, DESERT_HAZE, GROUND_Y - 55)
                layer(s, 0.06, 650, function(i, x)
                    if hash(i) < 0.5 then return end
                    local h = 70 + hash(i, 1) * 50
                    local by = GROUND_Y - 40
                    love.graphics.setColor(hex(0xD9B36E))
                    love.graphics.polygon("fill", x - h, by, x + h, by, x, by - h)
                    love.graphics.setColor(hex(0xB8904F))
                    love.graphics.polygon("fill", x, by, x + h, by, x, by - h)
                end)
                drawFog(desertHazeNear, DESERT_HAZE, GROUND_Y - 36)
                hills(s, 0.15, GROUND_Y - 55, 22, 0.006, 0xE9C98A)
                hills(s, 0.35, GROUND_Y - 20, 16, 0.011, 0xDDB06A)
            end,
        },
        {
            name = "Forest",
            sky = skyMesh(0x6FB6F0, 0xCDEBFF),
            cloudColor = { 1, 1, 1, 0.9 },
            groundTop = texture(16, 16, surface(0x5CBF3A, 0x3E8A28, 0x7A4E25, 4, 3)),
            groundFill = texture(16, 16, speckled(0x7A4E25, 0x5C3A1B, 0.12)),
            block = texture(16, 16, planks(0xB57A3C, 0x8A5A28, 0x5E3C1A)),
            pillar = texture(20, 16, bark(0x8A5A2E, 0x5E3C1C)),
            cap = texture(20, 8, roundedCap(0x4AA03E, 0x2E6B2A)),
            layers = function(s)
                -- distant tree line fading into fog, then pale, sparse scenery in front
                distantTrees(s, 0.03, 10, GROUND_Y - 78, 30, mix(0x4F8F4A, FOREST_FOG, 0.72), false, 7)
                distantTrees(s, 0.06, 13, GROUND_Y - 64, 38, mix(0x4F8F4A, FOREST_FOG, 0.55), false, 9)
                drawFog(forestFog, FOREST_FOG, GROUND_Y - 58)
                hills(s, 0.1, GROUND_Y - 32, 10, 0.004, 0xA9D3A6)
                layer(s, 0.25, 90, function(i, x)
                    if hash(i) < 0.4 then return end
                    roundTree(x + hash(i, 4) * 30, GROUND_Y, 60 + hash(i, 1) * 30, 0x96C78F, 0x9C8A74)
                end)
                layer(s, 0.45, 240, function(i, x)
                    if hash(i, 2) < 0.5 then return end
                    roundTree(x + hash(i, 5) * 60, GROUND_Y, 90 + hash(i, 3) * 30, 0x7DB876, 0x8A7560)
                end)
            end,
        },
        {
            name = "Antarctic",
            sky = skyMesh(0x5F86B8, 0xEAF5FF),
            cloudColor = { 0.95, 0.97, 1, 0.9 },
            particles = "snow", particleCount = 120,
            groundTop = texture(16, 16, surface(0xFFFFFF, 0xCFE8F5, 0x9FD0EC, 6, 3)),
            groundFill = texture(16, 16, function(x, y, rng)
                local n = love.math.noise(x * 0.3, y * 0.3, 7)
                if math.abs(n - 0.5) < 0.03 then return 0x6FA8CC end   -- cracks
                return 0x9FD0EC, j(rng, 0.06) * (0.92 + 0.16 * n)
            end),
            block = texture(16, 16, function(x, y, rng)   -- ice block
                if x == 15 or y == 15 then return 0x1F5C88 end
                if x == 0 or y == 0 then return 0xD8F2FF end
                if x == 14 or y == 14 then return 0x3A7EB0 end
                if (x + y) % 11 == 0 and x > 2 and x < 13 then return 0xE6F7FF end
                return 0x5FAEDC, j(rng, 0.06)
            end),
            pillar = texture(20, 16, function(x, y, rng)   -- ice column
                if x == 0 or x == 19 then return 0x1F5C88 end
                if x == 18 then return 0x3A7EB0 end
                if x == 4 or x == 5 then return 0xD8F2FF end
                if x % 6 == 2 then return 0x4E9ACB end
                return 0x6CB7E2, j(rng, 0.05)
            end),
            cap = texture(20, 8, snowCap(0xFFFFFF, 0x3A7EB0)),
            layers = function(s)
                aurora(s, { 0x7FFFD0, 0x9C8CFF })
                -- deep layers: faint ice peaks on the horizon, half lost in fog
                layer(s, 0.02, 150, function(i, x)
                    peak(x + hash(i, 6) * 60, GROUND_Y - 45, 100 + hash(i, 7) * 80, 110 + hash(i, 8) * 50,
                        mix(0x8FB6D6, ICE_FOG, 0.62), mix(0xC8DDEE, ICE_FOG, 0.5))
                end)
                drawFog(iceFogFar, ICE_FOG, GROUND_Y - 60)
                layer(s, 0.1, 300, function(i, x)
                    if hash(i) < 0.3 then return end
                    iceberg(x + hash(i, 1) * 100, GROUND_Y - 30, 60 + hash(i, 2) * 70, 70 + hash(i, 3) * 60)
                end)
                drawFog(iceFogNear, ICE_FOG, GROUND_Y - 28)
                hills(s, 0.3, GROUND_Y - 25, 12, 0.008, 0xDDEFFA)
            end,
        },
        {
            name = "Mountains",
            sky = skyMesh(0x7FB2E5, 0xD6E8F5),
            cloudColor = { 1, 1, 1, 0.85 },
            groundTop = texture(16, 16, surface(0x7A9A5A, 0x5A6A4A, 0x7D7D82, 3, 2)),
            groundFill = texture(16, 16, speckled(0x7D7D82, 0x5E5E63, 0.15)),
            block = texture(16, 16, bricks(0x9A7556, 0x3E2C1E, 8, 5)),
            pillar = texture(20, 16, function(x, y, rng)   -- rock column
                if x == 0 or x == 19 then return 0x3A2A1E end
                local n = love.math.noise(x * 0.3, y * 0.3, 5)
                if y % 8 == 7 and n > 0.4 then return 0x4E3A2A end
                return 0x8E6C50, j(rng, 0.1) * (0.85 + 0.3 * n) * (x < 6 and 1.1 or 1)
            end),
            cap = texture(20, 8, snowCap(0xF2F6FA, 0x6E7C8C)),
            layers = function(s)
                -- deep layer: a giant, faint range far behind, with mist in the valleys
                layer(s, 0.03, 120, function(i, x)
                    peak(x + hash(i, 6) * 50, GROUND_Y - 60, 210 + hash(i, 7) * 80, 120 + hash(i, 8) * 40,
                        mix(0x9FB0C6, MOUNTAIN_MIST, 0.72), mix(0xE4EEF8, MOUNTAIN_MIST, 0.6))
                end)
                drawFog(mountainMistFar, MOUNTAIN_MIST, GROUND_Y - 95)
                layer(s, 0.08, 180, function(i, x)
                    peak(x + hash(i) * 60, GROUND_Y - 20, 180 + hash(i, 1) * 90, 130 + hash(i, 2) * 40,
                        0xB4C2D4, 0xF2F6FA)
                end)
                drawFog(mountainMistNear, MOUNTAIN_MIST, GROUND_Y - 30)
                layer(s, 0.18, 140, function(i, x)
                    peak(x + hash(i, 3) * 50, GROUND_Y, 110 + hash(i, 4) * 60, 90 + hash(i, 5) * 30,
                        0x98A6B8, 0xEEF2F6)
                end)
                hills(s, 0.4, GROUND_Y - 22, 14, 0.01, 0x5F7A55)
            end,
        },
        {
            name = "Taiga",
            sky = skyMesh(0x56708F, 0xB8C8D8),
            cloudColor = { 0.85, 0.88, 0.92, 0.9 },
            particles = "snow", particleCount = 50,
            groundTop = texture(16, 16, surface(0xF4F8FF, 0xC6D6E6, 0x4A3A2A, 4, 3)),
            groundFill = texture(16, 16, speckled(0x4A3A2A, 0x2E241A, 0.15)),
            block = texture(16, 16, planks(0x8A6440, 0x5E4026, 0x3C2816)),
            pillar = texture(20, 16, bark(0x5E4632, 0x3A2A1C)),
            cap = texture(20, 8, snowCap(0xF4F8FF, 0xC6D6E6)),
            layers = function(s)
                hills(s, 0.08, GROUND_Y - 120, 25, 0.005, 0x6E8296)
                distantTrees(s, 0.03, 9, GROUND_Y - 74, 34, mix(0x2C4A3B, TAIGA_FOG, 0.7), true, 7)
                distantTrees(s, 0.06, 12, GROUND_Y - 60, 42, mix(0x2C4A3B, TAIGA_FOG, 0.5), true, 9)
                drawFog(taigaFog, TAIGA_FOG, GROUND_Y - 52)
                layer(s, 0.2, 110, function(i, x)
                    if hash(i) < 0.5 then return end
                    pine(x + hash(i, 4) * 40, GROUND_Y - 10, 60 + hash(i, 1) * 30, 0x4A6858, true)
                end)
                layer(s, 0.45, 320, function(i, x)
                    if hash(i, 2) < 0.4 then return end
                    pine(x + hash(i, 5) * 120, GROUND_Y, 110 + hash(i, 3) * 40, 0x2C4A3B, true)
                end)
            end,
        },
    }
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function Biomes.load(screenW, groundY)
    W, GROUND_Y = screenW, groundY
    Biomes.list = makeBiomes()
end

-- Sky, then clouds (via callback, so they sit behind the scenery), then scenery
function Biomes.drawBackground(b, s, drawClouds)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(b.sky)
    if drawClouds then drawClouds(b) end
    b.layers(s)
end

local particles = {}

function Biomes.updateParticles(dt, speed, b)
    for i = 1, 120 do
        local p = particles[i]
        if not p then
            p = { x = love.math.random() * W, y = love.math.random() * GROUND_Y, s = 0.5 + love.math.random() }
            particles[i] = p
        end
        if b.particles == "sand" then
            p.x = p.x - (speed * 0.9 + 200 * p.s) * dt
            p.y = p.y + math.sin(p.x * 0.02) * 10 * dt
        else
            p.x = p.x - (speed * 0.25 + 20 * p.s) * dt
            p.y = p.y + 50 * p.s * dt
        end
        if p.x < -10 then
            p.x = W + love.math.random() * 20
            p.y = love.math.random() * GROUND_Y
        end
        if p.y > GROUND_Y then
            p.y = -5
            p.x = love.math.random() * (W + 40)
        end
    end
end

function Biomes.drawParticles(b)
    if not b.particles then return end
    for i = 1, math.min(b.particleCount, #particles) do
        local p = particles[i]
        if b.particles == "snow" then
            love.graphics.setColor(1, 1, 1, 0.85)
            love.graphics.circle("fill", p.x, p.y, 1.5 * p.s)
        else
            love.graphics.setColor(0.95, 0.85, 0.6, 0.5)
            love.graphics.rectangle("fill", p.x, p.y, 8 * p.s, 1.5)
        end
    end
end

return Biomes
