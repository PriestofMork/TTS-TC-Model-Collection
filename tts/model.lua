-- =============================================
-- TC MINIATURES - MODEL SCRIPT
-- =============================================
-- The spawner puts this into every model it spawns (unless "Model scripts" is off).
--
--  * Range rings: hover the model and type a number (two digits within 0.8 s). Typing the
--    same number again, or 0, clears it.
--  * Stabilisation: rotation is frozen while the model stands, so it doesn't tip over.
--  * Save / Load position: right-click menu; the spawner has Save all / Load all.
--  * Image tokens: drop a token tagged TCUITokenSimple / TCUITokenEquipment onto the model.
--    It shows as an icon above the model; click the icon to remove it.
--  * Floating markers: once the model is taken off the spawner's platform it gets its
--    faction's activation token floating above it; any multi-state token dropped onto it
--    links as its activation token too. Any die dropped onto the model floats next to that
--    token. Markers stay above the model, also while it is carried.
--    Right-click a die -> "Remove marker", or drag it off the model to unlink it.
--
-- Ideas from the legacy UI extender; stabilisation from Pyromaniacal's Stabilized Bases (MIT).

local RAW_BASE       = "https://raw.githubusercontent.com/PriestofMork/TTS-TC-Model-Collection/main/"
local MODEL_TAG      = "TCM_Model"
local ACTIVATION_TAG = "TCM_Activation"
local PLATFORM_NAME  = "TC spawn platform"
local TOKEN_TAGS     = {"TCUITokenSimple", "TCUITokenEquipment"}

local MARKER_GAP     = 0.8    -- space between the top of the model and the bottom of a marker
local MARKER_SPACING = 1.1    -- distance between dice in the row
local DICE_OFFSET    = 1.0    -- first die sits this far to the side of the activation token
local RANGE_STEPS    = 64     -- points per range ring

-- f / cv are set by the spawner (faction id, catalog version). links = floating markers,
-- activation token first; each keeps the drag values to restore when it is unlinked.
state = {f = nil, cv = nil, savePos = nil, tokens = {}, links = {}, activation = nil, asked = false}

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

-- Position above the model, turned with it. The activation token (diceIndex nil) is centred
-- over the model; dice go to its side in a row. markerHeight is the marker's own height,
-- so its bottom (not its centre) sits MARKER_GAP above the model.
local function slotPosition(diceIndex, markerHeight)
    local x = diceIndex and (DICE_OFFSET + (diceIndex - 1) * MARKER_SPACING) or 0
    local offset = Vector(x, 0, 0):rotateOver("y", self.getRotation().y)
    local p = self.getPosition()
    return Vector(p.x + offset.x, modelTop() + MARKER_GAP + (markerHeight or 1) / 2, p.z + offset.z)
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

-- ============ FLOATING MARKERS ============
local function findLink(guid)
    for i, l in ipairs(state.links) do
        if l.guid == guid then return i end
    end
    return nil
end

-- Markers stay normal objects (number keys, state switching, picking up all work); only
-- gravity is switched off, and high drag keeps bumps from pushing them away. Uses TTS's own
-- use_gravity / drag members: setting the Unity Rigidbody directly gets overridden by TTS.
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

-- Moves every linked marker back into its slot and forgets markers that no longer exist.
-- instant = teleport (used while the model is carried), otherwise a short smooth move.
function snapMarkers(instant)
    local live = {}
    for _, l in ipairs(state.links) do
        local o = getObjectFromGUID(l.guid)
        if o then live[#live + 1] = {link = l, obj = o} end
    end
    state.links = {}
    local dice = 0
    for i, e in ipairs(live) do
        state.links[i] = e.link
        local diceIndex = nil
        if e.link.guid ~= state.activation then
            dice = dice + 1
            diceIndex = dice
        end
        local pos = slotPosition(diceIndex, e.obj.getBoundsNormalized().size.y)
        if instant == true then
            e.obj.setPosition(pos)
            e.obj.setVelocity({0, 0, 0})
        else
            setFloating(e.obj, e.link, true)
            e.obj.setPositionSmooth(pos, false, true)
        end
    end
    if instant ~= true then saveState() end
end

local function unlink(guid, destroy)
    local i = findLink(guid)
    if not i then return end
    local l = table.remove(state.links, i)
    if state.activation == guid then state.activation = nil end
    local o = getObjectFromGUID(guid)
    if o then
        if destroy then o.destruct() else setFloating(o, l, false) end
    end
    snapMarkers()
end

local function addRemoveMenu(obj)
    if obj.type ~= "Dice" then return end
    local guid = obj.getGUID()
    obj.addContextMenuItem("Remove marker", function() unlink(guid, true) end)
end

local function link(obj, first)
    if findLink(obj.getGUID()) then snapMarkers() return end
    local entry = {guid = obj.getGUID(), drag = obj.drag, ang = obj.angular_drag}
    if first then table.insert(state.links, 1, entry) else state.links[#state.links + 1] = entry end
    addRemoveMenu(obj)
    snapMarkers()
end

-- Spawns this faction's activation token (or the general one) above the model, once.
local function requestActivation()
    if state.asked or not state.f then return end
    state.asked = true
    saveState()
    WebRequest.get(RAW_BASE .. "catalog/tokens.json?v=" .. tostring(state.cv or os.time()), function(req)
        if req.is_error then return end
        local ok, tokens = pcall(JSON.decode, req.text)
        if not ok or type(tokens) ~= "table" or type(tokens.activation) ~= "table" then return end
        local data = tokens.activation[state.f] or tokens.activation.general
        if not data or self == nil then return end
        spawnObjectData({
            data = data,
            position = slotPosition(nil, 1),
            callback_function = function(o)
                state.activation = o.getGUID()
                link(o, true)
            end,
        })
    end)
end

-- Activation tokens are multi-state objects; any one dropped onto a model counts, whether it
-- came from the catalog (tagged) or from a table's bag (untagged).
local function isActivationToken(obj)
    if obj.hasTag(ACTIVATION_TAG) then return true end
    local ok, states = pcall(obj.getStates)
    return ok and type(states) == "table" and #states > 0
end

-- ============ IMAGE TOKENS ============
local function hasTokenTag(obj)
    for _, t in ipairs(TOKEN_TAGS) do
        if obj.hasTag(t) then return true end
    end
    return false
end

-- Buttons use the token's index as id, so names with special characters can't break the XML.
local function renderTokens()
    local assets, buttons, n = {}, {}, #state.tokens
    for i, t in ipairs(state.tokens) do
        if t.url and t.url ~= "" then   -- setCustomAssets fails on a nil/empty URL
            assets[#assets + 1] = {name = "tok" .. i, url = t.url}
            -- No tooltip: TTS draws object-UI tooltips on the ground and can leave them stuck.
            buttons[#buttons + 1] = '<Button id="tok:' .. i .. '" onClick="ui_removeToken" rectAlignment="MiddleCenter" offsetXY="' .. ((i - (n + 1) / 2) * 65) .. ' -90" width="60" height="60"'
                .. ' colors="#FFFFFF00|#FFFFFF33|#FFFFFF55|#FFFFFF00"><Image image="tok' .. i
                .. '" width="60" height="60" preserveAspect="true"/></Button>'
        end
    end
    if #buttons == 0 then
        self.UI.setXml("")
        return
    end
    self.UI.setCustomAssets(assets)
    self.UI.setXml('<Panel position="0 -150 -250" width="400" height="400">' .. table.concat(buttons) .. '</Panel>')
end

local function addToken(obj)
    local name = obj.getName() ~= "" and obj.getName() or obj.getDescription()
    local custom = obj.getCustomObject() or {}
    state.tokens[#state.tokens + 1] = {name = name, url = custom.image}
    obj.destruct()
    renderTokens()
    saveState()
end

function ui_removeToken(player, value, id)
    local i = tonumber(string.sub(id, 5))   -- strip "tok:"
    if i and state.tokens[i] then table.remove(state.tokens, i) end
    renderTokens()
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
    Wait.time(snapMarkers, 1)
end

-- ============ EVENTS ============
-- While the model is held, keep its markers above it (every few frames, until it's dropped).
local function followWhileHeld()
    if self == nil or self.held_by_color == nil then return end
    snapMarkers(true)
    Wait.frames(followWhileHeld, 3)
end

function onPickUp()
    destabilize()
    if #state.links > 0 then Wait.frames(followWhileHeld, 3) end
end

-- Global event, delivered to every object script: handles the model itself being put down,
-- dice/tokens dropped onto it, and its markers being dragged away.
function onObjectDrop(player_color, obj)
    if obj == nil then return end
    if obj == self then
        Wait.frames(stabilize, 10)
        Wait.time(function()
            if self == nil then return end
            if not state.activation and not onPlatform() then requestActivation() end
            snapMarkers()
        end, 0.5)
        return
    end
    local linked = findLink(obj.getGUID())
    local token = hasTokenTag(obj)
    local activation = not token and isActivationToken(obj)
    if not (linked or token or activation or obj.type == "Dice") then return end
    local onto = isOntoMe(obj.getPosition())
    if token then
        if onto then addToken(obj) end
    elseif onto then
        if activation then
            -- Tagged so "Ready all" finds it; a second activation token replaces nothing, it just links.
            if not obj.hasTag(ACTIVATION_TAG) then obj.addTag(ACTIVATION_TAG) end
            if not state.activation then state.activation = obj.getGUID() end
        end
        link(obj, activation)
    elseif linked then
        unlink(obj.getGUID(), false)
    end
end

-- Switching a multi-state object's state replaces it with a new object (new GUID).
function onObjectStateChange(obj, oldGuid)
    local i = findLink(oldGuid)
    if not i then return end
    state.links[i].guid = obj.getGUID()
    if state.activation == oldGuid then state.activation = obj.getGUID() end
    if not obj.hasTag(ACTIVATION_TAG) then obj.addTag(ACTIVATION_TAG) end
    snapMarkers()
end

-- A rolled die flies off without gravity; put it back once it has its number.
function onObjectRandomize(obj)
    if findLink(obj.getGUID()) then Wait.time(snapMarkers, 1.5) end
end

-- Linked markers get gravity back so they don't hang in the air without their model.
-- After a reload onLoad makes them float again.
function onDestroy()
    for _, l in ipairs(state.links) do
        local o = getObjectFromGUID(l.guid)
        if o then setFloating(o, l, false) end
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
    self.addContextMenuItem("Unlink markers", function()
        for _, l in ipairs(state.links) do
            local o = getObjectFromGUID(l.guid)
            if o then setFloating(o, l, false) end
        end
        state.links, state.activation = {}, nil
        saveState()
    end)
    self.addContextMenuItem("Clear tokens", function()
        state.tokens = {}
        renderTokens()
        saveState()
    end)

    -- Other objects (and our markers) may still be loading; set things up a bit later.
    Wait.frames(function()
        if self == nil then return end
        stabilize()
        renderTokens()
        for _, l in ipairs(state.links) do
            local o = getObjectFromGUID(l.guid)
            if o then addRemoveMenu(o) end
        end
        snapMarkers()
    end, 30)
end
