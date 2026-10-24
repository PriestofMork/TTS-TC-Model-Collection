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
--    above it (object UI). Click it to toggle ready / activated (greyed). The spawner's
--    "Ready all" resets every model.
--  * Dice: drop any die onto the model. The real die stays, locked, floating beside the
--    activation token, and moves with the model. Hover it and press 1-6 to turn it to that
--    face; press 0 to take it off (it lands beside the model as a normal die).
--  * Swapping (warband members only): drop a catalog model of the same unit onto a warband
--    model; the dropped model takes over its name, rules, activation, dice and place.
--  * Image tokens: drop a token tagged TCUITokenSimple / TCUITokenEquipment onto the model.
--    It shows as an icon above the model; click the icon to remove it.
--
-- Why dice are locked: locked objects ignore physics, so they can't drift, fall or be pushed.
-- Earlier attempts with gravity switched off, attachments or UI dice all failed (see CLAUDE.md).
--
-- Ideas and faction icons from the legacy UI extender; stabilisation from Pyromaniacal's
-- Stabilized Bases (MIT).

local MODEL_TAG     = "TCM_Model"
local PLATFORM_NAME = "TC spawn platform"
local TOKEN_TAGS    = {"TCUITokenSimple", "TCUITokenEquipment"}

-- Panel sizes in UI units; the panel is scaled so that 100 UI units = 1 inch on any model.
local GAP          = 40     -- between the top of the model and the markers
local TOKEN_SIZE   = 80     -- activation token
local TOKEN_LAYERS = 6      -- stacked layers that form the token's edge
local TOKEN_STEP   = 2      -- depth between two layers
local ICON_SIZE    = 55     -- image tokens

-- Dice, in inches.
local DICE_OFFSET  = 0.85   -- first die's centre, to the side of the activation token
local DICE_SPACING = 0.9    -- distance between dice in the row
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

-- f is set by the spawner (faction id). taken = has left the spawner's platform (shows the
-- activation token). dice = GUIDs of the linked dice, in row order.
-- u is the unit id and member = true for warband members (imported, or put on a warband slot);
-- both are set by the spawner or a slot.
state = {f = nil, u = nil, member = false, savePos = nil, tokens = {}, dice = {}, activated = false, taken = false}

local typedBuffer, activeRange = "", 0
local following, followFrames = false, 0

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

-- World position GAP above the model, `side` inches to its side, turned with the model.
local function besideTop(side, extraHeight)
    local offset = Vector(side, 0, 0):rotateOver("y", self.getRotation().y)
    local p = self.getPosition()
    return Vector(p.x + offset.x, modelTop() + GAP / 100 + (extraHeight or 0), p.z + offset.z)
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
local function isOntoMe(pos, ignore)
    local b, p = self.getBounds(), self.getPosition()
    local radius = math.max(b.size.x, b.size.z) / 2 + 0.4
    local dx, dz = pos.x - p.x, pos.z - p.z
    if dx * dx + dz * dz > radius * radius or pos.y < b.center.y - b.size.y / 2 - 0.2 then return false end
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

-- ============ PANEL (activation token + image tokens) ============
-- Object UI: z is height in UI units (negative = up), 100 UI units per local unit. Children
-- are placed with position="x y z" relative to the root panel.
local function el(tag, x, y, z, size, attrs, inner)
    return '<' .. tag .. ' position="' .. x .. ' ' .. y .. ' ' .. z .. '" width="' .. size .. '" height="' .. size .. '" '
        .. (attrs or '') .. '>' .. (inner or '') .. '</' .. tag .. '>'
end

-- The faction icon on top of TOKEN_LAYERS darker copies stacked below it: a solid-looking
-- edge from any angle. (Object UI isn't depth-sorted, so only parallel layers look right.)
local function tokenXml()
    local tint = state.activated and "#666666" or "#FFFFFF"
    local out = {}
    for k = TOKEN_LAYERS, 1, -1 do
        local shade = k == TOKEN_LAYERS and "#000000" or "#2A2A2A"
        out[#out + 1] = el("Image", 0, 0, k * TOKEN_STEP, TOKEN_SIZE, 'image="act" preserveAspect="true" color="' .. shade .. '"')
    end
    out[#out + 1] = el("Button", 0, 0, 0, TOKEN_SIZE, 'onClick="ui_toggleActivation" colors="#FFFFFF00|#FFFFFF00|#FFFFFF00|#FFFFFF00"',
        '<Image image="act" preserveAspect="true" color="' .. tint .. '"/>')
    return table.concat(out)
end

-- Activation token in the middle, image tokens to the side away from the dice. The root panel
-- undoes the model's scale, so sizes are the same on every model. Buttons use indices as ids,
-- so token names with special characters can't break the XML; no tooltips (TTS draws
-- object-UI tooltips on the ground and can leave them stuck).
local function renderPanel()
    local assets, parts = {}, {}
    local icon = ICONS[state.f] or ICONS.default
    if state.taken and icon then   -- setCustomAssets fails on a nil URL
        assets[#assets + 1] = {name = "act", url = icon}
        parts[#parts + 1] = tokenXml()
    end
    for i, t in ipairs(state.tokens) do
        if t.url and t.url ~= "" then
            assets[#assets + 1] = {name = "tok" .. i, url = t.url}
            parts[#parts + 1] = el("Button", (TOKEN_SIZE / 2 + 20 + (i - 0.5) * (ICON_SIZE + 8)), 0, 0, ICON_SIZE,
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

-- ============ DICE ============
local function findDie(guid)
    for i, g in ipairs(state.dice) do
        if g == guid then return i end
    end
    return nil
end

-- Die i in a row beside the activation token, its bottom at marker height. The panel is
-- rotated 180 degrees, so its image tokens (panel +x) end up on the model's -x side; the dice
-- go to +x.
local function diePosition(i, die)
    return besideTop(DICE_OFFSET + (i - 1) * DICE_SPACING, die.getBoundsNormalized().size.y / 2)
end

-- Puts every linked die in its place (instantly: they're locked, so no physics is involved)
-- and forgets dice that no longer exist.
function placeDice()
    local live = {}
    for _, g in ipairs(state.dice) do
        local o = getObjectFromGUID(g)
        if o then
            live[#live + 1] = g
            o.setPosition(diePosition(#live, o))
        end
    end
    state.dice = live
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
        Wait.frames(followStep, 1)
    else
        following = false
        saveState()
    end
end

local function startFollowing()
    followFrames = FOLLOW_MIN
    if following or #state.dice == 0 then return end
    following = true
    Wait.frames(followStep, 1)
end

-- Script put on linked dice. Number keys over a die go to the die's own script first, and
-- returning true there stops TTS's own handling (catching them in the model's
-- onObjectNumberTyped did not: TTS still lifted and dropped the die). The die's memo holds its
-- model's GUID; without one (taken off again) the die behaves normally.
local DIE_SCRIPT = [[
-- TC Miniatures die marker: 1-6 turn this die to that face, 0 hands it back to its model.
function onNumberTyped(player_color, number)
    local model = self.memo ~= "" and getObjectFromGUID(self.memo) or nil
    if model == nil then return end
    if number == 0 then
        model.call("releaseDie", {guid = self.getGUID()})
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
    placeDice()
    saveState()
end

-- Dice without a script, or with an older version of ours, get DIE_SCRIPT; a new script only
-- runs after a reload, which replaces the object. Dice with someone else's script are linked
-- without it (number keys then behave like TTS's default).
local function linkDie(die)
    die.memo = self.getGUID()
    local script = die.getLuaScript()
    local ours = string.find(script, "TC Miniatures die marker", 1, true) ~= nil
    if script == DIE_SCRIPT or (script ~= "" and not ours) then
        addDie(die)
        return
    end
    die.setLuaScript(DIE_SCRIPT)
    local fresh = die.reload()
    Wait.condition(function()
        if fresh ~= nil and self ~= nil then addDie(fresh) end
    end, function() return fresh == nil or not fresh.spawning end, 5)
end

-- The die becomes a normal die again, beside the model on the table.
local function unlinkDie(die, putDown)
    local i = findDie(die.getGUID())
    if not i then return end
    table.remove(state.dice, i)
    die.memo = ""   -- its script then leaves number keys to TTS again
    die.setLock(false)
    if putDown then
        local offset = Vector(-1.5, 0, 0):rotateOver("y", self.getRotation().y)
        local p = self.getPosition()
        die.setPositionSmooth({p.x + offset.x, p.y + 1, p.z + offset.z}, false, true)
    end
    placeDice()
    saveState()
end

-- Called by a linked die's script when 0 is pressed over it.
function releaseDie(params)
    local die = getObjectFromGUID(params.guid)
    if die then unlinkDie(die, true) end
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
    startFollowing()
end

-- ============ EVENTS ============
function onPickUp()
    destabilize()
    startFollowing()
end

-- A warband slot made this model a warband member (it already set name and description).
function becomeMember(params)
    state.member = true
    state.f = params.f or state.f
    state.u = params.u or state.u
    renderPanel()
    saveState()
end

-- Swap: this model replaces a warband member. It takes over the member's name, rules,
-- activation, tokens and dice, and its place on the table.
function adoptMember(params)
    local p = params.state
    state.f, state.u, state.member = p.f, p.u, true
    state.activated, state.taken, state.tokens = p.activated, true, p.tokens or {}
    state.dice = p.dice or {}
    self.setName(params.name)
    self.setDescription(params.desc)
    self.setPositionSmooth(params.pos, false, true)
    self.setRotationSmooth(params.rot, false, true)
    for _, g in ipairs(state.dice) do
        local o = getObjectFromGUID(g)
        if o then o.memo = self.getGUID() end   -- the die's script finds its model by this
    end
    renderPanel()
    saveState()
    startFollowing()   -- carries the dice to the new place
end

-- A catalog model of the same unit dropped onto this warband member replaces it. Only a
-- model that isn't a member itself can replace one, so two members bumping into each other
-- never swap.
local function trySwap(obj)
    if not state.member or not state.u or not obj.hasTag(MODEL_TAG) then return false end
    local other = obj.getTable("state")
    if type(other) ~= "table" or other.member or other.u ~= state.u then return false end
    if not isOntoMe(obj.getPosition(), obj) then return false end
    obj.call("adoptMember", {
        name = self.getName(), desc = self.getDescription(),
        pos = self.getPosition(), rot = self.getRotation(),
        state = {f = state.f, u = state.u, activated = state.activated, tokens = state.tokens, dice = state.dice},
    })
    state.dice = {}   -- handed over: onDestroy must not unlock them
    saveState()
    self.destruct()
    return true
end

-- Global event, delivered to every object script: handles the model itself being put down,
-- dice / image tokens dropped onto it, a replacement model dropped onto it, and its dice
-- being dragged off (after pressing L).
function onObjectDrop(player_color, obj)
    if obj == nil then return end
    if obj == self then
        Wait.frames(stabilize, 10)
        startFollowing()   -- keeps the dice with the model while it falls
        Wait.time(function()
            if self == nil or state.taken or onPlatform() then return end
            state.taken = true   -- off the spawner's platform: show the activation token
            renderPanel()
            saveState()
        end, 0.5)
        return
    end
    if trySwap(obj) then return end
    local mine = findDie(obj.getGUID())
    local token, die = hasTokenTag(obj), obj.type == "Dice"
    if not (mine or token or die) then return end
    local onto = isOntoMe(obj.getPosition())
    if token then
        if onto then addToken(obj) end
    elseif onto then
        linkDie(obj)
    elseif mine then
        unlinkDie(obj, false)
    end
end

-- If the model is deleted, its dice become normal dice instead of hanging in the air.
function onDestroy()
    for _, g in ipairs(state.dice) do
        local o = getObjectFromGUID(g)
        if o then o.setLock(false) end
    end
end

function onLoad(saved_data)
    if saved_data and saved_data ~= "" then
        local ok, data = pcall(JSON.decode, saved_data)
        if ok and type(data) == "table" then
            for k, v in pairs(data) do state[k] = v end
        end
    end
    state.tokens = state.tokens or {}
    -- Saves from earlier script versions stored dice as tables; only GUID strings are valid now.
    local dice = {}
    for _, g in ipairs(state.dice or {}) do
        if type(g) == "string" then dice[#dice + 1] = g end
    end
    state.dice = dice
    self.addTag(MODEL_TAG)
    self.max_typed_number = 1   -- every key press reaches onNumberTyped; two digits are buffered there

    self.addContextMenuItem("Save position", savePosition)
    self.addContextMenuItem("Load position", loadPosition)
    self.addContextMenuItem("Clear tokens", function()
        state.tokens = {}
        renderPanel()
        saveState()
    end)

    -- The model and its dice may still be loading (bounds are needed for heights).
    Wait.frames(function()
        if self == nil then return end
        stabilize()
        renderPanel()
        for _, g in ipairs(state.dice) do
            local o = getObjectFromGUID(g)
            if o then
                o.memo = self.getGUID()   -- the die's script finds its model by this
                o.setLock(true)
            end
        end
        placeDice()
    end, 30)
end
