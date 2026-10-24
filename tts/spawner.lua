-- =============================================
-- TC MINIATURES - SPAWNER
-- =============================================
-- Contains no models. On load it fetches catalog/version.json and catalog/index.json from
-- GitHub and builds a menu. Clicking a unit fetches that unit's file and spawns its models
-- in labelled rows behind the spawner; clicking it again removes them.
--
-- Spawned objects carry the tag TCM_Spawned and a memo "<token>|<faction>/<unit>". The token
-- is a random id saved in this object's state, so it survives GUID changes (TTS reassigns
-- GUIDs on collision, e.g. when a save with another spawner is loaded).

local SPAWNER_VERSION = 1

-- ===================== CONFIG =====================
local RAW_BASE  = "https://raw.githubusercontent.com/PriestofMork/TTS-TC-Model-Collection/main/"
local SPAWN_TAG = "TCM_Spawned"

-- Layout, in world units relative to the spawner (follows its position and rotation, not its
-- scale). Rows start behind the spawner (local +z, away from a player reading the panel).
local LAYOUT_GAP    = 2      -- between the spawner's back edge and the first label
local MAX_ROW_WIDTH = 30     -- rows wrap after this width
local MODEL_PAD     = 0.4    -- space between models in a row
local ROW_GAP       = 0.6    -- space between rows
local LABEL_DEPTH   = 1.4    -- room reserved for a unit's label above its first row
local SPAWN_HEIGHT  = 0.5    -- models are spawned this far above the table and settle

-- Catalog models have rotY 0 (export resets it). They get the spawner's yaw plus this.
-- Change to 180 if models come out facing away from the players.
local MODEL_YAW = 0
-- 3D text lying flat on the table: pitch 90. Adjust LABEL_YAW if labels read upside down.
local LABEL_PITCH = 90
local LABEL_YAW   = 0
local LABEL_FONT  = 48

local BATCH_SIZE = 15        -- objects spawned or destroyed per frame

local UI_MARGIN = 5          -- extra lift above the object's top face, in UI units
local UI_SCALE  = 1
-- ==================================================

local index        = nil     -- decoded catalog/index.json
local factionById  = {}
local token        = nil
local sel          = {f = nil, sub = nil}
local spawned      = {}      -- "faction/unit" -> true
local cursorZ      = 0       -- next free row position (world units behind LAYOUT_GAP)
local busy         = false
local status       = "Loading catalog..."
local renderPending = false
local unitCache    = {}      -- unit file -> decoded entries (for the loaded catalog version)

-- ============ UTIL ============
local function xmlEscape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function uiHeight()
    -- getBoundsNormalized ignores rotation but includes scale; UI units are 100 per local unit.
    local halfLocal = self.getBoundsNormalized().size.y / 2 / self.getScale().y
    return -math.ceil(halfLocal * 100 + UI_MARGIN)
end

local function tableY()
    local b = self.getBounds()
    return b.center.y - b.size.y / 2
end

-- Layout position (x across, z rows going back) -> world position. positionToWorld uses
-- local (scaled) units, so divide by scale to keep the layout in world units.
local function layoutToWorld(x, z)
    local s = self.getScale()
    local backEdge = self.getBoundsNormalized().size.z / 2
    local pos = self.positionToWorld(Vector(x / s.x, 0, (backEdge + LAYOUT_GAP + z) / s.z))
    pos.y = tableY() + SPAWN_HEIGHT
    return pos
end

local function unitKey(f, u) return f .. "/" .. u end

-- Models of a unit visible under the current subfaction filter.
local function unitCount(unit)
    if not sel.sub then return unit.count end
    return (unit.any or 0) + ((unit.subs or {})[sel.sub] or 0)
end

local function entryMatches(entry)
    if not sel.sub or not entry.s or #entry.s == 0 then return true end
    for _, s in ipairs(entry.s) do
        if s == sel.sub then return true end
    end
    return false
end

-- ============ STATUS / UI ============
-- setXml takes a frame or two to apply and setValue on the old UI is lost when it is
-- replaced, so status is baked into each render and re-applied a few frames later.
local function setStatus(text)
    status = text
    self.UI.setValue("status", status)
    Wait.frames(function() self.UI.setValue("status", status) end, 5)
end

local function buildXml()
    local x = {}
    local function add(s) x[#x + 1] = s end

    add('<Defaults><Text fontSize="18" color="#FFFFFF"/><Button fontSize="17"/><Dropdown fontSize="18"/></Defaults>')
    add('<Panel position="0 0 ' .. uiHeight() .. '" rotation="0 0 180" width="460" height="720" scale="'
        .. UI_SCALE .. ' ' .. UI_SCALE .. ' 1" color="#1A1A1AEE">')
    add('<VerticalLayout padding="12 12 12 12" spacing="6" childForceExpandHeight="false">')
    add('<Text preferredHeight="30" fontSize="22" fontStyle="Bold">TC Miniatures</Text>')

    local fe = index and factionById[sel.f]
    if fe then
        add('<Dropdown id="faction" preferredHeight="40" onValueChanged="ui_faction">')
        for _, f in ipairs(index.factions) do
            add('<Option' .. (f.id == sel.f and ' selected="true"' or '') .. '>' .. xmlEscape(f.name) .. '</Option>')
        end
        add('</Dropdown>')

        local subs = fe.subfactions or {}
        if #subs > 0 then
            add('<Dropdown id="sub" preferredHeight="40" onValueChanged="ui_sub">')
            add('<Option' .. (sel.sub == nil and ' selected="true"' or '') .. '>All subfactions</Option>')
            for _, s in ipairs(subs) do
                add('<Option' .. (s.id == sel.sub and ' selected="true"' or '') .. '>' .. xmlEscape(s.name) .. '</Option>')
            end
            add('</Dropdown>')
        end

        add('<Text preferredHeight="22" fontSize="15" color="#AAAAAA" alignment="MiddleLeft">Click a unit to spawn it, click again to remove it.</Text>')
        local rows = {}
        for _, u in ipairs(fe.units) do
            local n = unitCount(u)
            if n > 0 then
                local on = spawned[unitKey(fe.id, u.id)]
                rows[#rows + 1] = '<Button id="u:' .. xmlEscape(u.id) .. '" onClick="ui_unit" preferredHeight="34"'
                    .. (on and ' colors="#3A7A3A|#4A9A4A|#2A5A2A|#555555" textColor="#FFFFFF"' or '')
                    .. '>' .. (on and '[spawned] ' or '') .. xmlEscape(u.name) .. ' (' .. n .. ')</Button>'
            end
        end
        -- A scroll view's content needs an explicit height.
        add('<VerticalScrollView preferredHeight="380" scrollSensitivity="30" color="#00000000">')
        add('<VerticalLayout height="' .. math.max(#rows * 38, 10) .. '" spacing="4" childForceExpandHeight="false">')
        add(#rows > 0 and table.concat(rows) or '<Text color="#AAAAAA">No models for this filter.</Text>')
        add('</VerticalLayout></VerticalScrollView>')

        add('<HorizontalLayout preferredHeight="44" spacing="6">')
        add('<Button onClick="ui_spawnFaction">Spawn whole faction</Button>')
        add('<Button onClick="ui_clearAll">Clear all</Button>')
        add('</HorizontalLayout>')
    else
        add('<Button onClick="ui_reload" preferredHeight="40">Reload catalog</Button>')
    end

    add('<Text id="status" preferredHeight="80" fontSize="15" alignment="UpperLeft">' .. xmlEscape(status) .. '</Text>')
    add('</VerticalLayout></Panel>')
    return table.concat(x)
end

-- Coalesce several render() calls in one frame into a single setXml.
local function render()
    if renderPending then return end
    renderPending = true
    Wait.frames(function()
        renderPending = false
        self.UI.setXml(buildXml())
    end, 1)
end

-- ============ SPAWN QUEUE ============
-- One queue for spawning and destroying, processed BATCH_SIZE per frame, so a whole faction
-- (hundreds of models) doesn't freeze the game on one frame.
local queue, queueRunning, queueDone = {}, false, nil

local function runQueue()
    for _ = 1, BATCH_SIZE do
        local job = table.remove(queue, 1)
        if not job then break end
        job()
    end
    if #queue > 0 then
        Wait.frames(runQueue, 1)
    else
        queueRunning = false
        local done = queueDone
        queueDone = nil
        if done then done() end
    end
end

-- Runs all queued jobs, then calls done.
local function flushQueue(done)
    queueDone = done
    if queueRunning then return end
    queueRunning = true
    Wait.frames(runQueue, 1)
end

local function spawnLabel(text, pos, memo)
    local yaw = self.getRotation().y
    spawnObject({
        type     = "3DText",
        position = pos,
        rotation = {LABEL_PITCH, yaw + LABEL_YAW, 0},
        callback_function = function(obj)
            obj.TextTool.setValue(text)
            obj.TextTool.setFontSize(LABEL_FONT)
            obj.memo = memo
            obj.addTag(SPAWN_TAG)
        end,
    })
end

local function spawnModel(data, pos, memo)
    local t = data.Transform or {}
    -- Tag and memo go into the data before spawning, so no per-object call is needed after.
    data.Memo = memo
    data.Tags = data.Tags or {}
    local hasTag = false
    for _, tag in ipairs(data.Tags) do
        if tag == SPAWN_TAG then hasTag = true end
    end
    if not hasTag then table.insert(data.Tags, SPAWN_TAG) end
    spawnObjectData({
        data     = data,
        position = pos,
        rotation = {t.rotX or 0, self.getRotation().y + MODEL_YAW, t.rotZ or 0},
    })
end

-- Lays out one unit: a label, then rows of models wrapped at MAX_ROW_WIDTH, each row as deep
-- as its deepest model. w/d come from the intake because bounds aren't known before loading.
local function queueUnit(f, unit, entries)
    local key = unitKey(f, unit.id)
    local memo = token .. "|" .. key
    local x0 = -MAX_ROW_WIDTH / 2

    local labelPos = layoutToWorld(x0 + MAX_ROW_WIDTH / 2, cursorZ + LABEL_DEPTH / 2)
    local label = unit.name .. " (" .. #entries .. ")"
    queue[#queue + 1] = function() spawnLabel(label, labelPos, memo) end
    cursorZ = cursorZ + LABEL_DEPTH

    local x, rowDepth, row = x0, 0, {}
    local function flushRow()
        local zc = cursorZ + rowDepth / 2
        for _, item in ipairs(row) do
            local pos = layoutToWorld(item.x, zc)
            local data = item.data
            queue[#queue + 1] = function() spawnModel(data, pos, memo) end
        end
        cursorZ = cursorZ + rowDepth + ROW_GAP
        x, rowDepth, row = x0, 0, {}
    end

    for _, entry in ipairs(entries) do
        local w, d = entry.w or 1.5, entry.d or 1.5
        if #row > 0 and x + w > x0 + MAX_ROW_WIDTH then flushRow() end
        row[#row + 1] = {data = entry.data, x = x + w / 2}
        x = x + w + MODEL_PAD
        if d > rowDepth then rowDepth = d end
    end
    if #row > 0 then flushRow() end
    spawned[key] = true
end

-- Fetches a unit file (cached per catalog version) and passes the decoded entries to callback,
-- or nil on error.
local function fetchUnit(unit, callback)
    if unitCache[unit.file] then callback(unitCache[unit.file]) return end
    WebRequest.get(RAW_BASE .. "catalog/" .. unit.file .. "?v=" .. index.version, function(req)
        if req.is_error or (req.response_code and req.response_code >= 400) then
            setStatus("Could not load " .. unit.name .. ": " .. tostring(req.error or req.response_code))
            callback(nil)
            return
        end
        local ok, entries = pcall(JSON.decode, req.text)
        if not ok or type(entries) ~= "table" then
            setStatus("Could not read " .. unit.name .. " (bad JSON).")
            callback(nil)
            return
        end
        unitCache[unit.file] = entries
        callback(entries)
    end)
end

-- Spawns the given units one after another, then calls done.
local function spawnUnits(f, units, done)
    local i, total = 0, 0
    local function nextUnit()
        i = i + 1
        local unit = units[i]
        if not unit then
            flushQueue(function() done(total) end)
            return
        end
        setStatus("Loading " .. unit.name .. "...")
        fetchUnit(unit, function(entries)
            if entries then
                local list = {}
                for _, e in ipairs(entries) do
                    if entryMatches(e) then list[#list + 1] = e end
                end
                if #list > 0 then
                    queueUnit(f, unit, list)
                    total = total + #list
                    render()
                end
            end
            -- Start spawning this unit while the next one downloads.
            flushQueue(nil)
            nextUnit()
        end)
    end
    nextUnit()
end

-- Destroys this spawner's objects, all of them or only one unit's (key).
local function clearSpawned(key, done)
    local prefix = token .. "|"
    local wanted = key and (prefix .. key) or nil
    local count = 0
    for _, obj in ipairs(getObjectsWithTag(SPAWN_TAG)) do
        local memo = obj.memo or ""
        local mine = wanted and memo == wanted or (not wanted and string.find(memo, prefix, 1, true) == 1)
        if mine then
            count = count + 1
            queue[#queue + 1] = function()
                if obj ~= nil then obj.destruct() end   -- destroyed objects compare equal to nil
            end
        end
    end
    if key then spawned[key] = nil else spawned = {} end
    if next(spawned) == nil then cursorZ = 0 end   -- rows are not compacted, only reset when empty
    flushQueue(function() done(count) end)
end

-- ============ CATALOG LOADING ============
local function applyIndex(text)
    local ok, data = pcall(JSON.decode, text)
    if not ok or type(data) ~= "table" or type(data.factions) ~= "table" or #data.factions == 0 then
        setStatus("Catalog index could not be read.")
        render()
        return
    end
    index, factionById, unitCache = data, {}, {}
    for _, f in ipairs(data.factions) do factionById[f.id] = f end
    if not factionById[sel.f] then sel.f, sel.sub = data.factions[1].id, nil end
    setStatus("Catalog version " .. tostring(data.version) .. " loaded.")
    render()
end

local function loadIndex(catalogVersion)
    WebRequest.get(RAW_BASE .. "catalog/index.json?v=" .. tostring(catalogVersion or os.time()), function(req)
        if req.is_error or (req.response_code and req.response_code >= 400) then
            setStatus("Could not load the catalog index (" .. tostring(req.error or req.response_code) .. ").")
            render()
            return
        end
        applyIndex(req.text)
    end)
end

-- Replaces this object's script with the published one if version.json announces a newer
-- spawner. Returns true if an update was started.
local function selfUpdate(v)
    if type(v.spawner) ~= "number" or v.spawner <= SPAWNER_VERSION or not v.spawnerUrl then return false end
    setStatus("Updating spawner to version " .. v.spawner .. "...")
    WebRequest.get(RAW_BASE .. v.spawnerUrl .. "?v=" .. v.spawner, function(req)
        -- Guard against an endless reload loop: the new script must itself declare the
        -- version that version.json announces.
        if req.is_error or not string.find(req.text or "", "SPAWNER_VERSION = " .. v.spawner, 1, true) then
            setStatus("Spawner update failed; using version " .. SPAWNER_VERSION .. ".")
            loadIndex(v.catalog)
            return
        end
        self.script_state = onSave()
        self.setLuaScript(req.text)
        self.reload()   -- replaces this object; nothing may use `self` after this
    end)
    return true
end

local function loadCatalog()
    index = nil
    setStatus("Loading catalog...")
    render()
    -- version.json is tiny and fetched with a timestamp so a new catalog is seen immediately;
    -- the other files are fetched with the catalog version, so GitHub's cache can serve them.
    WebRequest.get(RAW_BASE .. "catalog/version.json?v=" .. os.time(), function(req)
        local v = {}
        if not req.is_error then
            local ok, data = pcall(JSON.decode, req.text)
            if ok and type(data) == "table" then v = data end
        end
        if not selfUpdate(v) then loadIndex(v.catalog) end
    end)
end

-- ============ UI CALLBACKS ============
-- XML UI passes (player, value, id). Dropdown value is the selected option's text.
function ui_faction(player, value)
    for _, f in ipairs(index.factions) do
        if f.name == value and f.id ~= sel.f then
            sel.f, sel.sub = f.id, nil
            render()
            break
        end
    end
end

function ui_sub(player, value)
    sel.sub = nil
    for _, s in ipairs(factionById[sel.f].subfactions or {}) do
        if s.name == value then sel.sub = s.id end
    end
    render()
end

function ui_unit(player, value, id)
    if busy or not index then return end
    local uid = string.sub(id, 3)   -- strip "u:"
    local fe = factionById[sel.f]
    local key = unitKey(fe.id, uid)
    busy = true
    if spawned[key] then
        clearSpawned(key, function(n)
            busy = false
            setStatus("Removed " .. n .. " object(s).")
            render()
        end)
        return
    end
    for _, u in ipairs(fe.units) do
        if u.id == uid then
            spawnUnits(fe.id, {u}, function(n)
                busy = false
                setStatus("Spawned " .. n .. " model(s) of " .. u.name .. ".")
                render()
            end)
            return
        end
    end
    busy = false
end

function ui_spawnFaction()
    if busy or not index then return end
    local fe = factionById[sel.f]
    local units = {}
    for _, u in ipairs(fe.units) do
        if unitCount(u) > 0 and not spawned[unitKey(fe.id, u.id)] then units[#units + 1] = u end
    end
    if #units == 0 then setStatus("Everything in this faction is already spawned.") return end
    busy = true
    spawnUnits(fe.id, units, function(n)
        busy = false
        setStatus("Spawned " .. n .. " model(s) from " .. fe.name .. ".")
        render()
    end)
end

function ui_clearAll()
    if busy then return end
    busy = true
    clearSpawned(nil, function(n)
        busy = false
        setStatus("Removed " .. n .. " object(s).")
        render()
    end)
end

function ui_reload() loadCatalog() end

-- ============ SAVE / LOAD ============
function onSave()
    return JSON.encode({token = token, cursorZ = cursorZ, f = sel.f, sub = sel.sub})
end

function onLoad(saved_data)
    if saved_data and saved_data ~= "" then
        local ok, data = pcall(JSON.decode, saved_data)
        if ok and type(data) == "table" then
            token, cursorZ, sel.f, sel.sub = data.token, data.cursorZ or 0, data.f, data.sub
        end
    end
    if not token then
        math.randomseed(os.time())
        token = "tcm" .. os.time() .. math.random(100000, 999999)
    end

    -- Rebuild which units are on the table from the spawned objects themselves.
    local prefix = token .. "|"
    for _, obj in ipairs(getObjectsWithTag(SPAWN_TAG)) do
        local memo = obj.memo or ""
        if string.find(memo, prefix, 1, true) == 1 then spawned[string.sub(memo, #prefix + 1)] = true end
    end
    if next(spawned) == nil then cursorZ = 0 end

    loadCatalog()
end
