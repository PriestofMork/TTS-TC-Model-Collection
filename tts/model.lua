-- =============================================
-- TC MINIATURES - MODEL SCRIPT
-- =============================================
-- The spawner puts this into every model it spawns (unless "Model scripts" is off).
--
--  * Range rings: hover the model and type a number (two digits within 0.8 s). Typing the
--    same number again, or 0, clears it.
--  * Stabilisation: rotation is frozen while the model stands, so it doesn't tip over.
--  * Save / Load position: right-click menu; the spawner has Save all / Load all.
--  * Activation: once the model is taken off the spawner's platform, its faction icon floats
--    above it. Click it to toggle ready / activated (greyed). The spawner's "Ready all"
--    resets every model.
--  * Image tokens: drop a token tagged TCUITokenSimple / TCUITokenEquipment onto the model.
--    It shows as an icon above the model; click the icon to remove it.
--  * Floating dice: any die dropped onto the model floats beside its activation icon and
--    keeps working as a die (pick up, number keys). While the model moves the dice are locked
--    and moved along every frame; once it rests they float freely again.
--    Right-click a die -> "Remove marker", or drag it off the model to unlink it.
--
-- Ideas and faction icons from the legacy UI extender; stabilisation from Pyromaniacal's
-- Stabilized Bases (MIT).

local MODEL_TAG     = "TCM_Model"
local PLATFORM_NAME = "TC spawn platform"
local TOKEN_TAGS    = {"TCUITokenSimple", "TCUITokenEquipment"}

local MARKER_GAP     = 0.8    -- space between the top of the model and the bottom of a die
local DICE_OFFSET    = 1.0    -- first die sits this far to the side, next to the activation icon
local DICE_SPACING   = 1.1    -- distance between dice in the row
local FOLLOW_MIN     = 30     -- frames dice follow at least after a move starts
local RANGE_STEPS    = 64     -- points per range ring

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
-- activation icon). links = floating dice, each with the drag values to restore on unlink.
state = {f = nil, savePos = nil, tokens = {}, links = {}, activated = false, taken = false}

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

-- Position of die number i above the model, beside the activation icon, turned with the
-- model. dieHeight is the die's own height, so its bottom sits MARKER_GAP above the model.
local function slotPosition(i, dieHeight)
    local x = DICE_OFFSET + (i - 1) * DICE_SPACING
    local offset = Vector(x, 0, 0):rotateOver("y", self.getRotation().y)
    local p = self.getPosition()
    return Vector(p.x + offset.x, modelTop() + MARKER_GAP + (dieHeight or 1) / 2, p.z + offset.z)
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
-- dropped between two models only links to one of them.
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

-- ============ PANEL (activation icon + image tokens) ============
-- One panel above the model. The activation icon is drawn over two dark, slightly offset
-- copies of itself so it reads as a thick token instead of a flat picture. Buttons use
-- indices as ids, so token names with special characters can't break the XML, and there
-- are no tooltips (TTS draws object-UI tooltips on the ground and can leave them stuck).
local function renderPanel()
    local assets, parts = {}, {}
    local icon = ICONS[state.f] or ICONS.default
    if state.taken and icon then   -- setCustomAssets fails on a nil URL
        assets[#assets + 1] = {name = "act", url = icon}
        local tint = state.activated and "#666666" or "#FFFFFF"
        parts[#parts + 1] = '<Image image="act" width="70" height="70" offsetXY="5 -5" color="#000000AA" preserveAspect="true"/>'
            .. '<Image image="act" width="70" height="70" offsetXY="2.5 -2.5" color="#202020DD" preserveAspect="true"/>'
            .. '<Button onClick="ui_toggleActivation" width="70" height="70" colors="#FFFFFF00|#FFFFFF00|#FFFFFF00|#FFFFFF00">'
            .. '<Image image="act" color="' .. tint .. '" preserveAspect="true"/></Button>'
    end
    local n = #state.tokens
    for i, t in ipairs(state.tokens) do
        if t.url and t.url ~= "" then
            assets[#assets + 1] = {name = "tok" .. i, url = t.url}
            parts[#parts + 1] = '<Button id="tok:' .. i .. '" onClick="ui_removeToken" offsetXY="'
                .. ((i - (n + 1) / 2) * 65) .. ' -90" width="60" height="60"'
                .. ' colors="#FFFFFF00|#FFFFFF33|#FFFFFF55|#FFFFFF00"><Image image="tok' .. i
                .. '" width="60" height="60" preserveAspect="true"/></Button>'
        end
    end
    if #parts == 0 then
        self.UI.setXml("")
        return
    end
    self.UI.setCustomAssets(assets)
    self.UI.setXml('<Panel position="0 -150 -250" width="400" height="400">' .. table.concat(parts) .. '</Panel>')
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

function ui_removeToken(player, value, id)
    local i = tonumber(string.sub(id, 5))   -- strip "tok:"
    if i and state.tokens[i] then table.remove(state.tokens, i) end
    renderPanel()
    saveState()
end

-- ============ FLOATING DICE ============
local function findLink(guid)
    for i, l in ipairs(state.links) do
        if l.guid == guid then return i end
    end
    return nil
end

-- Dice stay normal objects (number keys, picking up); only gravity is off, and high drag
-- keeps bumps from pushing them away. Uses TTS's own use_gravity / drag members: setting the
-- Unity Rigidbody directly gets overridden by TTS.
local function setFloating(obj, link, on)
    if on then
        obj.use_gravity = false
        obj.drag = 10
        obj.angular_drag = 10
        obj.setVelocity({0, 0, 0})
        obj.setAngularVelocity({0, 0, 0})
    else
        obj.use_gravity = true
        obj.drag = link.drag or 0.1
        obj.angular_drag = link.ang or 0.1
    end
end

-- Moves every linked die back into its slot and forgets dice that no longer exist.
function snapMarkers()
    if following then return end   -- the follow loop places them while the model moves
    local live = {}
    for _, l in ipairs(state.links) do
        local o = getObjectFromGUID(l.guid)
        if o then live[#live + 1] = {link = l, obj = o} end
    end
    state.links = {}
    for i, e in ipairs(live) do
        state.links[i] = e.link
        setFloating(e.obj, e.link, true)
        e.obj.setPositionSmooth(slotPosition(i, e.obj.getBoundsNormalized().size.y), false, true)
    end
    saveState()
end

-- While the model is held, falling or moved by "Load position", its dice are locked (so
-- physics can't make them drift or flicker) and placed above it every frame. Once the model
-- rests they are unlocked and float freely again.
local function followStep()
    if self == nil then
        following = false
        return
    end
    followFrames = followFrames - 1
    local moving = self.held_by_color ~= nil or not self.resting or followFrames > 0
    local i = 0
    for _, l in ipairs(state.links) do
        local o = getObjectFromGUID(l.guid)
        if o then
            i = i + 1
            if moving then
                o.setPosition(slotPosition(i, o.getBoundsNormalized().size.y))
            else
                o.setLock(false)
            end
        end
    end
    if moving then
        Wait.frames(followStep, 1)
    else
        following = false
        snapMarkers()
    end
end

local function startFollowing()
    followFrames = FOLLOW_MIN
    if following or #state.links == 0 then return end
    following = true
    for _, l in ipairs(state.links) do
        local o = getObjectFromGUID(l.guid)
        if o then o.setLock(true) end
    end
    Wait.frames(followStep, 1)
end

local function unlink(guid, destroy)
    local i = findLink(guid)
    if not i then return end
    local l = table.remove(state.links, i)
    local o = getObjectFromGUID(guid)
    if o then
        o.setLock(false)
        if destroy then o.destruct() else setFloating(o, l, false) end
    end
    snapMarkers()
end

local function addRemoveMenu(obj)
    local guid = obj.getGUID()
    obj.addContextMenuItem("Remove marker", function() unlink(guid, true) end)
end

local function link(obj)
    if findLink(obj.getGUID()) then snapMarkers() return end
    state.links[#state.links + 1] = {guid = obj.getGUID(), drag = obj.drag, ang = obj.angular_drag}
    addRemoveMenu(obj)
    snapMarkers()
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

-- Global event, delivered to every object script: handles the model itself being put down,
-- dice/tokens dropped onto it, and its dice being dragged away.
function onObjectDrop(player_color, obj)
    if obj == nil then return end
    if obj == self then
        Wait.frames(stabilize, 10)
        startFollowing()   -- keeps the dice with the model while it falls
        Wait.time(function()
            if self == nil or state.taken or onPlatform() then return end
            state.taken = true   -- off the spawner's platform: show the activation icon
            renderPanel()
            saveState()
        end, 0.5)
        return
    end
    local linked = findLink(obj.getGUID())
    local token = hasTokenTag(obj)
    if not (linked or token or obj.type == "Dice") then return end
    local onto = isOntoMe(obj.getPosition())
    if token then
        if onto then addToken(obj) end
    elseif onto then
        link(obj)
    elseif linked then
        unlink(obj.getGUID(), false)
    end
end

-- Number keys over a linked die: TTS's own handling puts the die down, so set the face here
-- and keep it floating. Returning true stops TTS's default.
function onObjectNumberTyped(obj, player_color, number)
    if obj == nil or obj.type ~= "Dice" or not findLink(obj.getGUID()) then return end
    obj.setValue(number)
    Wait.frames(snapMarkers, 5)
    return true
end

-- A rolled die flies off without gravity; put it back once it has its number.
function onObjectRandomize(obj)
    if findLink(obj.getGUID()) then Wait.time(snapMarkers, 1.5) end
end

-- Linked dice get gravity back so they don't hang in the air without their model.
-- After a reload onLoad makes them float again.
function onDestroy()
    for _, l in ipairs(state.links) do
        local o = getObjectFromGUID(l.guid)
        if o then
            o.setLock(false)
            setFloating(o, l, false)
        end
    end
end

function onLoad(saved_data)
    if saved_data and saved_data ~= "" then
        local ok, data = pcall(JSON.decode, saved_data)
        if ok and type(data) == "table" then
            for k, v in pairs(data) do state[k] = v end
        end
    end
    state.tokens, state.links = state.tokens or {}, state.links or {}
    self.addTag(MODEL_TAG)
    self.max_typed_number = 1   -- every key press reaches onNumberTyped; two digits are buffered there

    self.addContextMenuItem("Save position", savePosition)
    self.addContextMenuItem("Load position", loadPosition)
    self.addContextMenuItem("Unlink dice", function()
        for _, l in ipairs(state.links) do
            local o = getObjectFromGUID(l.guid)
            if o then
                o.setLock(false)
                setFloating(o, l, false)
            end
        end
        state.links = {}
        saveState()
    end)
    self.addContextMenuItem("Clear tokens", function()
        state.tokens = {}
        renderPanel()
        saveState()
    end)

    -- Other objects (and our dice) may still be loading; set things up a bit later.
    Wait.frames(function()
        if self == nil then return end
        stabilize()
        renderPanel()
        for _, l in ipairs(state.links) do
            local o = getObjectFromGUID(l.guid)
            if o then
                o.setLock(false)   -- in case the game was saved while the model was moving
                addRemoveMenu(o)
            end
        end
        snapMarkers()
    end, 30)
end
