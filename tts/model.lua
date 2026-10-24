-- =============================================
-- TC MINIATURES - MODEL SCRIPT
-- =============================================
-- The spawner puts this into every model it spawns (unless "Model scripts" is off).
--
--  * Range rings: hover the model and type a number (two digits within 0.8 s). Typing the
--    same number again, or 0, clears it.
--  * Stabilisation: rotation is frozen while the model stands, so it doesn't tip over.
--  * Save / Load position: right-click menu; the spawner has Save all / Load all.
--  * Activation: once the model is taken off the spawner's platform, its faction token floats
--    above it. Click it to toggle ready / activated (greyed). The spawner's "Ready all"
--    resets every model.
--  * Dice markers: drop any die onto the model. It is replaced by a floating die of the same
--    colour and number (colour tells blood / blessing / infection). Left-click +1,
--    right-click -1; at 0 it disappears.
--  * Image tokens: drop a token tagged TCUITokenSimple / TCUITokenEquipment onto the model.
--    It shows as an icon above the model; click the icon to remove it.
--
-- Everything above the model is object XML UI: no hitboxes, nothing to keep in place, and it
-- moves with the model by itself. UI elements are flat, so the die is built from six faces
-- placed and rotated in 3D, and the token from stacked layers, to look solid from any angle.
--
-- Ideas and faction icons from the legacy UI extender; stabilisation from Pyromaniacal's
-- Stabilized Bases (MIT).

local MODEL_TAG     = "TCM_Model"
local PLATFORM_NAME = "TC spawn platform"
local TOKEN_TAGS    = {"TCUITokenSimple", "TCUITokenEquipment"}

-- Sizes in UI units; the panel is scaled so that 100 UI units = 1 inch on any model.
local GAP          = 40     -- between the top of the model and the markers
local TOKEN_SIZE   = 80     -- activation token
local TOKEN_LAYERS = 6      -- stacked layers that form the token's edge
local TOKEN_STEP   = 2      -- depth between two layers
local DIE_SIZE     = 50     -- edge length of a die
local DIE_SPACING  = 60     -- distance between dice
local ICON_SIZE    = 55     -- image tokens
local MAX_DIE      = 6
local RANGE_STEPS  = 64     -- points per range ring

-- Faction activation icons (from the legacy UI extender). Factions without one use "default".
local ICONS = {
    ["default"]                           = "https://steamusercontent-a.akamaihd.net/ugc/17565077082788158933/75472FA5DF4D9A5A79DFCACCF02E6D044B0AB70F/",
    ["new-antioch"]                       = "https://steamusercontent-a.akamaihd.net/ugc/12140870569665962018/647EDFF35D1397EC9577768D1913B378FD7F36CB/",
    ["trench-pilgrims"]                   = "https://steamusercontent-a.akamaihd.net/ugc/10865693481180792483/AE8CC3A0A475582AAA8BB10EC12569BAC5AF6C1A/",
    ["iron-sultanate"]                    = "https://steamusercontent-a.akamaihd.net/ugc/11011531862432102694/E93E2E25F8A724A188A450B906DFAA25E146F085/",
    ["heretic-legion"]                    = "https://steamusercontent-a.akamaihd.net/ugc/11780656566766941905/005DCBF2BD729C494E5EC0DA58CF0398ABA447A8/",
    ["cult-of-the-black-grail"]           = "https://steamusercontent-a.akamaihd.net/ugc/15933842057862161695/5D24970A3042BDF9747BFC7DC74039B64C17BD99/",
    ["court-of-the-seven-headed-serpent"] = "https://steamusercontent-a.akamaihd.net/ugc/12527179569780597784/62EFCEC8605897141AC23B9F8E49A464589B2001/",
}

-- f is set by the spawner (faction id). taken = has left the spawner's platform (shows the
-- activation token). dice = {value=, color="RRGGBB"} per die marker.
state = {f = nil, savePos = nil, tokens = {}, dice = {}, activated = false, taken = false}

local typedBuffer, activeRange = "", 0

local PLAYER_COLORS = {
    White  = {1, 1, 1},       Brown = {0.44, 0.23, 0.05}, Red    = {0.85, 0.1, 0.1},
    Orange = {0.96, 0.39, 0.11}, Yellow = {0.9, 0.9, 0.17}, Green = {0.11, 0.53, 0.11},
    Teal   = {0.12, 0.53, 0.53}, Blue = {0.11, 0.25, 0.76},  Purple = {0.52, 0.1, 0.72},
    Pink   = {0.96, 0.44, 0.81}, Grey = {0.5, 0.5, 0.5},     Black  = {0.1, 0.1, 0.1},
}

local function saveState() self.script_state = JSON.encode(state) end

-- ============ STABILISATION ============
function stabilize()
    local rb = self.getComponent("Rigidbody")
    if rb then rb.set("freezeRotation", true) end
end

function destabilize()
    local rb = self.getComponent("Rigidbody")
    if rb then rb.set("freezeRotation", false) end
end

-- ============ GEOMETRY ============
local function modelTop()
    local b = self.getBounds()
    -- Bounds may not include the attached sculpt (the tagged object is often just the base).
    local h = math.max(b.size.y, 1.8)
    return b.center.y - b.size.y / 2 + h
end

local function onPlatform()
    local p = self.getPosition()
    local hits = Physics.cast({origin = {p.x, p.y + 0.5, p.z}, direction = {0, -1, 0}, type = 1, max_distance = 3})
    for _, hit in ipairs(hits) do
        if hit.hit_object ~= self and hit.hit_object.getName() == PLATFORM_NAME then return true end
    end
    return false
end

-- True if pos is over this model's base and this is the closest scripted model, so a die
-- dropped between two models only goes to one of them.
local function isOntoMe(pos)
    local b, p = self.getBounds(), self.getPosition()
    local radius = math.max(b.size.x, b.size.z) / 2 + 0.4
    local dx, dz = pos.x - p.x, pos.z - p.z
    if dx * dx + dz * dz > radius * radius or pos.y < b.center.y - b.size.y / 2 - 0.2 then return false end
    local best, bestD = nil, math.huge
    for _, o in ipairs(getAllObjects()) do
        if o.hasTag(MODEL_TAG) then
            local op = o.getPosition()
            local d = (op.x - pos.x) ^ 2 + (op.z - pos.z) ^ 2
            if d < bestD then best, bestD = o, d end
        end
    end
    return best == self
end

-- ============ PANEL ============
-- Object UI: z is height in UI units (negative = up), 100 UI units per local unit. Children
-- are placed with position="x y z" and rotation="x y z" relative to the root panel.
local function el(tag, x, y, z, rx, ry, rz, size, attrs, inner)
    return '<' .. tag .. ' position="' .. x .. ' ' .. y .. ' ' .. z .. '" rotation="' .. rx .. ' ' .. ry .. ' ' .. rz
        .. '" width="' .. size .. '" height="' .. size .. '" ' .. (attrs or '') .. '>' .. (inner or '') .. '</' .. tag .. '>'
end

-- A die as a cube of six faces, each showing the number. UI faces are only drawn from the
-- front, so every face has a back-to-back twin (rotated 180 around x) to be seen from inside
-- or behind as well. All faces are buttons: left-click +1, right-click -1.
local function dieXml(i, d, x)
    local h, s = DIE_SIZE / 2, DIE_SIZE
    local z = -h   -- cube centre: its bottom sits on the marker line
    local r, g, b = tonumber(string.sub(d.color, 1, 2), 16), tonumber(string.sub(d.color, 3, 4), 16), tonumber(string.sub(d.color, 5, 6), 16)
    local textColor = (r * 0.3 + g * 0.59 + b * 0.11) > 140 and "#000000" or "#FFFFFF"
    local face = '<Button id="die:' .. i .. '" onClick="ui_die" colors="#' .. d.color .. '|#' .. d.color .. '|#' .. d.color .. '|#' .. d.color
        .. '"><Text fontSize="34" fontStyle="Bold" color="' .. textColor .. '">' .. d.value .. '</Text></Button>'
    local faces = {
        {x, 0, z - h, 0, 0, 0},    {x, 0, z + h, 0, 0, 0},     -- top, bottom
        {x, h, z, 90, 0, 0},       {x, -h, z, 90, 0, 0},       -- front, back
        {x + h, 0, z, 0, 90, 0},   {x - h, 0, z, 0, 90, 0},    -- sides
    }
    local out = {}
    for _, f in ipairs(faces) do
        out[#out + 1] = el("Panel", f[1], f[2], f[3], f[4], f[5], f[6], s, "", face)
        out[#out + 1] = el("Panel", f[1], f[2], f[3], f[4] + 180, f[5], f[6], s, "", face)
    end
    return table.concat(out)
end

-- The activation token: the faction icon on top of TOKEN_LAYERS darker copies stacked below
-- it, which form a solid-looking edge from any angle.
local function tokenXml()
    local tint = state.activated and "#666666" or "#FFFFFF"
    local out = {}
    for k = TOKEN_LAYERS, 1, -1 do
        local shade = k == TOKEN_LAYERS and "#000000" or "#2A2A2A"
        out[#out + 1] = el("Image", 0, 0, k * TOKEN_STEP, 0, 0, 0, TOKEN_SIZE, 'image="act" preserveAspect="true" color="' .. shade .. '"')
    end
    out[#out + 1] = el("Button", 0, 0, 0, 0, 0, 0, TOKEN_SIZE, 'onClick="ui_toggleActivation" colors="#FFFFFF00|#FFFFFF00|#FFFFFF00|#FFFFFF00"',
        '<Image image="act" preserveAspect="true" color="' .. tint .. '"/>')
    return table.concat(out)
end

-- Layout above the model: activation token in the middle, dice to one side, image tokens to
-- the other. The root panel undoes the model's scale, so sizes are the same on every model.
local function renderPanel()
    local assets, parts = {}, {}
    local icon = ICONS[state.f] or ICONS.default
    if state.taken and icon then   -- setCustomAssets fails on a nil URL
        assets[#assets + 1] = {name = "act", url = icon}
        parts[#parts + 1] = tokenXml()
    end
    for i, d in ipairs(state.dice) do
        parts[#parts + 1] = dieXml(i, d, TOKEN_SIZE / 2 + 20 + (i - 0.5) * DIE_SPACING)
    end
    for i, t in ipairs(state.tokens) do
        if t.url and t.url ~= "" then
            assets[#assets + 1] = {name = "tok" .. i, url = t.url}
            parts[#parts + 1] = el("Button", -(TOKEN_SIZE / 2 + 20 + (i - 0.5) * (ICON_SIZE + 8)), 0, 0, 0, 0, 0, ICON_SIZE,
                'id="tok:' .. i .. '" onClick="ui_removeToken" colors="#FFFFFF00|#FFFFFF33|#FFFFFF55|#FFFFFF00"',
                '<Image image="tok' .. i .. '" preserveAspect="true"/>')
        end
    end
    if #parts == 0 then
        self.UI.setXml("")
        return
    end
    -- The root's own position is in the model's scaled local space (100 UI units per local
    -- unit), so the world height (model top + GAP) is divided by the model's y scale.
    local s, p = self.getScale(), self.getPosition()
    local height = ((modelTop() - p.y) * 100 + GAP) / s.y
    self.UI.setCustomAssets(assets)
    self.UI.setXml('<Panel position="0 0 ' .. -height .. '" rotation="0 0 180" width="10" height="10" scale="'
        .. 1 / s.x .. ' ' .. 1 / s.z .. ' ' .. 1 / s.y .. '">' .. table.concat(parts) .. '</Panel>')
end

function ui_toggleActivation()
    state.activated = not state.activated
    renderPanel()
    saveState()
end

-- Called by the spawner's "Ready all".
function readyActivation()
    if not state.activated then return end
    state.activated = false
    renderPanel()
    saveState()
end

-- Dice faces have id "die:<index>". XML UI passes the mouse button as value: "-1" left, "-2" right.
function ui_die(player, value, id)
    local i = tonumber(string.sub(id, 5))
    local d = i and state.dice[i]
    if not d then return end
    if value == "-2" then d.value = d.value - 1 else d.value = math.min(MAX_DIE, d.value + 1) end
    if d.value <= 0 then table.remove(state.dice, i) end
    renderPanel()
    saveState()
end

function ui_removeToken(player, value, id)
    local i = tonumber(string.sub(id, 5))   -- strip "tok:"
    if i and state.tokens[i] then table.remove(state.tokens, i) end
    renderPanel()
    saveState()
end

local function hasTokenTag(obj)
    for _, t in ipairs(TOKEN_TAGS) do
        if obj.hasTag(t) then return true end
    end
    return false
end

local function addToken(obj)
    local name = obj.getName() ~= "" and obj.getName() or obj.getDescription()
    local custom = obj.getCustomObject() or {}
    state.tokens[#state.tokens + 1] = {name = name, url = custom.image}
    obj.destruct()
    renderPanel()
    saveState()
end

-- A dropped die becomes a die marker with its colour and the number it shows.
local function addDie(obj)
    local c = obj.getColorTint()
    local value = tonumber(obj.getValue()) or 1
    state.dice[#state.dice + 1] = {
        value = math.max(1, math.min(MAX_DIE, value)),
        color = string.format("%02X%02X%02X", math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255)),
    }
    obj.destruct()
    renderPanel()
    saveState()
end

-- ============ RANGE RINGS ============
local function clearRange()
    activeRange, typedBuffer = 0, ""
    self.setVectorLines({})
end

-- Ring at `inches` from the edge of the base (round, oval or square bases).
local function drawRange(inches, color)
    local scale, size = self.getScale(), self.getBounds().size
    local sx, sz = size.x, size.z
    if sx == 0 or sz == 0 then sx, sz = 1.25 * scale.x, 1.25 * scale.z end
    local rx = (sx / 2 + inches) / scale.x
    local rz = (sz / 2 + inches) / scale.z
    local points = {}
    for i = 0, RANGE_STEPS do
        local a = i * 2 * math.pi / RANGE_STEPS
        points[#points + 1] = {math.cos(a) * rx, 0.1, math.sin(a) * rz}
    end
    self.setVectorLines({{points = points, color = color, thickness = 0.06, loop = true}})
end

function commitTypedNumber(params)
    local n = tonumber(typedBuffer)
    typedBuffer = ""
    if not n then return end
    if n == 0 or n == activeRange then
        clearRange()
        return
    end
    activeRange = n
    drawRange(n, PLAYER_COLORS[params.color] or {0, 1, 0})
end

-- Number keys over the model: collect up to two digits, then draw after a short pause.
function onNumberTyped(player_color, number)
    Timer.destroy("tcm_range_" .. self.getGUID())
    typedBuffer = string.sub(typedBuffer .. tostring(number), -2)
    Timer.create({
        identifier = "tcm_range_" .. self.getGUID(),
        function_name = "commitTypedNumber",
        function_owner = self,
        parameters = {color = player_color},
        delay = 0.8,
    })
    return true   -- don't let TTS handle the number itself
end

-- ============ SAVE / LOAD POSITION ============
function savePosition()
    state.savePos = {position = self.getPosition(), rotation = self.getRotation()}
    saveState()
end

function loadPosition()
    if not state.savePos then return end
    self.setPositionSmooth(state.savePos.position)
    self.setRotationSmooth(state.savePos.rotation)
end

-- ============ EVENTS ============
function onPickUp() destabilize() end

-- Global event, delivered to every object script: handles the model itself being put down
-- and dice / image tokens dropped onto it.
function onObjectDrop(player_color, obj)
    if obj == nil then return end
    if obj == self then
        Wait.frames(stabilize, 10)
        Wait.time(function()
            if self == nil or state.taken or onPlatform() then return end
            state.taken = true   -- off the spawner's platform: show the activation token
            renderPanel()
            saveState()
        end, 0.5)
        return
    end
    local token, die = hasTokenTag(obj), obj.type == "Dice"
    if not (token or die) or not isOntoMe(obj.getPosition()) then return end
    if token then addToken(obj) else addDie(obj) end
end

function onLoad(saved_data)
    if saved_data and saved_data ~= "" then
        local ok, data = pcall(JSON.decode, saved_data)
        if ok and type(data) == "table" then
            for k, v in pairs(data) do state[k] = v end
        end
    end
    state.tokens, state.dice = state.tokens or {}, state.dice or {}
    self.addTag(MODEL_TAG)
    self.max_typed_number = 1   -- every key press reaches onNumberTyped; two digits are buffered there

    self.addContextMenuItem("Save position", savePosition)
    self.addContextMenuItem("Load position", loadPosition)
    self.addContextMenuItem("Clear markers", function()
        state.tokens, state.dice = {}, {}
        renderPanel()
        saveState()
    end)

    -- The model may still be loading (bounds are needed for the panel height).
    Wait.frames(function()
        if self == nil then return end
        stabilize()
        renderPanel()
    end, 30)
end
