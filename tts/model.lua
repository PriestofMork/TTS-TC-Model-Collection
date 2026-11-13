-- =============================================
-- TC MINIATURES - MODEL SCRIPT
-- =============================================
-- The spawner puts this into every model it spawns (unless "Model scripts" is off), and into
-- any model dropped into its Extend UI area.
--
--  * Range rings: hover the model and type a number (two digits within 0.8 s). Typing the
--    same number again, or 0, clears it.
--  * Stabilisation: rotation is frozen while the model stands, so it doesn't tip over.
--  * Right-click menu: Ready all (start of a round: every model ready, positions saved),
--    Save / Load position, Set base size (25 to 60 mm), Clear tokens.
--  * Activation: once the model is taken off the spawner's platform, its faction token floats
--    above it (object UI). Click it to toggle ready / activated (greyed).
--  * Dice: drop any die onto the model. The real die stays, locked, floating on a half circle
--    above the activation token, and moves with the model. Hover it and press 1-6 to turn it
--    to that face; press 0 to take it off (it lands beside the model as a normal die).
--  * Swapping (imported warbands, while still on their platform): drop a catalog model of the
--    same unit, or any model from the spawner's Extend UI area, onto a warband model; the
--    dropped model takes over its name, rules, activation, dice and place.
--  * Image tokens: drop a token tagged TCUITokenSimple / TCUITokenEquipment onto the model.
--    It shows as an icon on a half circle below the activation token; click it to remove it.
--  * Other TC table scripts: models carry the tag TCUIOperative and offer savePosition() and
--    toggleState() with `state.activated`, like the TC UI extender, so e.g. a scoreboard's
--    "Next round" works on them.
--
-- How it works: events (drops, clicks, keys, calls from other objects) only change `state`
-- and call changed(). One update a frame later draws the panel, places the dice and saves,
-- so many changes in one frame (Ready all on 30 models) cost one redraw per model. Every
-- event and timer runs through safe(), so an error is printed instead of leaving the model
-- half updated.
--
-- Why dice are locked: locked objects ignore physics, so they can't drift, fall or be pushed.
-- Earlier attempts with gravity switched off, attachments or UI dice all failed (see CLAUDE.md).
--
-- Ideas and faction icons from the legacy UI extender; stabilisation from Pyromaniacal's
-- Stabilized Bases (MIT).

local STATE_VERSION = 2

local MODEL_TAG     = "TCM_Model"
local COMPAT_TAG    = "TCUIOperative"   -- tag of TC UI extender models (other scripts look for it)
local DIE_TAG       = "TCM_Die"         -- dice linked to a model; their memo is the model's id
local PLATFORM_NAME = "TC spawn platform"
local TOKEN_TAGS    = {"TCUITokenSimple", "TCUITokenEquipment"}

-- Panel sizes in UI units; the panel is scaled so that 100 UI units = 1 inch on any model.
local GAP          = 40     -- between the top of the model and the markers
local TOKEN_SIZE   = 80     -- activation token
local TOKEN_LAYERS = 6      -- stacked layers that form the token's edge
local TOKEN_STEP   = 2      -- depth between two layers
local ICON_SIZE    = 55     -- image tokens

-- Base sizes (mm) offered in "Set base size", and the model height assumed for each (inches).
-- Bases wider than 70 mm count as big. HEADROOM is added to every height, so unusually tall
-- models stay clear of their token.
local BASE_SIZES   = {25, 32, 40, 50, 60}
local BASE_HEIGHT  = {[25] = 1.5, [32] = 1.75, [40] = 2.0, [50] = 2.5, [60] = 3.0}
local BIG_HEIGHT   = 3.6
local HEADROOM     = 1.0
local MM           = 25.4

-- Markers around the activation token: dice on a half circle above it, image tokens on one
-- below it (as the player sees the model when spawned).
local ARC_STEP     = 40     -- degrees between neighbours on a half circle
local DICE_RADIUS  = 1.25   -- inches from the token's centre to a die's centre (fits 1" dice)
local DICE_SPACING = 0.95   -- inches: dice centres at least this far apart
local TOKEN_RADIUS = 0.85   -- inches from the token's centre to an image token's centre
local FOLLOW_MIN   = 30     -- frames dice follow at least after a move starts

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

local PLAYER_COLORS = {
    White  = {1, 1, 1},       Brown = {0.44, 0.23, 0.05}, Red    = {0.85, 0.1, 0.1},
    Orange = {0.96, 0.39, 0.11}, Yellow = {0.9, 0.9, 0.17}, Green = {0.11, 0.53, 0.11},
    Teal   = {0.12, 0.53, 0.53}, Blue = {0.11, 0.25, 0.76},  Purple = {0.52, 0.1, 0.72},
    Pink   = {0.96, 0.44, 0.81}, Grey = {0.5, 0.5, 0.5},     Black  = {0.1, 0.1, 0.1},
}

-- ============ STATE ============
-- Saved in script_state. Global, so other objects can read it (obj.getTable("state")).
--   v        state version (see migrate)
--   id       random id of this model: its dice carry it (GUIDs change when TTS resolves
--            collisions on load); idGuid = the GUID it was given at, to tell copies apart
--   f, u     faction id (activation icon) and unit id (swapping), set by the spawner
--   member   warband member (imported)
--   base     base size in mm (25..60), nil = not known or bigger than 60 mm
--   geo      measured once at rest: {bottom = base bottom below the pivot, h = collider
--            height, w = footprint width (x), d = footprint depth (z)}, world inches
--   taken    has left the spawner's platform (shows the activation token)
--   dice     GUIDs of the linked dice in arc order (rebuilt from their tags on every load)
state = {v = STATE_VERSION, id = nil, idGuid = nil, f = nil, u = nil, member = false, base = nil,
         geo = nil, savePos = nil, tokens = {}, dice = {}, activated = false, taken = false}

local picking = false     -- "Set base size" is open (not saved)
local typedBuffer, activeRange = "", 0
local following, followFrames = false, 0

local function saveState() self.script_state = JSON.encode(state) end

-- Runs fn protected: an error is printed with the step's name instead of silently stopping
-- a Wait loop or leaving the model half updated.
local function safe(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then print("[TC model " .. self.getGUID() .. "] " .. name .. ": " .. tostring(err)) end
    return ok
end

local function newId()
    return "m" .. os.time() .. math.random(100000, 999999)
end

-- Upgrades a saved state from an older script version in one place.
local legacyDice = nil   -- v1 kept dice by GUID with the model's GUID in their memo
local function migrate()
    local v = state.v or 1
    if v < 2 then
        state.top, state.topRule = nil, nil   -- v1 stored the height itself
        legacyDice = state.dice
        state.dice = {}
    end
    state.tokens = type(state.tokens) == "table" and state.tokens or {}
    state.dice = type(state.dice) == "table" and state.dice or {}
    state.v = STATE_VERSION
end

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
-- The tagged object is usually just the base with the sculpt attached. Attached parts have no
-- collider, so getBounds only sees the base, and getVisualBounds was wrong both ways (tested:
-- ~1.4" Lieutenants measured 0.25", asset bundles about their scale). So the base is measured
-- (reliable) and the height comes from the base size. Measuring happens once, while the model
-- rests: measuring on every redraw caught models lifted or tilted and dropped their token.
local function measure()
    local b, p = self.getBounds(), self.getPosition()
    return {bottom = b.center.y - b.size.y / 2 - p.y, h = b.size.y, w = b.size.x, d = b.size.z}
end

-- The stored measurement, or a live one (not stored) until the model has rested once.
local function geometry()
    if state.geo then return state.geo end
    local g = measure()
    if self.resting and not self.held_by_color then
        state.geo = g
        saveState()
    end
    return g
end

-- Nearest offered base size for a footprint width (inches), nil for big bases.
local function baseFromWidth(width)
    local mm = width * MM
    if mm > 70 then return nil end
    local best, bestD = nil, math.huge
    for _, size in ipairs(BASE_SIZES) do
        local d = math.abs(size - mm)
        if d < bestD then best, bestD = size, d end
    end
    return best
end

-- The base size in use: set by the player, else guessed from the measured footprint.
local function baseSize()
    return state.base or baseFromWidth(math.max(geometry().w, geometry().d))
end

-- Height of the marker panel above the model's pivot (world inches): the base size's height
-- or the collider's, whichever is taller (the collider is the sculpt itself on some models).
local function topOffset()
    local g = geometry()
    local base = baseSize()
    local h = math.max(g.h, base and BASE_HEIGHT[base] or BIG_HEIGHT)
    return g.bottom + h + HEADROOM
end

-- Point k of n on a half circle around the activation token, in panel inches (x to the side,
-- y = side * up the panel: 1 = "above" the token, away from the player as spawned, -1 =
-- below). Neighbours are ARC_STEP degrees apart, centred; when n wouldn't fit on half a
-- circle, they spread over 180 degrees and the radius grows so they don't overlap.
local function arcPoint(k, n, radius, spacing, side)
    local step = math.rad(ARC_STEP)
    if n > 1 and (n - 1) * step > math.pi then
        step = math.pi / (n - 1)
        radius = math.max(radius, spacing / (2 * math.sin(step / 2)))
    end
    local a = math.pi / 2 + ((n + 1) / 2 - k) * step
    return radius * math.cos(a), side * radius * math.sin(a)
end

-- World position of panel point (x, y) inches, at the panel's height plus extraHeight, turned
-- with the model. The panel is rotated "0 0 180", so panel x / y are the model's local -x / -z.
local function panelToWorld(x, y, extraHeight)
    local s = self.getScale()
    local pos = self.positionToWorld(Vector(-x / s.x, 0, -y / s.z))
    pos.y = self.getPosition().y + topOffset() + GAP / 100 + (extraHeight or 0)
    return pos
end

local function onPlatform()
    local p = self.getPosition()
    local hits = Physics.cast({origin = {p.x, p.y + 0.5, p.z}, direction = {0, -1, 0}, type = 1, max_distance = 3})
    for _, hit in ipairs(hits) do
        if hit.hit_object ~= self and hit.hit_object.getName() == PLATFORM_NAME then return true end
    end
    return false
end

-- Cheap test: is pos over this model's base (and not below it)?
local function overMe(pos)
    local g, p = geometry(), self.getPosition()
    local radius = math.max(g.w, g.d) / 2 + 0.4
    local dx, dz = pos.x - p.x, pos.z - p.z
    return dx * dx + dz * dz <= radius * radius and pos.y >= p.y + g.bottom - 0.2
end

-- Expensive test, only for objects already over this model: is it the closest scripted model,
-- so a die dropped between two models only goes to one of them?
local function closestTo(pos, ignore)
    local best, bestD = nil, math.huge
    for _, o in ipairs(getAllObjects()) do
        if o.hasTag(MODEL_TAG) and o ~= ignore then
            local op = o.getPosition()
            local d = (op.x - pos.x) ^ 2 + (op.z - pos.z) ^ 2
            if d < bestD then best, bestD = o, d end
        end
    end
    return best == self
end

-- ============ PANEL (activation token, image tokens, base size picker) ============
-- Object UI: z is height in UI units (negative = up), 100 UI units per local unit. Children
-- are placed with position="x y z" relative to the root panel.
local function el(tag, x, y, z, size, attrs, inner)
    return '<' .. tag .. ' position="' .. x .. ' ' .. y .. ' ' .. z .. '" width="' .. size .. '" height="' .. size .. '" '
        .. (attrs or '') .. '>' .. (inner or '') .. '</' .. tag .. '>'
end

-- UI image names. TTS shares custom asset names between objects: with one name ("act") for
-- every model, models of different factions redrawn together (Ready all) showed each other's
-- icons. So a name always stands for one picture: per faction for the activation icon, per
-- model and slot for image tokens.
local function actAsset() return "act_" .. (ICONS[state.f] and state.f or "default") end
local function tokAsset(i) return "tok_" .. self.getGUID() .. "_" .. i end

-- The faction icon on top of TOKEN_LAYERS darker copies stacked below it: a solid-looking
-- edge from any angle. (Object UI isn't depth-sorted, so only parallel layers look right.)
local function tokenXml()
    local tint = state.activated and "#666666" or "#FFFFFF"
    local img = 'image="' .. actAsset() .. '" preserveAspect="true" color="'
    local out = {}
    for k = TOKEN_LAYERS, 1, -1 do
        local shade = k == TOKEN_LAYERS and "#000000" or "#2A2A2A"
        out[#out + 1] = el("Image", 0, 0, k * TOKEN_STEP, TOKEN_SIZE, img .. shade .. '"')
    end
    out[#out + 1] = el("Button", 0, 0, 0, TOKEN_SIZE, 'onClick="ui_toggleActivation" colors="#FFFFFF00|#FFFFFF00|#FFFFFF00|#FFFFFF00"',
        '<Image ' .. img .. tint .. '"/>')
    return table.concat(out)
end

-- "Set base size": a row of buttons where the token is, the current size highlighted, turned
-- to face the player who opened it (pickerTurn, see openPicker).
local pickerTurn = 0
local function pickerXml()
    local out, current = {'<Panel width="10" height="10" rotation="0 0 ' .. pickerTurn .. '">'}, baseSize()
    for i, size in ipairs(BASE_SIZES) do
        local x = (i - (#BASE_SIZES + 1) / 2) * 72
        local colors = size == current and "#7F2119|#9A2A20|#5E1812|#7F2119" or "#2A2624|#3A3532|#1E1B1A|#2A2624"
        out[#out + 1] = '<Button id="base:' .. size .. '" position="' .. x .. ' 0 -4" width="66" height="44" fontSize="22" '
            .. 'textColor="#EEE6D8" onClick="ui_pickBase" colors="' .. colors .. '">' .. size .. '</Button>'
    end
    out[#out + 1] = '</Panel>'
    return table.concat(out)
end

-- Activation token in the middle, image tokens on a half circle below it (dice are on one
-- above it, see diePosition). The root panel undoes the model's scale, so sizes are the same
-- on every model. Buttons use indices as ids, so token names with special characters can't
-- break the XML; no tooltips (TTS draws object-UI tooltips on the ground and can leave them
-- stuck).
local function renderPanel()
    local assets, parts = {}, {}
    local icon = ICONS[state.f] or ICONS.default
    if picking then
        parts[#parts + 1] = pickerXml()
    elseif state.taken and icon then   -- setCustomAssets fails on a nil URL
        assets[#assets + 1] = {name = actAsset(), url = icon}
        parts[#parts + 1] = tokenXml()
    end
    local shown = {}
    for i, t in ipairs(state.tokens) do
        if t.url and t.url ~= "" then shown[#shown + 1] = i end
    end
    for k, i in ipairs(shown) do
        assets[#assets + 1] = {name = tokAsset(i), url = state.tokens[i].url}
        local x, y = arcPoint(k, #shown, TOKEN_RADIUS, (ICON_SIZE + 8) / 100, -1)
        parts[#parts + 1] = el("Button", x * 100, y * 100, 0, ICON_SIZE,
            'id="tok:' .. i .. '" onClick="ui_removeToken" colors="#FFFFFF00|#FFFFFF33|#FFFFFF55|#FFFFFF00"',
            '<Image image="' .. tokAsset(i) .. '" preserveAspect="true"/>')
    end
    if #parts == 0 then
        self.UI.setXml("")
        return
    end
    -- The root's own position is in the model's scaled local space (100 UI units per local
    -- unit), so the world height (model top + GAP) is divided by the model's y scale.
    local s = self.getScale()
    local height = (topOffset() * 100 + GAP) / s.y
    if #assets > 0 then self.UI.setCustomAssets(assets) end
    self.UI.setXml('<Panel position="0 0 ' .. -height .. '" rotation="0 0 180" width="10" height="10" scale="'
        .. 1 / s.x .. ' ' .. 1 / s.z .. ' ' .. 1 / s.y .. '">' .. table.concat(parts) .. '</Panel>')
end

-- ============ DICE ============
local function findDie(guid)
    for i, g in ipairs(state.dice) do
        if g == guid then return i end
    end
    return nil
end

-- Die i on the half circle above the activation token, its bottom at marker height.
local function diePosition(i, die)
    local x, y = arcPoint(i, #state.dice, DICE_RADIUS, DICE_SPACING, 1)
    return panelToWorld(x, y, die.getBoundsNormalized().size.y / 2)
end

-- Puts every linked die in its place (instantly: they're locked, so no physics is involved)
-- and forgets dice that no longer exist.
local function placeDice()
    local live, objs = {}, {}
    for _, g in ipairs(state.dice) do
        local o = getObjectFromGUID(g)
        if o then
            live[#live + 1] = g
            objs[#objs + 1] = o
        end
    end
    state.dice = live   -- before placing: the half circle is laid out for the dice that exist
    for i, o in ipairs(objs) do o.setPosition(diePosition(i, o)) end
end

-- ============ UPDATE ============
-- changed() schedules one update for the next frame; changes in the same frame share it.
local scheduled = false
local function update()
    scheduled = false
    if self == nil then return end
    renderPanel()
    placeDice()
    saveState()
end

local function changed()
    if scheduled then return end
    scheduled = true
    Wait.frames(function() safe("update", update) end, 1)
end

-- While the model is held, falling or moved by "Load position", its dice are placed above
-- it every frame (and for at least FOLLOW_MIN frames after a move starts).
local function followStep()
    if self == nil then
        following = false
        return
    end
    followFrames = followFrames - 1
    placeDice()
    if self.held_by_color ~= nil or not self.resting or followFrames > 0 then
        Wait.frames(function() safe("follow", followStep) end, 1)
    else
        following = false
        saveState()
    end
end

local function startFollowing()
    followFrames = FOLLOW_MIN
    if following or #state.dice == 0 then return end
    following = true
    Wait.frames(function() safe("follow", followStep) end, 1)
end

-- Script put on linked dice. Number keys over a die go to the die's own script first, and
-- returning true there stops TTS's own handling (catching them in the model's
-- onObjectNumberTyped did not: TTS still lifted and dropped the die). The die's memo is its
-- model's id; without one (taken off again) the die behaves normally.
local DIE_SCRIPT = [[
-- 1-6 turn this die to that face, 0 hands it back to its model. memo = the id of the model it
-- belongs to (kept in the model's state; GUIDs can change). The marker below is code, not a
-- comment, so it survives the spawner stripping comments (tests and finding old dice use it).
TCM_DIE = "TC Miniatures die marker v2"
local model = nil
local function findModel()
    if self.memo == "" then return nil end
    if model ~= nil then
        local st = model.getTable("state")
        if type(st) == "table" and st.id == self.memo then return model end
    end
    model = nil
    for _, o in ipairs(getAllObjects()) do
        if o.hasTag("TCM_Model") then
            local st = o.getTable("state")
            if type(st) == "table" and st.id == self.memo then model = o break end
        end
    end
    return model
end

function onNumberTyped(player_color, number)
    local m = findModel()
    if m == nil then return end
    if number == 0 then
        m.call("releaseDie", {guid = self.getGUID()})
        return true
    end
    -- Not setValue: that lifts the die and lets physics drop it. A smooth turn keeps a
    -- locked die where it is.
    for _, rv in ipairs(self.getRotationValues() or {}) do
        if tostring(rv.value) == tostring(number) then self.setRotationSmooth(rv.rotation, false, false) end
    end
    return true
end
]]

local function addDie(die)
    if not findDie(die.getGUID()) then state.dice[#state.dice + 1] = die.getGUID() end
    die.setLock(true)
    changed()
end

-- A die gets this model's id in its memo, the die tag and DIE_SCRIPT, which replaces whatever
-- script it had (a new script only runs after a reload; the GUID stays). Always, no checks:
-- without ours, TTS's default number handling drops the die on 1-6. (Nov 2026: a game
-- infected with the self-spreading "Spawning object" script had it on every die, and dice
-- linked without ours fell down on every key.) Runs once per link (a drop), not on load.
local function linkDie(die)
    die.memo = state.id
    if not die.hasTag(DIE_TAG) then die.addTag(DIE_TAG) end
    die.setLuaScript(DIE_SCRIPT)
    local fresh = die.reload()
    Wait.condition(function()
        if fresh ~= nil and self ~= nil then safe("link die", addDie, fresh) end
    end, function() return fresh == nil or not fresh.spawning end, 5)
end

-- The die becomes a normal die again; with putDown, beside the model on the table.
local function unlinkDie(die, putDown)
    local i = findDie(die.getGUID())
    if i then table.remove(state.dice, i) end
    die.memo = ""   -- its script then leaves number keys to TTS again
    if die.hasTag(DIE_TAG) then die.removeTag(DIE_TAG) end
    die.setLock(false)
    if putDown then
        local offset = Vector(-1.5, 0, 0):rotateOver("y", self.getRotation().y)
        local p = self.getPosition()
        die.setPositionSmooth({p.x + offset.x, p.y + 1, p.z + offset.z}, false, true)
    end
    changed()
end

-- Called by a linked die's script when 0 is pressed over it.
function releaseDie(params)
    safe("release die", function()
        local die = getObjectFromGUID(params.guid)
        if die then unlinkDie(die, true) end
    end)
end

-- ============ TOKENS ============
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
    changed()
end

function ui_removeToken(player, value, id)
    safe("remove token", function()
        local i = tonumber(string.sub(id, 5))   -- strip "tok:"
        if i and state.tokens[i] then table.remove(state.tokens, i) end
        changed()
    end)
end

-- ============ ACTIVATION ============
local function toggle()
    state.activated = not state.activated
    changed()
end

function ui_toggleActivation() safe("activation", toggle) end

-- The TC UI extender's name for it (scoreboards call it on activated models).
function toggleState() safe("activation", toggle) end

-- Called by older spawners' "Ready all".
function readyActivation()
    if state.activated then safe("activation", toggle) end
end

-- "Ready all" in the right-click menu: start of a round. Every model with the TCUIOperative
-- tag (ours and TC UI extender ones) saves its position, and the activated ones are set to
-- ready (only those are toggled, so none ends up activated by mistake). Each call is
-- protected, so a model whose script hasn't loaded can't stop the others.
local function readyAll()
    local saved, readied = 0, 0
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag(COMPAT_TAG) then
            if pcall(function() obj.call("savePosition") end) then saved = saved + 1 end
            pcall(function()
                local st = obj.getTable("state")
                if type(st) == "table" and st.activated == true then
                    obj.call("toggleState")
                    readied = readied + 1
                end
            end)
        end
    end
    broadcastToAll("Ready all: " .. readied .. " model(s) set to ready, positions saved (" .. saved .. ").", {0.95, 0.78, 0.25})
end

-- ============ BASE SIZE ============
function ui_pickBase(player, value, id)
    safe("base size", function()
        state.base = tonumber(string.sub(id, 6))   -- strip "base:"
        picking = false
        changed()
    end)
end

-- The panel reads upright from the model's local +z side; the row turns by the angle between
-- that side and the seat of the player who clicked (their hand's yaw), so it reads upright
-- for them however the model stands.
local function openPicker(player_color)
    picking = not picking
    local hand = player_color and Player[player_color] and Player[player_color].getHandTransform()
    local seat = hand and hand.rotation.y or 0
    pickerTurn = (self.getRotation().y - seat + 180) % 360   -- sign tested: model at 0 and 90 degrees
    changed()
end

-- ============ RANGE RINGS ============
local function clearRange()
    activeRange, typedBuffer = 0, ""
    self.setVectorLines({})
end

-- Ring at `inches` from the edge of the base: round for a known base size, else following the
-- measured footprint (oval or square bases).
local function drawRange(inches, color)
    local scale, g, base = self.getScale(), geometry(), baseSize()
    local rx, rz
    if base then
        rx = base / MM / 2
        rz = rx
    else
        rx, rz = g.w / 2, g.d / 2
    end
    rx, rz = (rx + inches) / scale.x, (rz + inches) / scale.z
    local points = {}
    for i = 0, RANGE_STEPS do
        local a = i * 2 * math.pi / RANGE_STEPS
        points[#points + 1] = {math.cos(a) * rx, 0.1, math.sin(a) * rz}
    end
    self.setVectorLines({{points = points, color = color, thickness = 0.06, loop = true}})
end

function commitTypedNumber(params)
    safe("range", function()
        local n = tonumber(typedBuffer)
        typedBuffer = ""
        if not n then return end
        if n == 0 or n == activeRange then
            clearRange()
            return
        end
        activeRange = n
        drawRange(n, PLAYER_COLORS[params.color] or {0, 1, 0})
    end)
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
    startFollowing()
end

-- ============ CALLS FROM THE SPAWNER ============
-- The spawner's Extend UI area: a model that already runs this script was dropped there, so
-- only its faction (activation icon) changes.
function setFaction(params)
    state.f = params.f
    state.taken = true
    changed()
end

-- Swap: this model replaces a warband member. It takes over the member's name, rules,
-- activation, tokens and dice, and its place on the table.
function adoptMember(params)
    safe("swap", function()
        local p = params.state
        state.f, state.u, state.member = p.f, p.u, true
        -- Swaps happen on the import platform, so the activation token shows once the model
        -- is taken off (see the drop handler).
        state.activated, state.taken, state.tokens = p.activated, false, p.tokens or {}
        state.dice = p.dice or {}
        self.setName(params.name)
        self.setDescription(params.desc)
        self.setPositionSmooth(params.pos, false, true)
        self.setRotationSmooth(params.rot, false, true)
        for _, g in ipairs(state.dice) do
            local o = getObjectFromGUID(g)
            if o then o.memo = state.id end   -- the dice now belong to this model's id
        end
        changed()
        startFollowing()   -- carries the dice to the new place
    end)
end

-- A model dropped onto this warband member replaces it: a catalog model of the same unit, or
-- one without a unit (given the script in the spawner's Extend UI area: the player's own
-- models). Only while the member still stands on its import platform (setting up the
-- warband), so nothing swaps during a game. Only a model that isn't a member itself can
-- replace one, so two members bumping into each other never swap.
local function trySwap(obj)
    local other = obj.getTable("state")
    if type(other) ~= "table" or other.member then return end
    if other.u and other.u ~= state.u then return end
    if not onPlatform() then return end
    obj.call("adoptMember", {
        name = self.getName(), desc = self.getDescription(),
        pos = self.getPosition(), rot = self.getRotation(),
        state = {f = state.f, u = state.u, activated = state.activated, tokens = state.tokens, dice = state.dice},
    })
    state.dice = {}   -- handed over: onDestroy must not unlock them
    saveState()
    self.destruct()
end

-- ============ EVENTS ============
function onPickUp()
    safe("pick up", function()
        destabilize()
        startFollowing()
    end)
end

-- This model was put down: stabilise, carry the dice, and once it's off the spawner's
-- platform show the activation token.
local function droppedSelf()
    Wait.frames(function() safe("stabilize", stabilize) end, 10)
    startFollowing()   -- keeps the dice with the model while it falls
    Wait.time(function()
        safe("taken", function()
            if self == nil then return end
            if not state.geo then geometry() end   -- first rest: measure now
            if state.taken or onPlatform() then return end
            state.taken = true
            changed()
        end)
    end, 0.5)
end

-- Something else was put down. This is a global event: every model gets every drop, so the
-- cheap checks come first and only a model the object lies over does more.
local function droppedOther(obj)
    local isDie, isToken, isModel = obj.type == "Dice", hasTokenTag(obj), obj.hasTag(MODEL_TAG)
    local mine = isDie and findDie(obj.getGUID())
    if not (isDie or isToken or (isModel and state.member)) then return end
    local pos = obj.getPosition()
    if not overMe(pos) then
        if mine then unlinkDie(obj, false) end   -- dragged off after pressing L
        return
    end
    if not closestTo(pos, isModel and obj or nil) then return end
    if isModel then
        trySwap(obj)
    elseif isToken then
        addToken(obj)
    elseif not mine then
        linkDie(obj)
    end
end

function onObjectDrop(player_color, obj)
    if obj == nil then return end
    if obj == self then
        safe("drop", droppedSelf)
    else
        safe("drop", droppedOther, obj)
    end
end

-- If the model is deleted, its dice become normal dice instead of hanging in the air.
function onDestroy()
    for _, g in ipairs(state.dice) do
        local o = getObjectFromGUID(g)
        if o then
            o.setLock(false)
            o.memo = ""
            if o.hasTag(DIE_TAG) then o.removeTag(DIE_TAG) end
        end
    end
end

-- ============ LOAD ============
-- After everything has loaded: make the id unique (a copied model has its original's id),
-- check this model's dice, relink dice of older script versions, then update. The table is
-- only scanned when there is something to find, so a normal load scans nothing.
local function settle()
    if self == nil then return end
    -- A GUID other than the one the id was made under: this is a copy, or TTS changed the
    -- GUID (collision on load). Only then can another model have the same id.
    if state.idGuid ~= self.getGUID() then
        for _, o in ipairs(getAllObjects()) do
            if o ~= self and o.hasTag(MODEL_TAG) then
                local st = o.getTable("state")
                if type(st) == "table" and st.id == state.id then
                    -- The original is the one with the GUID the id was made under; if neither
                    -- has it, the larger GUID yields.
                    if o.getGUID() == state.idGuid or self.getGUID() > o.getGUID() then
                        state.id, state.dice = newId(), {}
                    end
                    break
                end
            end
        end
        state.idGuid = self.getGUID()
    end

    -- Saved dice that still exist under their GUID keep their place. Only if one is missing
    -- (TTS changed its GUID) are the dice found by their tag and this model's id.
    if #state.dice > 0 then
        local dice, seen, missing = {}, {}, false
        for _, g in ipairs(state.dice) do
            local o = getObjectFromGUID(g)
            if o and o.memo == state.id then
                dice[#dice + 1], seen[g] = g, true
            else
                missing = true
            end
        end
        if missing then
            for _, o in ipairs(getAllObjects()) do
                if o.hasTag(DIE_TAG) and o.memo == state.id and not seen[o.getGUID()] then
                    dice[#dice + 1] = o.getGUID()
                end
            end
        end
        state.dice = dice
    end
    local dice = state.dice
    for _, g in ipairs(dice) do
        local o = getObjectFromGUID(g)
        if o then o.setLock(true) end
    end
    for _, g in ipairs(legacyDice or {}) do
        local o = type(g) == "string" and getObjectFromGUID(g) or nil
        if o then linkDie(o) end
    end
    legacyDice = nil

    stabilize()
    changed()
    -- Measure the base as soon as the model rests (it may still be falling after spawning).
    if not state.geo then
        Wait.condition(function() safe("measure", function()
            if self ~= nil and not state.geo then geometry() changed() end
        end) end, function() return self == nil or (self.resting and self.held_by_color == nil) end, 20)
    end
end

function onLoad(saved_data)
    if saved_data and saved_data ~= "" then
        local ok, data = pcall(JSON.decode, saved_data)
        if ok and type(data) == "table" then
            for k, v in pairs(data) do state[k] = v end
        end
    end
    migrate()
    if not state.id then
        math.randomseed(os.time() + math.floor(self.getPosition().x * 1000))
        state.id, state.idGuid = newId(), self.getGUID()
    end
    self.addTag(MODEL_TAG)
    self.addTag(COMPAT_TAG)
    self.max_typed_number = 1   -- every key press reaches onNumberTyped; two digits are buffered there

    self.addContextMenuItem("Ready all", function() safe("ready all", readyAll) end)
    self.addContextMenuItem("Save position", function() safe("save position", savePosition) end)
    self.addContextMenuItem("Load position", function() safe("load position", loadPosition) end)
    self.addContextMenuItem("Set base size", function(player_color) safe("base size", openPicker, player_color) end)
    self.addContextMenuItem("Clear tokens", function()
        state.tokens = {}
        changed()
    end)

    -- Other objects (dice, other models) may still be loading during onLoad.
    Wait.frames(function() safe("load", settle) end, 30)
end
