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

local SPAWNER_VERSION = 4

-- ===================== CONFIG =====================
local RAW_BASE  = "https://raw.githubusercontent.com/PriestofMork/TTS-TC-Model-Collection/main/"
local SPAWN_TAG = "TCM_Spawned"
local MODEL_TAG      = "TCM_Model"        -- models running tts/model.lua
local PLATFORM_NAME  = "TC spawn platform"

-- Layout, in world units relative to the spawner (follows its position and rotation, not its
-- scale). Rows start behind the panel as seen by a player reading it (local -z: tested in TTS,
-- a panel with rotation "0 0 180" reads upright from the object's +z side).
local LAYOUT_GAP    = 1.5    -- between the panel's back edge and the first label
local MAX_ROW_WIDTH = 30     -- rows wrap after this width
local MODEL_PAD     = 0.4    -- space between models in a row
local ROW_GAP       = 0.6    -- space between rows
local LABEL_DEPTH   = 1.4    -- room reserved for a unit's label above its first row
local BLOCK_GAP     = 1.0    -- space between two units' platforms

-- Each unit stands on its own locked platform, raised above the surface the spawner stands
-- on, so spawned models never land in terrain or on the board.
local PLATFORM_HEIGHT    = 2      -- top of the platform above the spawner's base (inches)
local PLATFORM_THICKNESS = 0.2
local PLATFORM_MARGIN    = 0.5    -- platform border around the label and rows
local PLATFORM_COLOR     = {0.12, 0.12, 0.12}
local SPAWN_HEIGHT       = 0.3    -- models are spawned this far above the platform and settle

-- Spawn-area indicator (vector lines on the spawner) at platform height. Only a hint of where
-- and in which direction units appear: the real row width, and a short depth.
local INDICATOR_DEPTH = 10
local INDICATOR_COLOR = {0.3, 0.8, 1}

-- Catalog models have rotY 0 (export resets it). They get the spawner's yaw plus this.
-- Change to 180 if models come out facing away from the players.
local MODEL_YAW = 0
-- 3D text lying flat on the table: pitch 90. Yaw 180 reads upright for the panel's reader.
local LABEL_PITCH = 90
local LABEL_YAW   = 180
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
local panelHeight  = 720     -- UI units; set by buildXml, used by the layout
local layoutEdge   = nil     -- distance from the spawner's centre to the first row (world units)
local showArea     = true    -- spawn-area indicator visible
local scriptsOn    = true    -- put tts/model.lua into spawned models
local modelScript  = nil     -- tts/model.lua, fetched on load
local importing    = false   -- the panel shows the warband import box
local importText   = ""      -- what was pasted; kept here, the box itself isn't re-rendered

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

-- Layout position -> world position. x runs left to right and z away from the reader
-- (both in world units from the back edge of the panel). The panel is usually much bigger
-- than the object, so its size decides where the layout starts. positionToWorld uses local
-- (scaled) units: UI units are 100 per local unit, and dividing by scale gives world units.
local function getLayoutEdge()
    -- Fixed once units are on the table, so switching to a faction with a taller menu
    -- doesn't shift where new rows go relative to existing ones.
    if layoutEdge then return layoutEdge end
    local panelHalf = panelHeight / 2 / 100 * UI_SCALE * self.getScale().z
    return math.max(self.getBoundsNormalized().size.z / 2, panelHalf) + LAYOUT_GAP
end

-- Layout (x, z) -> local (scaled) coordinates of the spawner, at world height offset dy
-- above the spawner's base. Used for vector lines, which are drawn in local space.
local function layoutToLocal(x, z, dy)
    local s, p = self.getScale(), self.getPosition()
    return {-x / s.x, (tableY() + dy - p.y) / s.y, -(getLayoutEdge() + z) / s.z}
end

-- Layout (x, z) -> world position at world height y.
local function layoutToWorld(x, z, y)
    local s = self.getScale()
    local pos = self.positionToWorld(Vector(-x / s.x, 0, -(getLayoutEdge() + z) / s.z))
    pos.y = y
    return pos
end

local function platformTop()
    return tableY() + PLATFORM_HEIGHT
end

-- Draws where units will spawn: an outline at platform height with an arrow pointing away
-- from the panel. Vector lines belong to the spawner, so they follow it when it moves.
local function drawIndicator()
    if not showArea then
        self.setVectorLines({})
        return
    end
    local h, half = PLATFORM_HEIGHT, MAX_ROW_WIDTH / 2
    local function at(x, z) return layoutToLocal(x, z, h) end
    local function line(points) return {points = points, color = INDICATOR_COLOR, thickness = 0.1} end
    self.setVectorLines({
        line({at(-half, 0), at(half, 0), at(half, INDICATOR_DEPTH), at(-half, INDICATOR_DEPTH), at(-half, 0)}),
        line({at(0, 1), at(0, 5)}),
        line({at(-1, 4), at(0, 5), at(1, 4)}),
    })
end

local function unitKey(f, u) return f .. "/" .. u end

-- TTS only calls onSave when the game is saved. Writing the state right away means a script
-- reload (e.g. pasting a new version) keeps the token and still recognises its own models.
local function saveState()
    self.script_state = onSave()
end

-- All objects carrying the spawn tag. getAllObjects + hasTag instead of getObjectsWithTag,
-- which can throw while the tag has never been used in this save.
local function spawnedObjects()
    local list = {}
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag(SPAWN_TAG) then list[#list + 1] = obj end
    end
    return list
end

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
local render

-- Status is part of the XML, so changing it re-renders the panel. Calling self.UI.setValue
-- instead throws a null-reference error while the panel doesn't exist yet (e.g. in onLoad).
local function setStatus(text)
    status = text
    render()
end

-- The panel's height is the sum of its rows, so it grows with the unit list instead of
-- needing a scroll view (TTS didn't draw the scroll view's contents).
local function buildXml()
    local x, height = {}, 24   -- 24 = top + bottom padding
    local function add(s) x[#x + 1] = s end
    local function row(h, s)
        height = height + h + 6   -- 6 = layout spacing
        add(s)
    end

    row(30, '<Text preferredHeight="30" fontSize="22" fontStyle="Bold">TC Miniatures</Text>')

    local fe = index and factionById[sel.f]
    if fe and importing then
        -- Paste box. The text lives in importText (onValueChanged); re-rendering the panel
        -- would empty the box, so status changes during the import don't touch it.
        row(44, '<Text preferredHeight="44" fontSize="15" alignment="MiddleLeft">Paste the TTS export from Trench Companion. '
            .. 'Faction and subfaction filter above decide which models are used.</Text>')
        row(200, '<InputField id="importBox" preferredHeight="200" fontSize="12" lineType="MultiLineNewline" '
            .. 'characterLimit="0" onValueChanged="ui_importText"></InputField>')
        row(44, '<HorizontalLayout preferredHeight="44" spacing="6">'
            .. '<Button onClick="ui_importGo" colors="#3A7A3A|#4A9A4A|#2A5A2A|#555555" textColor="#FFFFFF">Import</Button>'
            .. '<Button onClick="ui_importCancel">Cancel</Button></HorizontalLayout>')
    elseif fe then
        local opts = {}
        for _, f in ipairs(index.factions) do
            opts[#opts + 1] = '<Option' .. (f.id == sel.f and ' selected="true"' or '') .. '>' .. xmlEscape(f.name) .. '</Option>'
        end
        row(40, '<Dropdown id="faction" preferredHeight="40" onValueChanged="ui_faction">' .. table.concat(opts) .. '</Dropdown>')

        local subs = fe.subfactions or {}
        if #subs > 0 then
            opts = {'<Option' .. (sel.sub == nil and ' selected="true"' or '') .. '>All subfactions</Option>'}
            for _, sf in ipairs(subs) do
                opts[#opts + 1] = '<Option' .. (sf.id == sel.sub and ' selected="true"' or '') .. '>' .. xmlEscape(sf.name) .. '</Option>'
            end
            row(40, '<Dropdown id="sub" preferredHeight="40" onValueChanged="ui_sub">' .. table.concat(opts) .. '</Dropdown>')
        end

        row(22, '<Text preferredHeight="22" fontSize="15" color="#AAAAAA" alignment="MiddleLeft">Click a unit to spawn it, click again to remove it.</Text>')

        -- Unit buttons, two per row.
        local buttons = {}
        for _, u in ipairs(fe.units) do
            local n = unitCount(u)
            if n > 0 then
                local on = spawned[unitKey(fe.id, u.id)]
                buttons[#buttons + 1] = '<Button id="u:' .. xmlEscape(u.id) .. '" onClick="ui_unit" fontSize="15"'
                    .. (on and ' colors="#3A7A3A|#4A9A4A|#2A5A2A|#555555" textColor="#FFFFFF"' or '')
                    .. '>' .. xmlEscape(u.name) .. ' (' .. n .. ')</Button>'
            end
        end
        if #buttons == 0 then
            row(30, '<Text preferredHeight="30" color="#AAAAAA">No models for this filter.</Text>')
        end
        for i = 1, #buttons, 2 do
            row(40, '<HorizontalLayout preferredHeight="40" spacing="6">' .. buttons[i]
                .. (buttons[i + 1] or '<Text></Text>') .. '</HorizontalLayout>')
        end

        row(44, '<HorizontalLayout preferredHeight="44" spacing="6">'
            .. '<Button onClick="ui_spawnFaction">Spawn whole faction</Button>'
            .. '<Button onClick="ui_clearAll">Clear all</Button>'
            .. '<Button onClick="ui_toggleArea">' .. (showArea and 'Hide area' or 'Show area') .. '</Button>'
            .. '</HorizontalLayout>')
        row(40, '<HorizontalLayout preferredHeight="40" spacing="6">'
            .. '<Button onClick="ui_readyAll" fontSize="15">Ready all</Button>'
            .. '<Button onClick="ui_saveAll" fontSize="15">Save positions</Button>'
            .. '<Button onClick="ui_loadAll" fontSize="15">Load positions</Button>'
            .. '<Button onClick="ui_toggleScripts" fontSize="15">' .. (scriptsOn and 'Model scripts: on' or 'Model scripts: off')
            .. '</Button></HorizontalLayout>')
        row(40, '<Button onClick="ui_importOpen" preferredHeight="40">Import warband (Trench Companion)</Button>')
    else
        row(40, '<Button onClick="ui_reload" preferredHeight="40">Reload catalog</Button>')
    end

    row(60, '<Text preferredHeight="60" fontSize="15" alignment="UpperLeft">' .. xmlEscape(status) .. '</Text>')

    panelHeight = height
    return '<Defaults><Text fontSize="18" color="#FFFFFF"/><Button fontSize="17"/><Dropdown fontSize="18"/></Defaults>'
        .. '<Panel position="0 0 ' .. uiHeight() .. '" rotation="0 0 180" width="460" height="' .. height
        .. '" scale="' .. UI_SCALE .. ' ' .. UI_SCALE .. ' 1" color="#1A1A1AEE">'
        .. '<VerticalLayout padding="12 12 12 12" spacing="6" childForceExpandHeight="false">'
        .. table.concat(x) .. '</VerticalLayout></Panel>'
end

-- Coalesce several render() calls in one frame into a single setXml.
function render()
    if renderPending then return end
    renderPending = true
    Wait.frames(function()
        renderPending = false
        self.UI.setXml(buildXml())
        drawIndicator()   -- after buildXml: the layout starts at the panel's edge
    end, 1)
end

-- ============ SPAWN QUEUE ============
-- One queue for spawning and destroying, processed BATCH_SIZE per frame, so a whole faction
-- (hundreds of models) doesn't freeze the game on one frame.
local queue, queueRunning, queueDone = {}, false, nil

-- A job may return a number of frames to wait before the next job (e.g. to let a platform
-- finish spawning before models are dropped onto it).
local function runQueue()
    local pause = 1
    for _ = 1, BATCH_SIZE do
        -- MoonSharp's table.remove throws on an empty table (standard Lua returns nil).
        if #queue == 0 then break end
        local job = table.remove(queue, 1)
        -- One failing job must not stop the queue, or `busy` would stay set forever.
        local ok, result = pcall(job)
        if not ok then print("[TC Spawner] " .. tostring(result)) end
        if ok and type(result) == "number" then
            pause = result
            break
        end
    end
    if #queue > 0 then
        Wait.frames(runQueue, pause)
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

local function spawnModel(data, pos, memo, f)
    local t = data.Transform or {}
    -- The model script and its starting state (faction, for the activation icon) go into the data, so no "extend" step is needed. The data is
    -- cached per unit, so both are set (or cleared) on every spawn.
    if scriptsOn and modelScript then
        data.LuaScript = modelScript
        data.LuaScriptState = JSON.encode({f = f})
    else
        data.LuaScript, data.LuaScriptState = nil, nil
    end
    -- Tag and memo go into the data before spawning and are set again once the object exists,
    -- in case spawnObjectData ignores either field.
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
        callback_function = function(obj)
            obj.memo = memo
            if not obj.hasTag(SPAWN_TAG) then obj.addTag(SPAWN_TAG) end
        end,
    })
end

-- A plain locked block, spawned locked from the start so it never falls. Its native size
-- isn't known up front, so it is scaled to the wanted size once it exists.
local function spawnPlatform(pos, width, depth, memo)
    local c = PLATFORM_COLOR
    spawnObjectData({
        data = {
            Name         = "BlockSquare",
            Nickname     = "TC spawn platform",
            Transform    = {posX = pos.x, posY = pos.y, posZ = pos.z, rotX = 0, rotY = self.getRotation().y,
                            rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1},
            ColorDiffuse = {r = c[1], g = c[2], b = c[3]},
            Locked       = true,
            Tooltip      = false,
            Grid         = false,
            Snap         = false,
            Tags         = {SPAWN_TAG},
            Memo         = memo,
        },
        callback_function = function(obj)
            obj.memo = memo
            if not obj.hasTag(SPAWN_TAG) then obj.addTag(SPAWN_TAG) end
            local size, scale = obj.getBoundsNormalized().size, obj.getScale()
            obj.setScale({scale.x * width / size.x, scale.y * PLATFORM_THICKNESS / size.y, scale.z * depth / size.z})
        end,
    })
end

-- Lays out one block on its own platform: a label, then rows of models wrapped at
-- MAX_ROW_WIDTH, each row as deep as its deepest model. items = {data=, w=, d=, f=}; w/d come
-- from the intake because bounds aren't known before the models load, f is the faction the
-- model script gets (activation icon).
local function queueBlock(key, label, items)
    local memo = token .. "|" .. key
    if cursorZ == 0 then layoutEdge = nil end   -- empty table: measure the panel again
    layoutEdge = getLayoutEdge()

    local top = platformTop()
    local blockStart = cursorZ
    local z = blockStart + PLATFORM_MARGIN
    local jobs = {}

    -- Label and rows are centred on the spawner.
    local labelPos = layoutToWorld(0, z + LABEL_DEPTH / 2, top + 0.05)
    jobs[#jobs + 1] = function() spawnLabel(label, labelPos, memo) end
    z = z + LABEL_DEPTH

    local x, rowDepth, row, widest = 0, 0, {}, 0   -- x = width used so far in this row
    local function flushRow()
        local zc = z + rowDepth / 2
        local rowWidth = x - MODEL_PAD
        if rowWidth > widest then widest = rowWidth end
        for _, item in ipairs(row) do
            local pos = layoutToWorld(item.x - rowWidth / 2, zc, top + SPAWN_HEIGHT)
            local data, f = item.data, item.f
            jobs[#jobs + 1] = function() spawnModel(data, pos, memo, f) end
        end
        z = z + rowDepth + ROW_GAP
        x, rowDepth, row = 0, 0, {}
    end

    for _, item in ipairs(items) do
        local w, d = item.w or 1.5, item.d or 1.5
        if #row > 0 and x + w > MAX_ROW_WIDTH then flushRow() end
        row[#row + 1] = {data = item.data, f = item.f, x = x + w / 2}
        x = x + w + MODEL_PAD
        if d > rowDepth then rowDepth = d end
    end
    if #row > 0 then flushRow() end

    -- The platform covers the label (estimated at ~0.5" per character) and the widest row.
    local depth = z - ROW_GAP + PLATFORM_MARGIN - blockStart
    local width = math.max(widest, #label * 0.5) + 2 * PLATFORM_MARGIN
    local platformPos = layoutToWorld(0, blockStart + depth / 2, top - PLATFORM_THICKNESS / 2)
    queue[#queue + 1] = function()
        spawnPlatform(platformPos, width, depth, memo)
        return 5   -- let the platform exist and be scaled before models drop onto it
    end
    for _, job in ipairs(jobs) do queue[#queue + 1] = job end

    cursorZ = blockStart + depth + BLOCK_GAP
    spawned[key] = true
    saveState()
end

local function queueUnit(f, unit, entries)
    local items = {}
    for _, e in ipairs(entries) do items[#items + 1] = {data = e.data, w = e.w, d = e.d, f = f} end
    queueBlock(unitKey(f, unit.id), unit.name .. " (" .. #entries .. ")", items)
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

-- ============ WARBAND IMPORT ============
-- Trench Companion's TTS export: warband-name and models[], each with model-id (e.g.
-- md_lieutenant_eire = base "lieutenant", variant "eire"), name, stats and rule lists.

local function normName(s) return (string.gsub(string.lower(s), "[^a-z0-9]", "")) end

-- model-id -> {f=, unit=}. Full ids from a unit's `companion` list win, then companion bases,
-- then the unit name with spaces and punctuation removed. Built from the catalog index, so
-- only units that have models can match.
local importFull, importBase = {}, {}
local function buildImportIndex()
    importFull, importBase = {}, {}
    for _, f in ipairs(index.factions) do
        for _, u in ipairs(f.units) do
            local hit = {f = f.id, unit = u}
            for _, c in ipairs(u.companion or {}) do
                if string.sub(c, 1, 3) == "md_" then importFull[c] = importFull[c] or hit
                else importBase[c] = importBase[c] or hit end
            end
            local n = normName(u.name)
            importBase[n] = importBase[n] or hit
        end
    end
end

local function matchModel(modelId)
    if importFull[modelId] then return importFull[modelId] end
    local base = string.sub(modelId, 4)                  -- strip "md_"
    local cut = string.find(base, "_", 1, true)
    if cut then base = string.sub(base, 1, cut - 1) end
    return importBase[base]
end

local function joinField(list, field)
    local out = {}
    for _, e in ipairs(list or {}) do out[#out + 1] = tostring(e[field]) end
    return table.concat(out, ", ")
end

-- Equipment details (range, keywords) by item name, from config/equipment.json. The export
-- only has names and types; this table was read from Trench Companion's battlekit pages.
local equipment = nil

-- How each equipment type is shown: symbol, colour, whether its range is listed, and the
-- order of the groups. Matches the stat blocks Niklas uses on his models.
local EQUIP_STYLE = {
    ["melee weapon"]  = {order = 1, symbol = "✞", color = "fa8231", range = true},
    ["ranged weapon"] = {order = 2, symbol = "⊕", color = "C966E5", range = true},
    ["equipment"]     = {order = 3, symbol = "✜", color = "f7b731"},
    ["shield"]        = {order = 4, symbol = "☩", color = "fa8231"},
    ["armour"]        = {order = 5, symbol = "☩", color = "b2b7be"},
    ["grenade"]       = {order = 6, symbol = "✢", color = "fa8231"},
    ["special"]       = {order = 7, symbol = "✜", color = "fa8231"},
}

local function upperList(list)
    local out = {}
    for _, k in ipairs(list or {}) do out[#out + 1] = string.upper(k) end
    return table.concat(out, ", ")
end

-- Nickname: the player's name, the model type, the stat line and the keywords.
local function nameBlock(m)
    return "[b]☩☩ " .. tostring(m.name or m["model-name"]) .. " ☩☩[/b]\n"
        .. "(" .. tostring(m["model-name"]) .. ")\n"
        .. "[b][89E1E3]" .. tostring(m["stat-move"]) .. "[-][/b] | [b][fa8231]Mel. " .. tostring(m["stat-melee"])
        .. "D[-][/b] | [b][C966E5]Ran. " .. tostring(m["stat-ranged"]) .. "D[-][/b] | [b][b2b7be]Arm. "
        .. tostring(m["stat-armour"]) .. "[-][/b]\n"
        .. joinField(m.keywords, "keyword-name")
end

-- Description: equipment grouped by type (with range and keywords from the equipment table),
-- then abilities and upgrades, then advancements and injuries.
local function describe(m)
    local items = {}
    for i, e in ipairs(m.equipment or {}) do
        local style = EQUIP_STYLE[e["equipment-type"]] or EQUIP_STYLE["equipment"]
        items[#items + 1] = {e = e, style = style, i = i}
    end
    table.sort(items, function(a, b)
        if a.style.order ~= b.style.order then return a.style.order < b.style.order end
        return a.i < b.i
    end)
    local lines = {}
    for _, it in ipairs(items) do
        local name = tostring(it.e["equipment-name"])
        lines[#lines + 1] = "[b][" .. it.style.color .. "]" .. it.style.symbol .. " " .. name .. "[-][/b]"
        local info = equipment and equipment[name]
        if info then
            local detail = {}
            if it.style.range and info.r then detail[#detail + 1] = info.r end
            if info.k then detail[#detail + 1] = upperList(info.k) end
            if #detail > 0 then lines[#lines + 1] = table.concat(detail, " | ") end
        end
    end
    -- A group of lists separated from what comes before by one blank line.
    -- parts = {{list, field, colour, symbol}, ...}
    local function group(parts)
        local first = true
        for _, p in ipairs(parts) do
            for _, x in ipairs(p[1] or {}) do
                if first and #lines > 0 then lines[#lines + 1] = "" end
                first = false
                lines[#lines + 1] = "[b][" .. p[3] .. "]" .. p[4] .. " " .. tostring(x[p[2]]) .. "[-][/b]"
            end
        end
    end
    group({{m.abilities, "ability-name", "0fb9b1", "✧"}, {m.upgrades, "upgrade-name", "618DF4", "✹"}})
    group({{m.advancements, "advancement-name", "20bf6b", "△"}})
    group({{m.injuries, "injury-name", "eb3b5a", "✖"}})
    return table.concat(lines, "\n")
end

-- Spawns a whole warband on one platform labelled with its name. Each warband member gets a
-- catalog model of its unit; copies of the same unit get different models where the catalog
-- has several. The subfaction filter applies to the selected faction's units. Mercenaries get
-- the warband's faction for their activation icon.
local function importWarband(warband, done)
    local members, missing, order = {}, {}, {}
    local factionVotes = {}
    for _, m in ipairs(warband.models or {}) do
        local hit = type(m["model-id"]) == "string" and matchModel(m["model-id"]) or nil
        if hit then
            members[#members + 1] = {m = m, hit = hit}
            if hit.f ~= "mercenaries" then factionVotes[hit.f] = (factionVotes[hit.f] or 0) + 1 end
        else
            local name = tostring(m["model-name"] or m["model-id"])
            if not missing[name] then order[#order + 1] = name end
            missing[name] = (missing[name] or 0) + 1
        end
    end
    local warbandFaction, best = sel.f, 0
    for f, n in pairs(factionVotes) do
        if n > best then warbandFaction, best = f, n end
    end

    -- Download each needed unit file once, then build the block.
    local units, seen = {}, {}
    for _, mb in ipairs(members) do
        local key = unitKey(mb.hit.f, mb.hit.unit.id)
        if not seen[key] then
            seen[key] = true
            units[#units + 1] = mb.hit
        end
    end
    local entriesByKey, i = {}, 0
    local function finish()
        local items, used = {}, {}
        for _, mb in ipairs(members) do
            local key = unitKey(mb.hit.f, mb.hit.unit.id)
            local list = {}
            for _, e in ipairs(entriesByKey[key] or {}) do
                -- The subfaction filter only means something for the selected faction's units.
                if mb.hit.f ~= sel.f or entryMatches(e) then list[#list + 1] = e end
            end
            if #list == 0 then list = entriesByKey[key] or {} end
            if #list > 0 then
                used[key] = (used[key] or 0) + 1
                local e = list[(used[key] - 1) % #list + 1]
                local data = JSON.decode(JSON.encode(e.data))   -- own copy: name/description differ
                data.Nickname = nameBlock(mb.m)
                data.Description = describe(mb.m)
                items[#items + 1] = {data = data, w = e.w, d = e.d, f = warbandFaction}
            end
        end
        if #items > 0 then
            local name = tostring(warband["warband-name"] or "Warband")
            queueBlock("warband/" .. tostring(warband["warband-id"] or name), name, items)
        end
        flushQueue(function() done(#items, order, missing) end)
    end
    local function nextUnit()
        i = i + 1
        local hit = units[i]
        if not hit then
            if equipment then finish() return end
            -- Equipment details for the descriptions; without them only names are shown.
            WebRequest.get(RAW_BASE .. "config/equipment.json?v=" .. tostring(index.version), function(req)
                local ok, data = pcall(JSON.decode, req.text or "")
                if not req.is_error and ok and type(data) == "table" then equipment = data end
                finish()
            end)
            return
        end
        setStatus("Loading " .. hit.unit.name .. "...")
        fetchUnit(hit.unit, function(entries)
            entriesByKey[unitKey(hit.f, hit.unit.id)] = entries
            nextUnit()
        end)
    end
    nextUnit()
end

-- Destroys one unit's objects from this spawner (key), or with key nil every TC spawned
-- object on the table, whichever spawner made it. Clearing everything also catches models
-- left behind by an older copy of this spawner (e.g. after pasting a new script).
-- A spawned model that a player has taken off its platform is theirs now: clearing leaves
-- it alone and removes the spawn tag, so later clears don't touch it either.
local function standsOnPlatform(obj)
    local p = obj.getPosition()
    local hits = Physics.cast({origin = {p.x, p.y + 0.5, p.z}, direction = {0, -1, 0}, type = 1, max_distance = 3})
    for _, hit in ipairs(hits) do
        if hit.hit_object ~= obj and hit.hit_object.getName() == PLATFORM_NAME then return true end
    end
    return false
end

local function clearSpawned(key, done)
    local wanted = key and (token .. "|" .. key) or nil
    local count = 0
    for _, obj in ipairs(spawnedObjects()) do
        if not wanted or obj.memo == wanted then
            local isModel = obj.getName() ~= PLATFORM_NAME and obj.name ~= "3DText"
            if isModel and not standsOnPlatform(obj) then
                obj.removeTag(SPAWN_TAG)
                obj.memo = ""
            else
                count = count + 1
                queue[#queue + 1] = function()
                    if obj ~= nil then obj.destruct() end   -- destroyed objects compare equal to nil
                end
            end
        end
    end
    if key then spawned[key] = nil else spawned = {} end
    if next(spawned) == nil then cursorZ = 0 end   -- rows are not compacted, only reset when empty
    saveState()
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
    buildImportIndex()
    if not factionById[sel.f] then sel.f, sel.sub = data.factions[1].id, nil end
    setStatus("Catalog version " .. tostring(data.version) .. " loaded.")
    render()
    -- The model script is fetched with a timestamp: it can change without a catalog update.
    WebRequest.get(RAW_BASE .. "tts/model.lua?v=" .. os.time(), function(req)
        if req.is_error or (req.response_code and req.response_code >= 400) or not req.text then
            modelScript = nil
            setStatus("Catalog loaded, but the model script could not be loaded: models spawn without it.")
            return
        end
        modelScript = req.text
    end)
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
    if busy then setStatus("Still busy, try again in a moment.") return end
    if not index then return end
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
    if busy then setStatus("Still busy, try again in a moment.") return end
    if not index then return end
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
    if busy then setStatus("Still busy, try again in a moment.") return end
    busy = true
    clearSpawned(nil, function(n)
        busy = false
        setStatus("Removed " .. n .. " object(s).")
        render()
    end)
end

function ui_reload() loadCatalog() end

function ui_importOpen()
    if busy then setStatus("Still busy, try again in a moment.") return end
    importing, importText = true, ""
    setStatus("Paste the export, then press Import.")
end

function ui_importCancel()
    importing, importText = false, ""
    setStatus("Import cancelled.")
end

function ui_importText(player, value) importText = value or "" end

function ui_importGo()
    if busy then return end
    local ok, warband = pcall(JSON.decode, importText)
    if not ok or type(warband) ~= "table" or type(warband.models) ~= "table" then
        setStatus("That doesn't look like a Trench Companion TTS export (no models found).")
        return
    end
    importing, importText, busy = false, "", true
    importWarband(warband, function(n, order, missing)
        busy = false
        local text = "Imported " .. n .. " model(s) of " .. tostring(warband["warband-name"]) .. "."
        if #order > 0 then
            local parts = {}
            for _, name in ipairs(order) do parts[#parts + 1] = name .. (missing[name] > 1 and (" x" .. missing[name]) or "") end
            text = text .. " Not in the catalog yet: " .. table.concat(parts, ", ")
        end
        setStatus(text)
    end)
end

function ui_toggleScripts()
    scriptsOn = not scriptsOn
    saveState()
    render()
end

local function callOnModels(fn)
    local n = 0
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag(MODEL_TAG) then
            obj.call(fn)
            n = n + 1
        end
    end
    return n
end

function ui_readyAll() setStatus("Readied " .. callOnModels("readyActivation") .. " model(s).") end
function ui_saveAll() setStatus("Saved positions of " .. callOnModels("savePosition") .. " model(s).") end
function ui_loadAll() setStatus("Moved " .. callOnModels("loadPosition") .. " model(s) back.") end

function ui_toggleArea()
    showArea = not showArea
    saveState()
    render()
end

-- ============ SAVE / LOAD ============
function onSave()
    return JSON.encode({token = token, cursorZ = cursorZ, layoutEdge = layoutEdge, f = sel.f, sub = sel.sub,
                        showArea = showArea, scriptsOn = scriptsOn})
end

-- Each step runs protected and reports its name, so a failure in TTS says where it happened
-- instead of a bare "Object reference not set to an instance of an object".
local function step(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        status = "Error in " .. name .. ": " .. tostring(err)
        print("[TC Spawner] " .. status)
        render()
    end
    return ok
end

function onLoad(saved_data)
    step("reading saved state", function()
        if saved_data and saved_data ~= "" then
            local data = JSON.decode(saved_data)
            if type(data) == "table" then
                token, cursorZ, layoutEdge = data.token, data.cursorZ or 0, data.layoutEdge
                sel.f, sel.sub = data.f, data.sub
                if data.showArea == false then showArea = false end
                if data.scriptsOn == false then scriptsOn = false end
            end
        end
    end)
    if not token then
        math.randomseed(os.time())
        token = "tcm" .. os.time() .. math.random(100000, 999999)
        saveState()
    end
    render()

    -- Other objects may still be loading during onLoad; look at them a frame later.
    Wait.frames(function()
        step("finding spawned models", function()
            -- Rebuild which units are on the table from the spawned objects themselves.
            local prefix = token .. "|"
            for _, obj in ipairs(spawnedObjects()) do
                local memo = obj.memo or ""
                if string.find(memo, prefix, 1, true) == 1 then spawned[string.sub(memo, #prefix + 1)] = true end
            end
            if next(spawned) == nil then cursorZ = 0 end
        end)
        step("loading the catalog", loadCatalog)
    end, 1)
end
