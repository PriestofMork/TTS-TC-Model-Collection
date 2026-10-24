-- =============================================
-- TC MINIATURES - INTAKE STATION (dev save only)
-- =============================================
-- Put this on a flat object (e.g. a scaled Custom Tile or Block). Drop models into the
-- outlined zone in front of it, pick faction / unit / subfactions, press Submit.
-- Each model gets a {"tc":1,...} tag in its GM Notes, foreign scripts/UI are stripped,
-- and it goes into a per-unit storage bag next to the station. tools/export.py then
-- reads the save (including bag contents) and writes catalog/.
--
-- Storage uses one bag per unit instead of a grid on the table: ~2800 models laid out
-- at once would make the dev save very heavy, and bags keep each unit easy to re-check.

-- ===================== CONFIG =====================
local RAW_BASE  = "https://raw.githubusercontent.com/PriestofMork/TTS-TC-Model-Collection/main/"
local UNITS_URL = RAW_BASE .. "config/units.json"

-- Paste the contents of config/units.json here (as a [[long string]]) to work offline or
-- before the repo is pushed. nil = fetch from GitHub on load / Reload.
local LOCAL_UNITS_JSON = nil

-- All offsets/sizes are world units relative to the station; they follow its position and
-- rotation but NOT its scale. Local -z is the side a player reading the panel stands on.
local ZONE_SIZE   = {x = 12, y = 6, z = 10}
local ZONE_OFFSET = {x = 0, z = -9}
local BAG_OFFSET  = {x = 12, z = 0}   -- first storage bag
local BAG_SPACING = 2.5
local BAGS_PER_ROW = 10

-- TTS object names that count as models. Custom_Model has a CustomMesh; some source mods
-- use asset bundles or image figurines instead.
local MODEL_NAMES = {Custom_Model = true, Custom_Assetbundle = true, Figurine_Custom = true}

local BATCH_SIZE = 10   -- models moved into a bag per frame

-- Object XML UI is positioned from the object's centre; its z is height (negative = up) in
-- UI units (100 per local unit). The panel is lifted to the top face automatically, plus
-- this margin in UI units.
local UI_MARGIN = 5
local UI_SCALE  = 1

local COLOR_NEW   = {0.2, 1, 0.2}
local COLOR_RETAG = {1, 0.8, 0.1}
local COLOR_BAD   = {1, 0.2, 0.2}
-- ==================================================

local config       = nil        -- decoded units.json
local factionIndex = {}         -- faction id -> {faction=, index=, units={id->unit}, unitIndex={id->n}, subs={id->sub}}
local sel          = {f = nil, u = nil, s = {}}   -- s is a set: subfaction id -> true
local status       = "Loading config..."
local busy         = false
local renderPending = false
local highlighted  = {}
local bagGuids     = {}         -- "f/u" -> guid; cache only, bags are identified by their GM Notes marker
local dropToken    = 0

-- ============ UTIL ============
local function round(num, dec)
    local mult = 10 ^ (dec or 0)
    return math.floor(num * mult + 0.5) / mult
end

local function xmlEscape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function sortedKeys(set)
    local list = {}
    for k in pairs(set) do list[#list + 1] = k end
    table.sort(list)
    return list
end

-- World offset (x, z) relative to the station -> world position. positionToWorld works in
-- local (scaled) units, so divide by scale to keep offsets in world units.
local function toWorld(x, z)
    local s = self.getScale()
    return self.positionToWorld(Vector(x / s.x, 0, z / s.z))
end

-- Panel z that puts the UI just above the object's top face, whatever its shape and scale.
-- getBoundsNormalized ignores rotation but includes scale, so divide scale out to get local units.
local function uiHeight()
    local halfLocal = self.getBoundsNormalized().size.y / 2 / self.getScale().y
    return -math.ceil(halfLocal * 100 + UI_MARGIN)
end

local function tableY()
    local b = self.getBounds()
    return b.center.y - b.size.y / 2
end

local function clearHighlights()
    for _, obj in ipairs(highlighted) do
        if obj ~= nil then obj.highlightOff() end   -- destroyed objects compare equal to nil
    end
    highlighted = {}
end

local function highlight(obj, color)
    obj.highlightOn(color)
    highlighted[#highlighted + 1] = obj
end

-- ============ TAGS ============
-- GM Notes of source-mod objects can contain anything, so do a cheap plain find before decoding.
local function parseTag(notes)
    if not notes or notes == "" or not string.find(notes, '"tc"', 1, true) then return nil end
    local ok, t = pcall(JSON.decode, notes)
    if ok and type(t) == "table" and t.tc == 1 then return t end
    return nil
end

local function parseBagMarker(notes)
    if not notes or not string.find(notes, '"tcbag"', 1, true) then return nil end
    local ok, t = pcall(JSON.decode, notes)
    if ok and type(t) == "table" and t.tcbag == 1 then return t end
    return nil
end

local function tagValid(t)
    local fe = config and factionIndex[t.f]
    if not fe or not fe.units[t.u] then return false end
    for _, sid in ipairs(t.s or {}) do
        if not fe.subs[sid] then return false end
    end
    return true
end

local function tagLabel(f, u, subs)
    local fe = factionIndex[f]
    local fname = fe and fe.faction.name or tostring(f)
    local uname = (fe and fe.units[u]) and fe.units[u].name or tostring(u)
    local label = fname .. " / " .. uname
    if subs and #subs > 0 then
        local names = {}
        for _, sid in ipairs(subs) do
            names[#names + 1] = (fe and fe.subs[sid]) and fe.subs[sid].name or tostring(sid)
        end
        label = label .. " [" .. table.concat(names, ", ") .. "]"
    else
        label = label .. " (any subfaction)"
    end
    return label
end

-- ============ STATUS / UI ============
local render

-- Status is part of the XML, so changing it re-renders the panel. Calling self.UI.setValue
-- instead throws a null-reference error while the panel doesn't exist yet (e.g. in onLoad).
local function setStatus(text)
    status = text
    render()
end

-- The panel's height is the sum of its rows, so it grows with the unit list.
local function buildXml()
    local x, height = {}, 24   -- 24 = top + bottom padding
    local function add(s) x[#x + 1] = s end
    local function row(h, s)
        height = height + h + 6   -- 6 = layout spacing
        add(s)
    end

    row(30, '<Text preferredHeight="30" fontSize="22" fontStyle="Bold">TC Intake</Text>')

    if config then
        local fe = factionIndex[sel.f]

        local opts = {}
        for _, f in ipairs(config.factions) do
            opts[#opts + 1] = '<Option' .. (f.id == sel.f and ' selected="true"' or '') .. '>' .. xmlEscape(f.name) .. '</Option>'
        end
        row(40, '<Dropdown id="faction" preferredHeight="40" onValueChanged="ui_faction">' .. table.concat(opts) .. '</Dropdown>')

        -- Units as buttons (three per row): switching unit is the most frequent action, and a
        -- dropdown needs scrolling for long lists. The selected unit is green.
        row(24, '<Text preferredHeight="24" alignment="MiddleLeft">Unit</Text>')
        local units = fe.faction.units
        local unitRows = math.ceil(#units / 3)
        local b = {}
        for _, u in ipairs(units) do
            b[#b + 1] = '<Button id="u:' .. xmlEscape(u.id) .. '" onClick="ui_unit" fontSize="14"'
                .. (u.id == sel.u and ' colors="#3A7A3A|#4A9A4A|#2A5A2A|#555555" textColor="#FFFFFF"' or '')
                .. '>' .. xmlEscape(u.name) .. '</Button>'
        end
        row(unitRows * 38, '<GridLayout cellSize="160 34" spacing="4 4" preferredHeight="' .. (unitRows * 38) .. '">'
            .. table.concat(b) .. '</GridLayout>')

        row(24, '<Text preferredHeight="24" alignment="MiddleLeft">Subfactions (none = any)</Text>')
        local subs = fe.faction.subfactions or {}
        if #subs == 0 then
            row(26, '<Text preferredHeight="26" alignment="MiddleLeft" color="#AAAAAA">This faction has no subfactions.</Text>')
        else
            local t, subRows = {}, math.ceil(#subs / 2)
            for _, sf in ipairs(subs) do
                t[#t + 1] = '<Toggle id="sub:' .. xmlEscape(sf.id) .. '" isOn="' .. (sel.s[sf.id] and 'true' or 'false')
                    .. '" onValueChanged="ui_sub">' .. xmlEscape(sf.name) .. '</Toggle>'
            end
            row(subRows * 34, '<GridLayout cellSize="240 30" spacing="4 4" preferredHeight="' .. (subRows * 34) .. '">'
                .. table.concat(t) .. '</GridLayout>')
        end

        row(44, '<HorizontalLayout preferredHeight="44" spacing="6">'
            .. '<Button onClick="ui_preview">Preview</Button>'
            .. '<Button onClick="ui_submit" colors="#3A7A3A|#4A9A4A|#2A5A2A|#555555" textColor="#FFFFFF">Submit</Button>'
            .. '<Button onClick="ui_clear">Clear</Button></HorizontalLayout>')
    end

    row(36, '<HorizontalLayout preferredHeight="36" spacing="6">'
        .. (config and '<Button onClick="ui_unsorted" fontSize="16">Check unsorted</Button>' or '')
        .. '<Button onClick="ui_reload" fontSize="16">Reload config</Button></HorizontalLayout>')

    -- Activation tokens: every unlocked object in the zone (tokens can be tiles or custom
    -- models) is tagged for the selected faction or as the general token. They stay where they
    -- are; export reads them.
    if config then
        row(36, '<HorizontalLayout preferredHeight="36" spacing="6">'
            .. '<Button onClick="ui_tokenFaction" fontSize="15">Activation token: this faction</Button>'
            .. '<Button onClick="ui_tokenGeneral" fontSize="15">Activation token: general</Button></HorizontalLayout>')
    end

    row(160, '<Text preferredHeight="160" fontSize="16" alignment="UpperLeft">' .. xmlEscape(status) .. '</Text>')

    return '<Defaults><Text fontSize="18" color="#FFFFFF"/><Button fontSize="18"/>'
        .. '<Toggle fontSize="16" textColor="#FFFFFF"/><Dropdown fontSize="18"/></Defaults>'
        .. '<Panel position="0 0 ' .. uiHeight() .. '" rotation="0 0 180" width="520" height="' .. height
        .. '" scale="' .. UI_SCALE .. ' ' .. UI_SCALE .. ' 1" color="#1A1A1AEE">'
        .. '<VerticalLayout padding="12 12 12 12" spacing="6" childForceExpandHeight="false">'
        .. table.concat(x) .. '</VerticalLayout></Panel>'
end

-- Coalesce several render() calls in one frame into a single setXml.
function render()   -- assigns the local declared above setStatus
    if renderPending then return end
    renderPending = true
    Wait.frames(function()
        renderPending = false
        self.UI.setXml(buildXml())
    end, 1)
end

-- Outline of the intake zone, drawn with vector lines in the station's local (scaled) space.
local function drawZone()
    local s, p = self.getScale(), self.getPosition()
    local ly = (tableY() + 0.05 - p.y) / s.y
    local hx, hz = ZONE_SIZE.x / 2, ZONE_SIZE.z / 2
    local function corner(dx, dz)
        return {(ZONE_OFFSET.x + dx) / s.x, ly, (ZONE_OFFSET.z + dz) / s.z}
    end
    self.setVectorLines({{
        points    = {corner(-hx, -hz), corner(hx, -hz), corner(hx, hz), corner(-hx, hz), corner(-hx, -hz)},
        color     = COLOR_NEW,
        thickness = 0.05,
    }})
end

-- ============ CONFIG ============
local function applyConfig(text)
    local ok, data = pcall(JSON.decode, text)
    if not ok or type(data) ~= "table" or type(data.factions) ~= "table" or #data.factions == 0 then
        config = nil
        setStatus("units.json could not be parsed (no factions).")
        render()
        return
    end

    config, factionIndex = data, {}
    for fi, f in ipairs(data.factions) do
        local fe = {faction = f, index = fi, units = {}, unitIndex = {}, subs = {}}
        for ui, u in ipairs(f.units or {}) do
            fe.units[u.id] = u
            fe.unitIndex[u.id] = ui
        end
        for _, s in ipairs(f.subfactions or {}) do fe.subs[s.id] = s end
        f.units = f.units or {}
        factionIndex[f.id] = fe
    end

    -- Keep the saved selection only where it still exists in the config.
    if not factionIndex[sel.f] then sel.f, sel.u, sel.s = data.factions[1].id, nil, {} end
    local fe = factionIndex[sel.f]
    if sel.u and not fe.units[sel.u] then sel.u = nil end
    for sid in pairs(sel.s) do
        if not fe.subs[sid] then sel.s[sid] = nil end
    end

    setStatus("Config loaded: " .. #data.factions .. " faction(s). Drop models into the zone.")
    render()
end

local function loadConfig()
    if LOCAL_UNITS_JSON then
        applyConfig(LOCAL_UNITS_JSON)
        return
    end
    setStatus("Loading config...")
    -- raw.githubusercontent.com caches for minutes; the query string busts it.
    WebRequest.get(UNITS_URL .. "?v=" .. os.time(), function(req)
        if req.is_error or (req.response_code and req.response_code >= 400) then
            config = nil
            setStatus("Could not load units.json (" .. tostring(req.error or req.response_code) .. ").\n"
                .. "Push the repo or paste it into LOCAL_UNITS_JSON, then press Reload config.")
            render()
            return
        end
        applyConfig(req.text)
    end)
end

-- ============ ZONE ============
-- Returns {obj=, tag=} for every model in the zone, how many other objects were ignored, and
-- those other (unlocked) objects themselves, for tagging activation tokens.
local function scanZone()
    local origin = toWorld(ZONE_OFFSET.x, ZONE_OFFSET.z)
    origin.y = tableY() + ZONE_SIZE.y / 2
    local hits = Physics.cast({
        origin       = origin,
        direction    = {0, 1, 0},
        type         = 3,   -- box
        size         = {ZONE_SIZE.x, ZONE_SIZE.y, ZONE_SIZE.z},
        orientation  = self.getRotation(),
        max_distance = 0.01,   -- overlap check; objects inside the box at the start are reported
    })

    local items, ignored, seen, others = {}, 0, {}, {}
    for _, hit in ipairs(hits) do
        local obj = hit.hit_object
        if obj and obj ~= self and not seen[obj.getGUID()] then
            seen[obj.getGUID()] = true
            -- Locked objects are scenery/table parts: anything dragged in is unlocked.
            if MODEL_NAMES[obj.name] and not obj.getLock() then
                items[#items + 1] = {obj = obj, tag = parseTag(obj.getGMNotes())}
            elseif obj.name ~= "Table_Custom" and obj.type ~= "Surface" then
                ignored = ignored + 1
                if not obj.getLock() then others[#others + 1] = obj end
            end
        end
    end
    return items, ignored, others
end

local function selectionLabel()
    if not sel.u then return nil end
    return tagLabel(sel.f, sel.u, sortedKeys(sel.s))
end

-- Highlights the zone contents and describes them. autoSelect (from a drop) implements the
-- re-tag flow: if everything in the zone carries the same valid tag, load it into the menu.
local function preview(autoSelect, droppedObj)
    if not config or busy then return end
    local items, ignored = scanZone()

    if droppedObj then
        local found = false
        for _, it in ipairs(items) do
            if it.obj == droppedObj then found = true break end
        end
        if not found then return end
    end

    clearHighlights()
    local tagged, groups, order, invalid = 0, {}, {}, 0
    for _, it in ipairs(items) do
        if it.tag then
            tagged = tagged + 1
            if not tagValid(it.tag) then invalid = invalid + 1 end
            local label = tagLabel(it.tag.f, it.tag.u, it.tag.s)
            if not groups[label] then groups[label] = 0; order[#order + 1] = label end
            groups[label] = groups[label] + 1
            highlight(it.obj, tagValid(it.tag) and COLOR_RETAG or COLOR_BAD)
        else
            highlight(it.obj, COLOR_NEW)
        end
    end

    if autoSelect and #items > 0 and tagged == #items and #order == 1 and invalid == 0 then
        local t = items[1].tag
        sel.f, sel.u, sel.s = t.f, t.u, {}
        for _, sid in ipairs(t.s or {}) do sel.s[sid] = true end
        render()
    end

    local lines = {}
    lines[#lines + 1] = "Zone: " .. #items .. " model(s)" .. (ignored > 0 and (", " .. ignored .. " other object(s) ignored") or "") .. "."
    if tagged > 0 then
        lines[#lines + 1] = "Already tagged (yellow, red = invalid):"
        for i, label in ipairs(order) do
            if i > 6 then lines[#lines + 1] = "  ..." break end
            lines[#lines + 1] = "  " .. groups[label] .. "x " .. label
        end
    end
    local target = selectionLabel()
    lines[#lines + 1] = target and ("Submit tags as: " .. target) or "Choose a unit before submitting."
    setStatus(table.concat(lines, "\n"))
end

-- ============ STORAGE BAGS ============
local function findBag(f, u)
    local key = f .. "/" .. u
    local cached = bagGuids[key] and getObjectFromGUID(bagGuids[key])
    if cached then
        local m = parseBagMarker(cached.getGMNotes())
        if m and m.f == f and m.u == u then return cached end
    end
    for _, obj in ipairs(getAllObjects()) do
        local m = parseBagMarker(obj.getGMNotes())
        if m and m.f == f and m.u == u then
            bagGuids[key] = obj.getGUID()
            return obj
        end
    end
    return nil
end

local function bagPosition(f, u)
    local fe = factionIndex[f]
    local n = (fe.unitIndex[u] or 1) - 1
    local col, row = n % BAGS_PER_ROW, math.floor(n / BAGS_PER_ROW)
    local rowsPerFaction = math.ceil(#fe.faction.units / BAGS_PER_ROW) + 1
    local z = BAG_OFFSET.z + ((fe.index - 1) * rowsPerFaction + row) * BAG_SPACING
    local pos = toWorld(BAG_OFFSET.x + col * BAG_SPACING, z)
    pos.y = tableY() + 2
    return pos
end

local function ensureBag(f, u, callback)
    local bag = findBag(f, u)
    if bag then callback(bag) return end
    spawnObject({
        type     = "Bag",
        position = bagPosition(f, u),
        rotation = {0, self.getRotation().y, 0},
        callback_function = function(newBag)
            local fe = factionIndex[f]
            newBag.setName("TCM: " .. fe.faction.name .. " / " .. fe.units[u].name)
            newBag.setGMNotes(JSON.encode({tcbag = 1, f = f, u = u}))
            newBag.setLock(true)   -- locked bags still accept putObject
            bagGuids[f .. "/" .. u] = newBag.getGUID()
            callback(newBag)
        end,
    })
end

-- ============ SUBMIT ============
local function tagObject(obj, f, u, subs)
    -- Bounds are not in the save JSON; the spawner needs the footprint before models load.
    local size = obj.getBounds().size
    obj.setGMNotes(JSON.encode({tc = 1, f = f, u = u, s = subs, w = round(size.x, 2), d = round(size.z, 2)}))
    -- Only the stored script changes here; the running copy dies when the object enters the bag.
    obj.setLuaScript("")
    obj.script_state = ""
    obj.clearButtons()
    obj.clearInputs()
    obj.UI.setXml("")
    obj.highlightOff()
end

local function submit()
    if busy then return end
    if not config then setStatus("No config loaded.") return end
    if not sel.u then setStatus("Choose a unit before submitting.") return end

    local items = scanZone()
    if #items == 0 then setStatus("No models in the zone.") return end

    busy = true
    clearHighlights()
    local f, u, subs = sel.f, sel.u, sortedKeys(sel.s)
    local label = tagLabel(f, u, subs)
    local total = #items
    setStatus("Tagging " .. total .. " model(s) as " .. label .. "...")

    ensureBag(f, u, function(bag)
        local function step()
            for _ = 1, BATCH_SIZE do
                -- MoonSharp's table.remove throws on an empty table (standard Lua returns nil).
                if #items == 0 then break end
                local it = table.remove(items, 1)
                if it.obj ~= nil then
                    tagObject(it.obj, f, u, subs)
                    bag.putObject(it.obj)
                end
            end
            if #items > 0 then
                Wait.frames(step, 1)
            else
                busy = false
                setStatus("Tagged " .. total .. " model(s) as " .. label .. "\nStored in bag: " .. bag.getName())
            end
        end
        step()
    end)
end

-- ============ UNSORTED CHECK ============
-- Loose models outside the zone without a valid tag, and bag contents whose tag is missing,
-- invalid or for a different unit than the bag.
local function checkUnsorted()
    if not config or busy then return end
    clearHighlights()

    local inZone = {}
    for _, it in ipairs(scanZone()) do inZone[it.obj.getGUID()] = true end

    local loose, problems = 0, {}
    for _, obj in ipairs(getAllObjects()) do
        if MODEL_NAMES[obj.name] and not inZone[obj.getGUID()] then
            local t = parseTag(obj.getGMNotes())
            if not t or not tagValid(t) then
                loose = loose + 1
                highlight(obj, COLOR_BAD)
            end
        else
            local m = parseBagMarker(obj.getGMNotes())
            if m then
                local untagged, wrong = 0, 0
                for _, entry in ipairs(obj.getObjects()) do
                    local t = parseTag(entry.gm_notes)
                    if not t or not tagValid(t) then
                        untagged = untagged + 1
                    elseif t.f ~= m.f or t.u ~= m.u then
                        wrong = wrong + 1
                    end
                end
                if untagged + wrong > 0 then
                    problems[#problems + 1] = obj.getName() .. ": " .. untagged .. " untagged/invalid, " .. wrong .. " wrong unit"
                end
            end
        end
    end

    local lines = {"Loose untagged models: " .. loose .. (loose > 0 and " (highlighted red)" or "")}
    if #problems == 0 then
        lines[#lines + 1] = "All storage bags OK."
    else
        for i, p in ipairs(problems) do
            if i > 8 then lines[#lines + 1] = "..." break end
            lines[#lines + 1] = p
        end
    end
    setStatus(table.concat(lines, "\n"))
end

-- ============ UI CALLBACKS ============
-- XML UI passes (player, value, id). Dropdown value is the selected option's text.
function ui_faction(player, value)
    for _, f in ipairs(config.factions) do
        if f.name == value and f.id ~= sel.f then
            sel.f, sel.u, sel.s = f.id, nil, {}
            render()
            break
        end
    end
end

-- Unit buttons have id "u:<unit id>".
function ui_unit(player, value, id)
    sel.u = string.sub(id, 3)
    render()   -- highlight the selected button
    preview(false)
end

function ui_sub(player, value, id)
    local sid = string.sub(id, 5)   -- strip "sub:"
    sel.s[sid] = (value == "True") or nil
    preview(false)
end

function ui_preview() preview(false) end
function ui_submit() submit() end
function ui_unsorted() checkUnsorted() end

local function tagActivationTokens(f)
    if busy or not config then return end
    local items, _, others = scanZone()
    for _, it in ipairs(items) do others[#others + 1] = it.obj end
    clearHighlights()
    for _, obj in ipairs(others) do
        obj.setGMNotes(JSON.encode({tcm = "activation", f = f}))
        highlight(obj, COLOR_RETAG)
    end
    if #others == 0 then
        setStatus("Put the activation token into the zone first.")
    else
        setStatus("Tagged " .. #others .. " object(s) as activation token for '" .. f .. "'. Leave them in the save; export picks them up.")
    end
end

function ui_tokenFaction() tagActivationTokens(sel.f) end
function ui_tokenGeneral() tagActivationTokens("general") end
function ui_reload() loadConfig() end

function ui_clear()
    sel.u, sel.s = nil, {}
    clearHighlights()
    status = "Selection cleared."
    render()
end

-- ============ EVENTS ============
-- Global event, also delivered to object scripts. Debounced so dropping a stack of
-- models triggers one preview.
function onObjectDrop(player_color, obj)
    if busy or not config or obj == nil or not MODEL_NAMES[obj.name] then return end
    dropToken = dropToken + 1
    local token = dropToken
    Wait.time(function()
        if token == dropToken and obj ~= nil then preview(true, obj) end
    end, 0.5)
end

function onSave()
    return JSON.encode({sel = {f = sel.f, u = sel.u, s = sortedKeys(sel.s)}})
end

function onLoad(saved_data)
    if saved_data and saved_data ~= "" then
        local ok, data = pcall(JSON.decode, saved_data)
        if ok and type(data) == "table" and data.sel then
            sel.f, sel.u, sel.s = data.sel.f, data.sel.u, {}
            for _, sid in ipairs(data.sel.s or {}) do sel.s[sid] = true end
        end
    end
    drawZone()
    render()
    loadConfig()
end
