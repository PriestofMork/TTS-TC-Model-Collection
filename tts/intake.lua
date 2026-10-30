-- =============================================
-- TC MINIATURES - INTAKE STATION (dev save only)
-- =============================================
-- Sorting board for the maintainer. Choose a faction and press Open board: the station lays
-- out a grid to its right, one column per unit (leader first, then the mercenaries the faction
-- can hire) and
-- two rows per context (Vanilla, then each subfaction; each with General and Import), and takes
-- every catalogued model of that faction out of its storage bag into its cell. Add new models
-- by dropping them into a cell, retag by moving them, destroy them via the Discard strip.
-- Close board tags every model by the cell it lies in, strips foreign scripts and puts it back
-- into its unit bag. tools/export.py then reads the save (including bag contents).
--
-- One object = one cell. A model that belongs in several cells is copied, one copy per cell
-- (export merges copies of the same model within a unit). Tags written by the board:
--   General, Vanilla        {"s":[]}                    no subfaction theme
--   General, subfaction C   {"s":[C]}                   made for C
--   Import, context X       {"s":[],"i":[X],"k":"i"}    preferred pick for X's warband imports;
--                                                       k = "i": s carries no theme
-- A model that sits only in Import rows (no General copy) also counts as General for those
-- contexts (export applies this when merging), so moving a model into an Import row is enough;
-- copy it only to keep it under another theme too (e.g. vanilla Azebs picked for a subfaction).
-- X is "_" (vanilla) or a subfaction id. A faction's mercenaries use the faction id instead of
-- "_" (Heretic Legion's vanilla pick of Goetic Warlocks: i = ["heretic-legion"]); "_" on a
-- mercenary is the Mercenaries board's own vanilla pick. Older tags with several entries are
-- split into copies when their board opens.
--
-- Storage stays one bag per unit: ~2800 models laid out at once would make the dev save very
-- heavy, and a board only takes out one faction.

-- ===================== CONFIG =====================
local RAW_BASE  = "https://raw.githubusercontent.com/PriestofMork/TTS-TC-Model-Collection/main/"
local UNITS_URL = RAW_BASE .. "config/units.json"

-- Paste the contents of config/units.json here (as a [[long string]]) to work offline or
-- before the repo is pushed. nil = fetch from GitHub on load / Reload.
local LOCAL_UNITS_JSON = nil

local MERC = "mercenaries"

-- Board layout, in world units relative to the station (its position and rotation when the
-- board was opened, not its scale). x runs to the right of a player standing on the station's
-- local +z side (where a panel with rotation "0 0 180" reads upright, tested on the spawner),
-- z away from them. The board lies right of the station (the bags are on its left), so the
-- columns read left to right from the faction's leader to its mercenaries; rows start level
-- with the station's front edge and grow away from the player.
local BOARD_GAP   = 3      -- between the station and the board's left edge
local ROW_LABEL_W = 8      -- column of row labels on the board's left (next to the station)
local HEADER_D    = 2.5    -- row of column labels nearest to the player
local CELL_GAP    = 0.5    -- between cells
local CELL_PAD    = 0.3    -- around and between models in a cell
local MIN_COL_W   = 6
local MAX_COL_W   = 24
local MIN_ROW_D   = 3
local SPARE_D     = 2      -- empty room at the far side of every row, for new models
local DISCARD_D   = 5      -- Discard strip beyond the last row
local TILE_THICKNESS = 0.1
local DEFAULT_SIZE   = 1.5 -- footprint of a model whose tag has no w/d

-- Yaw of models on the board (relative to the station) so they face the player, and of the
-- flat 3D text labels so they read upright from the player's side. Same values as the
-- spawner, whose reader also stands on the +z side; change if they come out turned.
local MODEL_YAW   = 0
local LABEL_PITCH = 90
local LABEL_YAW   = 180
local LABEL_FONT  = 32

local COLOR_GENERAL = {0.18, 0.18, 0.18}
local COLOR_IMPORT  = {0.12, 0.22, 0.15}
local COLOR_DISCARD = {0.4, 0.08, 0.08}
local COLOR_HEADER  = {0.08, 0.08, 0.08}

local BAG_OFFSET   = {x = 12, z = 0}   -- first storage bag (local +x: the player's left)
local BAG_SPACING  = 2.5
local BAGS_PER_ROW = 10

-- TTS object names that count as models. Custom_Model has a CustomMesh; some source mods
-- use asset bundles or image figurines instead.
local MODEL_NAMES = {Custom_Model = true, Custom_Assetbundle = true, Figurine_Custom = true}
local BOARD_TAG   = "TCM_Board"         -- tiles and labels of the open board

local BATCH_SIZE = 10   -- objects taken out, stored or spawned per frame

-- Object XML UI is positioned from the object's centre; its z is height (negative = up) in
-- UI units (100 per local unit). The panel is lifted to the top face automatically, plus
-- this margin in UI units.
local UI_MARGIN = 5
local UI_SCALE  = 1

local COLOR_OK   = {0.2, 1, 0.2}
local COLOR_WARN = {1, 0.8, 0.1}
local COLOR_BAD  = {1, 0.2, 0.2}
-- ==================================================

local config       = nil        -- decoded units.json
local factionIndex = {}         -- faction id -> {faction=, index=, units={id->unit}, unitIndex={id->n}, subs={id->sub}}
local subOwner     = {}         -- subfaction id -> faction id
local sel          = {f = nil}  -- faction chosen in the dropdown
-- The open board (saved): f, frame = {x, y, z, yaw}, cols = {f, u, name, x0, x1}, rows =
-- {kind = "g"|"i", ctx = "_"|subfaction id, name, z0, z1}, discard = {z0, z1}, bounds.
local board        = nil
local status       = "Loading config..."
local busy         = false
local renderPending = false
local highlighted  = {}
local bagGuids     = {}         -- "f/u" -> guid; cache only, bags are identified by their GM Notes marker
local keyByGuid    = {}         -- model identity (see modelKey) of objects on the board
local pendingDrops = {}
local dropToken    = 0

-- ============ UTIL ============
local function round(num, dec)
    local mult = 10 ^ (dec or 0)
    return math.floor(num * mult + 0.5) / mult
end

local function xmlEscape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Wraps a short text at spaces into lines of at most `width` characters.
local function wrapWords(text, width)
    local lines, line = {}, ""
    for word in string.gmatch(tostring(text), "%S+") do
        if line ~= "" and #line + 1 + #word > width then
            lines[#lines + 1] = line
            line = word
        else
            line = (line == "" and word) or (line .. " " .. word)
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return table.concat(lines, "\n")
end

local function list(t) return type(t) == "table" and t or {} end

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

-- Board frame <-> world. The frame is stored when the board opens, so moving the station
-- afterwards doesn't shift the cells. The player faces the station's local -z, so board x
-- (their right) is local -x and board z (away) is local -z. Unity yaw turns local +z toward
-- world +x.
local function frameToWorld(x, z, y)
    local fr = board.frame
    local a = math.rad(fr.yaw)
    local c, s = math.cos(a), math.sin(a)
    local lx, lz = -x, -z
    return Vector(fr.x + lx * c + lz * s, y or fr.y, fr.z - lx * s + lz * c)
end

local function worldToFrame(p)
    local fr = board.frame
    local a = math.rad(fr.yaw)
    local c, s = math.cos(a), math.sin(a)
    local dx, dz = p.x - fr.x, p.z - fr.z
    return -(dx * c - dz * s), -(dx * s + dz * c)
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

local function isModel(obj)
    return obj ~= nil and MODEL_NAMES[obj.name] and not obj.getLock() and not obj.hasTag(BOARD_TAG)
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

-- s holds subfaction ids of any faction (a mercenary can be made for Knights of Avarice),
-- plus "_" (vanilla) in tags pulled from the catalog, where a model can be vanilla and themed
-- at once; i also allows "_" and faction ids (see the header).
local function tagValid(t)
    local fe = config and factionIndex[t.f]
    if not fe or not fe.units[t.u] then return false end
    for _, sid in ipairs(list(t.s)) do
        if sid ~= "_" and not subOwner[sid] then return false end
    end
    for _, x in ipairs(list(t.i)) do
        if x ~= "_" and not subOwner[x] and not factionIndex[x] then return false end
    end
    return true
end

-- What a tag says, as single memberships {kind = "g"|"i", ctx}: one per board cell (on some
-- board) the model belongs in.
local function membershipsOf(t)
    local out = {}
    if t.k ~= "i" then
        local s = list(t.s)
        if #s == 0 then out[#out + 1] = {kind = "g", ctx = "_"} end
        for _, sid in ipairs(s) do out[#out + 1] = {kind = "g", ctx = sid} end
    end
    for _, x in ipairs(list(t.i)) do out[#out + 1] = {kind = "i", ctx = x} end
    if #out == 0 then out[1] = {kind = "g", ctx = "_"} end
    return out
end

-- The tag of one membership.
local function membershipTag(f, u, m, w, d)
    local t = {tc = 1, f = f, u = u, s = {}, w = w, d = d}
    if m.kind == "g" then
        if m.ctx ~= "_" then t.s = {m.ctx} end
    else
        t.i, t.k = {m.ctx}, "i"
    end
    return t
end

-- Identity of a model for the duplicate check, like dedupe_key in tools/export.py: the
-- object's own asset URLs and scale plus all attached parts. Scale to 2 decimals: the catalog
-- rounds transforms, and Pull from catalog compares catalog models with the bags' ones.
local function partKey(d)
    local t = d.Transform or {}
    local sc = string.format("%.2f,%.2f,%.2f", t.scaleX or 1, t.scaleY or 1, t.scaleZ or 1)
    if d.CustomMesh then
        return "m|" .. tostring(d.CustomMesh.MeshURL) .. "|" .. tostring(d.CustomMesh.DiffuseURL) .. "|" .. sc
    elseif d.CustomAssetbundle then
        return "b|" .. tostring(d.CustomAssetbundle.AssetbundleURL) .. "|"
            .. tostring(d.CustomAssetbundle.AssetbundleSecondaryURL) .. "|" .. sc
    elseif d.CustomImage then
        return "i|" .. tostring(d.CustomImage.ImageURL) .. "|" .. sc
    end
    return ""
end

local modelKey
function modelKey(d)   -- assigns the local above (recursive)
    local parts = {}
    for _, c in ipairs(d.ChildObjects or {}) do parts[#parts + 1] = modelKey(c) end
    table.sort(parts)
    return partKey(d) .. "{" .. table.concat(parts, ";") .. "}"
end

local function keyOf(obj)
    local guid = obj.getGUID()
    if not keyByGuid[guid] then keyByGuid[guid] = modelKey(obj.getData()) end
    return keyByGuid[guid]
end

-- ============ STATUS / UI ============
local render

-- Status is part of the XML, so changing it re-renders the panel. Calling self.UI.setValue
-- instead throws a null-reference error while the panel doesn't exist yet (e.g. in onLoad).
local function setStatus(text)
    status = text
    render()
end

local function saveState()
    self.script_state = onSave()
end

-- The panel's height is the sum of its rows.
local function buildXml()
    local x, height = {}, 24   -- 24 = top + bottom padding
    local function row(h, s)
        height = height + h + 6   -- 6 = layout spacing
        x[#x + 1] = s
    end
    local green = ' colors="#3A7A3A|#4A9A4A|#2A5A2A|#555555" textColor="#FFFFFF"'

    row(30, '<Text preferredHeight="30" fontSize="22" fontStyle="Bold">TC Intake</Text>')

    if config and board then
        local fe = factionIndex[board.f]
        row(30, '<Text preferredHeight="30" alignment="MiddleLeft">Board open: '
            .. xmlEscape(fe and fe.faction.name or board.f) .. '</Text>')
        row(66, '<Text preferredHeight="66" fontSize="15" alignment="UpperLeft" color="#BBBBBB">'
            .. 'Drop new models into a cell, move models to retag them, copy a model (Ctrl+C / Ctrl+V) '
            .. 'to put it in several cells, drop it on Discard to destroy it. Close stores everything.</Text>')
        row(44, '<Button preferredHeight="44" onClick="ui_close"' .. green .. '>Close board (tag and store)</Button>')
    elseif config then
        local opts = {}
        for _, f in ipairs(config.factions) do
            opts[#opts + 1] = '<Option' .. (f.id == sel.f and ' selected="true"' or '') .. '>' .. xmlEscape(f.name) .. '</Option>'
        end
        row(40, '<Dropdown id="faction" preferredHeight="40" onValueChanged="ui_faction">' .. table.concat(opts) .. '</Dropdown>')
        row(44, '<HorizontalLayout preferredHeight="44" spacing="6">'
            .. '<Button onClick="ui_open"' .. green .. '>Open board</Button>'
            .. '<Button onClick="ui_pull">Pull from catalog</Button></HorizontalLayout>')
    end

    row(36, '<HorizontalLayout preferredHeight="36" spacing="6">'
        .. (config and '<Button onClick="ui_unsorted" fontSize="16">Check unsorted</Button>' or '')
        .. (board and '' or '<Button onClick="ui_reload" fontSize="16">Reload config</Button>')
        .. '</HorizontalLayout>')

    row(160, '<Text preferredHeight="160" fontSize="16" alignment="UpperLeft">' .. xmlEscape(status) .. '</Text>')

    return '<Defaults><Text fontSize="18" color="#FFFFFF"/><Button fontSize="18"/><Dropdown fontSize="18"/></Defaults>'
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

-- ============ JOB QUEUE ============
-- Taking out, storing and spawning run BATCH_SIZE per frame, so a whole faction (hundreds of
-- models) doesn't freeze the game. A job may return a number of frames to wait before the
-- next one (e.g. to let the tiles exist before models drop onto them).
local queue, queueRunning, queueDone = {}, false, nil

local function runQueue()
    local pause = 1
    for _ = 1, BATCH_SIZE do
        -- MoonSharp's table.remove throws on an empty table (standard Lua returns nil).
        if #queue == 0 then break end
        local job = table.remove(queue, 1)
        -- One failing job must not stop the queue, or `busy` would stay set forever.
        local ok, result = pcall(job)
        if not ok then print("[TC Intake] " .. tostring(result)) end
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

local function flushQueue(done)
    queueDone = done
    if queueRunning then return end
    queueRunning = true
    Wait.frames(runQueue, 1)
end

-- ============ CONFIG ============
local function applyConfig(text)
    local ok, data = pcall(JSON.decode, text)
    if not ok or type(data) ~= "table" or type(data.factions) ~= "table" or #data.factions == 0 then
        config = nil
        setStatus("units.json could not be parsed (no factions).")
        return
    end

    config, factionIndex, subOwner = data, {}, {}
    for fi, f in ipairs(data.factions) do
        local fe = {faction = f, index = fi, units = {}, unitIndex = {}, subs = {}}
        f.units = f.units or {}
        for ui, u in ipairs(f.units) do
            fe.units[u.id] = u
            fe.unitIndex[u.id] = ui
        end
        for _, s in ipairs(f.subfactions or {}) do
            fe.subs[s.id] = s
            subOwner[s.id] = f.id
        end
        factionIndex[f.id] = fe
    end
    if not factionIndex[sel.f] then sel.f = data.factions[1].id end

    setStatus("Config loaded: " .. #data.factions .. " faction(s). Choose a faction and open its board.")
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
            return
        end
        applyConfig(req.text)
    end)
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

-- ============ BOARD GEOMETRY ============
-- A Mercenaries unit on a faction board (hired mercenary or a unit every warband can get) has
-- no Vanilla General cell (untagged ones belong to the Mercenaries board). A hired mercenary
-- also has no cells in the rows of a subfaction whose own `mercenaries` list leaves it out
-- (Trench Ghosts hire none).
local function isMercColumn(col) return col.f ~= board.f end

local function cellExists(col, row)
    if not isMercColumn(col) then return true end
    if row.kind == "g" and row.ctx == "_" then return false end
    if row.mercs and not col.everyone then
        for _, uid in ipairs(row.mercs) do
            if uid == col.u then return true end
        end
        return false
    end
    return true
end

-- Row index of membership m in column col on the open board, or nil if it belongs elsewhere.
local function rowFor(col, m)
    local ctx = m.ctx
    if isMercColumn(col) then
        if m.kind == "g" and ctx == "_" then return nil end
        if m.kind == "i" then
            if ctx == "_" then return nil end          -- the Mercenaries board's own pick
            if ctx == board.f then ctx = "_" end        -- this faction's vanilla pick
        end
    end
    return board.rowIndex[m.kind .. ":" .. ctx]
end

-- The membership a cell stands for (inverse of rowFor).
local function cellMembership(col, row)
    if row.kind == "i" and row.ctx == "_" and isMercColumn(col) then return {kind = "i", ctx = board.f} end
    return {kind = row.kind, ctx = row.ctx}
end

local function cellName(c, r)
    return board.cols[c].name .. " / " .. board.rows[r].name
end

-- Where a world position lies: "cell", col, row / "discard" / "board" (on the board but not
-- in a cell: labels, gaps, missing cells) / nil (off the board).
local function locate(p)
    local x, z = worldToFrame(p)
    local bd = board.bounds
    if x < bd.x0 or x > bd.x1 or z < bd.z0 or z > bd.z1 then return nil end
    if z >= board.discard.z0 then return "discard" end
    for c, col in ipairs(board.cols) do
        if x >= col.x0 and x <= col.x1 then
            for r, row in ipairs(board.rows) do
                if z >= row.z0 and z <= row.z1 then
                    if cellExists(col, row) then return "cell", c, r end
                    return "board"
                end
            end
        end
    end
    return "board"
end

-- Packs items ({w, d}) into shelves inside a cell of the given width; sets item.x / item.z
-- (centre, from the cell's near-left corner) and returns the depth used.
local function shelve(items, width)
    local x, z, rowD = CELL_PAD, CELL_PAD, 0
    for _, it in ipairs(items) do
        if x > CELL_PAD and x + it.w + CELL_PAD > width then
            x, z, rowD = CELL_PAD, z + rowD + CELL_PAD, 0
        end
        it.x, it.z = x + it.w / 2, z + it.d / 2
        x = x + it.w + CELL_PAD
        if it.d > rowD then rowD = it.d end
    end
    return z + rowD + CELL_PAD
end

-- Columns and rows of a faction's board, without sizes.
local function boardSkeleton(fe)
    local b = {f = fe.faction.id, cols = {}, rows = {}, colIndex = {}, rowIndex = {}}
    local function addCol(f, u, suffix, everyone)
        b.cols[#b.cols + 1] = {f = f, u = u.id, name = u.name .. (suffix or ""), everyone = everyone}
        b.colIndex[f .. "/" .. u.id] = #b.cols
    end
    for _, u in ipairs(fe.faction.units) do addCol(b.f, u) end
    local mercs = factionIndex[MERC]
    if b.f ~= MERC and mercs then
        for _, uid in ipairs(fe.faction.mercenaries or {}) do
            if mercs.units[uid] then addCol(MERC, mercs.units[uid], " (merc)") end
        end
        -- Units every warband can get (Golem, an exploration reward). Not mercenaries, so a
        -- subfaction's own mercenaries list doesn't remove them.
        for _, u in ipairs(mercs.faction.units) do
            if u.everyone and not b.colIndex[MERC .. "/" .. u.id] then addCol(MERC, u, nil, true) end
        end
    end
    local contexts = {{id = "_", name = "Vanilla"}}
    for _, sf in ipairs(fe.faction.subfactions or {}) do contexts[#contexts + 1] = sf end
    for _, ctx in ipairs(contexts) do
        for _, kind in ipairs({"g", "i"}) do
            b.rows[#b.rows + 1] = {kind = kind, ctx = ctx.id, name = ctx.name .. (kind == "g" and " - General" or " - Import"),
                                   mercs = ctx.mercenaries}
            b.rowIndex[kind .. ":" .. ctx.id] = #b.rows
        end
    end
    return b
end

-- ============ OPEN BOARD ============
local function spawnTile(cx, cz, w, d, color, name)
    local pos = frameToWorld(cx, cz, board.frame.y + TILE_THICKNESS / 2)
    spawnObjectData({
        data = {
            Name = "BlockSquare", Nickname = name,
            Transform = {posX = pos.x, posY = pos.y, posZ = pos.z, rotX = 0, rotY = board.frame.yaw, rotZ = 0,
                         scaleX = 1, scaleY = 1, scaleZ = 1},
            ColorDiffuse = {r = color[1], g = color[2], b = color[3]},
            Locked = true, Tooltip = false, Grid = false, Snap = false, Tags = {BOARD_TAG},
        },
        -- A block's native size isn't known up front, so it is scaled once it exists.
        callback_function = function(obj)
            local size, scale = obj.getBoundsNormalized().size, obj.getScale()
            obj.setScale({scale.x * w / size.x, scale.y * TILE_THICKNESS / size.y, scale.z * d / size.z})
        end,
    })
end

local function spawnLabel(text, cx, cz)
    spawnObject({
        type     = "3DText",
        position = frameToWorld(cx, cz, board.frame.y + TILE_THICKNESS + 0.05),
        rotation = {LABEL_PITCH, board.frame.yaw + LABEL_YAW, 0},
        callback_function = function(obj)
            obj.TextTool.setValue(text)
            obj.TextTool.setFontSize(LABEL_FONT)
            obj.addTag(BOARD_TAG)
        end,
    })
end

-- A model taken out of its bag: it becomes its first cell's membership, every further
-- membership becomes a copy (on this board: in its cell; elsewhere: back into the bag).
local function onTaken(obj, take)
    local first = take.places[1]
    obj.setGMNotes(JSON.encode(membershipTag(take.f, take.u, first.m, take.w, take.d)))
    obj.highlightOff()
    for k = 2, #take.places do
        local p = take.places[k]
        local d = obj.getData()
        d.GUID = nil
        d.GMNotes = JSON.encode(membershipTag(take.f, take.u, p.m, take.w, take.d))
        spawnObjectData({data = d, position = p.pos, rotation = take.rot})
    end
    for _, m in ipairs(take.off) do
        local d = obj.getData()
        d.GUID = nil
        d.GMNotes = JSON.encode(membershipTag(take.f, take.u, m, take.w, take.d))
        local bp = take.bag.getPosition()
        spawnObjectData({data = d, position = {bp.x, bp.y + 4, bp.z}, callback_function = function(o)
            if take.bag ~= nil then take.bag.putObject(o) end
        end})
    end
end

local function openBoard()
    if busy or board or not config then return end
    local fe = factionIndex[sel.f]
    if not fe then return end
    clearHighlights()
    board = boardSkeleton(fe)
    keyByGuid = {}

    -- Bags of every column, found in one pass.
    local bags = {}
    for _, obj in ipairs(getAllObjects()) do
        local m = parseBagMarker(obj.getGMNotes())
        if m and m.f and m.u and board.colIndex[m.f .. "/" .. m.u] then bags[m.f .. "/" .. m.u] = obj end
    end

    -- Plan: which bag entries come out, and into which cells.
    local cells = {}     -- "c:r" -> items {w, d, place}
    local takes, untagged, foreign, copies = {}, 0, 0, 0
    for _, col in ipairs(board.cols) do
        local bag = bags[col.f .. "/" .. col.u]
        for _, entry in ipairs(bag and bag.getObjects() or {}) do
            local tag = parseTag(entry.gm_notes)
            local c = tag and board.colIndex[tostring(tag.f) .. "/" .. tostring(tag.u)]
            if not tag then
                untagged = untagged + 1
            elseif not c then
                foreign = foreign + 1   -- tagged for a unit that isn't on this board: stays in the bag
            else
                local take = {bag = bag, guid = entry.guid, f = tag.f, u = tag.u, places = {}, off = {},
                              w = tonumber(tag.w) or DEFAULT_SIZE, d = tonumber(tag.d) or DEFAULT_SIZE}
                for _, m in ipairs(membershipsOf(tag)) do
                    local r = rowFor(board.cols[c], m)
                    if r then
                        local place = {c = c, r = r, m = m}
                        take.places[#take.places + 1] = place
                        local key = c .. ":" .. r
                        cells[key] = cells[key] or {}
                        table.insert(cells[key], {w = take.w, d = take.d, place = place})
                    else
                        take.off[#take.off + 1] = m
                    end
                end
                if #take.places > 0 then
                    takes[#takes + 1] = take
                    copies = copies + #take.places + #take.off - 1
                end
            end
        end
    end

    -- Sizes: each column wide enough for its fullest cell at roughly 2:1, each row as deep as
    -- its deepest cell plus spare room.
    local totalW = ROW_LABEL_W
    for c, col in ipairs(board.cols) do
        local area, widest = 0, 0
        for r = 1, #board.rows do
            local a = 0
            for _, it in ipairs(cells[c .. ":" .. r] or {}) do
                a = a + (it.w + CELL_PAD) * (it.d + CELL_PAD)
                if it.w > widest then widest = it.w end
            end
            if a > area then area = a end
        end
        col.w = math.max(MIN_COL_W, widest + 2 * CELL_PAD, math.min(MAX_COL_W, math.sqrt(area * 2)))
        totalW = totalW + CELL_GAP + col.w
    end
    local s = self.getBounds().size
    local half = math.max(s.x, s.z) / 2
    local left = half + BOARD_GAP
    local x = left + ROW_LABEL_W
    for _, col in ipairs(board.cols) do
        col.x0 = x + CELL_GAP
        col.x1 = col.x0 + col.w
        x = col.x1
    end
    local z0 = -half
    local z = z0 + HEADER_D
    for r, row in ipairs(board.rows) do
        local depth = MIN_ROW_D
        for c, col in ipairs(board.cols) do
            local used = shelve(cells[c .. ":" .. r] or {}, col.w) + SPARE_D
            if used > depth then depth = used end
        end
        row.z0 = z + CELL_GAP
        row.z1 = row.z0 + depth
        z = row.z1
    end
    board.discard = {z0 = z + CELL_GAP * 2, z1 = z + CELL_GAP * 2 + DISCARD_D}
    board.bounds = {x0 = left, x1 = x, z0 = z0, z1 = board.discard.z1}

    local rot = self.getRotation()
    local pos = self.getPosition()
    board.frame = {x = pos.x, y = tableY(), z = pos.z, yaw = rot.y}
    local modelRot = {0, rot.y + MODEL_YAW, 0}
    for key, items in pairs(cells) do
        local sep = string.find(key, ":", 1, true)
        local col, row = board.cols[tonumber(string.sub(key, 1, sep - 1))], board.rows[tonumber(string.sub(key, sep + 1))]
        for _, it in ipairs(items) do
            it.place.pos = frameToWorld(col.x0 + it.x, row.z0 + it.z, board.frame.y + TILE_THICKNESS + 0.4)
        end
    end
    busy = true
    saveState()
    setStatus("Opening the " .. fe.faction.name .. " board...")

    -- Tiles and labels first, then the models.
    queue[#queue + 1] = function()
        local bd = board.bounds
        spawnTile((bd.x0 + bd.x1) / 2, z0 + HEADER_D / 2, bd.x1 - bd.x0, HEADER_D, COLOR_HEADER, "Board header")
        for _, col in ipairs(board.cols) do
            spawnLabel(wrapWords(col.name, 16), (col.x0 + col.x1) / 2, z0 + HEADER_D / 2)
        end
    end
    for _, row in ipairs(board.rows) do
        queue[#queue + 1] = function()
            spawnLabel(wrapWords(row.name, 18), left + ROW_LABEL_W / 2, (row.z0 + row.z1) / 2)
            for _, col in ipairs(board.cols) do
                if cellExists(col, row) then
                    spawnTile((col.x0 + col.x1) / 2, (row.z0 + row.z1) / 2, col.w, row.z1 - row.z0,
                        row.kind == "i" and COLOR_IMPORT or COLOR_GENERAL, col.name .. " / " .. row.name)
                end
            end
        end
    end
    queue[#queue + 1] = function()
        local bd = board.bounds
        spawnTile((bd.x0 + bd.x1) / 2, (board.discard.z0 + board.discard.z1) / 2, bd.x1 - bd.x0, DISCARD_D,
            COLOR_DISCARD, "Discard")
        spawnLabel("DISCARD - destroyed on Close", (bd.x0 + bd.x1) / 2, (board.discard.z0 + board.discard.z1) / 2)
        return 10   -- let the tiles exist and be scaled before models drop onto them
    end
    for _, take in ipairs(takes) do
        take.rot = modelRot
        queue[#queue + 1] = function()
            if take.bag == nil then return end
            take.bag.takeObject({guid = take.guid, position = take.places[1].pos, rotation = modelRot, smooth = false,
                callback_function = function(obj) pcall(onTaken, obj, take) end})
        end
    end
    flushQueue(function()
        busy = false
        local lines = {"Board open: " .. #takes .. " model(s) taken out."}
        if copies > 0 then lines[#lines + 1] = copies .. " copies made from models with several tags." end
        if untagged > 0 then lines[#lines + 1] = untagged .. " untagged object(s) left in the bags (Check unsorted)." end
        if foreign > 0 then lines[#lines + 1] = foreign .. " model(s) in these bags are tagged for other units and stayed there." end
        setStatus(table.concat(lines, "\n"))
    end)
end

-- ============ DROP FEEDBACK ============
-- After a drop: which cell the model is in, how many models that cell holds, and whether the
-- same model (same assets and scale, see modelKey) is already on the board. Red = already in
-- this cell (a real duplicate), yellow = in other cells (often an intended copy).
local function checkDrops()
    local drops = pendingDrops
    pendingDrops = {}
    if not board or busy then return end

    local byKey, perCell = {}, {}
    for _, obj in ipairs(getAllObjects()) do
        if isModel(obj) then
            local where, c, r = locate(obj.getPosition())
            if where == "cell" then
                local k = keyOf(obj)
                byKey[k] = byKey[k] or {}
                table.insert(byKey[k], {obj = obj, c = c, r = r})
                perCell[c .. ":" .. r] = (perCell[c .. ":" .. r] or 0) + 1
            end
        end
    end

    clearHighlights()
    local lines = {}
    for _, obj in ipairs(drops) do
        if obj ~= nil then
            local where, c, r = locate(obj.getPosition())
            if where == "discard" then
                highlight(obj, COLOR_BAD)
                lines[#lines + 1] = "On Discard: destroyed when the board closes."
            elseif where == "board" then
                highlight(obj, COLOR_BAD)
                lines[#lines + 1] = "Not in a cell: move it into one."
            elseif where == "cell" then
                local same, other = false, {}
                for _, hit in ipairs(byKey[keyOf(obj)] or {}) do
                    if hit.obj ~= obj then
                        if hit.c == c and hit.r == r then same = true
                        else other[#other + 1] = cellName(hit.c, hit.r) end
                    end
                end
                local line = cellName(c, r) .. ": " .. (perCell[c .. ":" .. r] or 0) .. " model(s)."
                if same then
                    highlight(obj, COLOR_BAD)
                    line = line .. " DUPLICATE: this model is already in this cell."
                elseif #other > 0 then
                    highlight(obj, COLOR_WARN)
                    line = line .. " Also in: " .. table.concat(other, ", ", 1, math.min(#other, 3))
                        .. (#other > 3 and ", ..." or "")
                else
                    highlight(obj, COLOR_OK)
                end
                lines[#lines + 1] = line
            end
        end
    end
    if #lines > 0 then
        if #lines > 6 then
            local n = #lines
            lines = {lines[1], lines[2], lines[3], lines[4], lines[5], "... and " .. (n - 5) .. " more"}
        end
        setStatus(table.concat(lines, "\n"))
    end
end

-- ============ CLOSE BOARD ============
local function storeTag(obj, col, row)
    -- Bounds are not in the save JSON; the spawner needs the footprint before models load.
    local size = obj.getBounds().size
    local tag = membershipTag(col.f, col.u, cellMembership(col, row), round(size.x, 2), round(size.z, 2))
    obj.setGMNotes(JSON.encode(tag))
    -- Only the stored script changes here; the running copy dies when the object enters the bag.
    obj.setLuaScript("")
    obj.script_state = ""
    obj.clearButtons()
    obj.clearInputs()
    obj.UI.setXml("")
    obj.highlightOff()
end

local function closeBoard()
    if busy or not board then return end
    clearHighlights()

    local stores, discards, stray = {}, {}, 0
    for _, obj in ipairs(getAllObjects()) do
        if isModel(obj) then
            local where, c, r = locate(obj.getPosition())
            if where == "cell" then
                stores[#stores + 1] = {obj = obj, col = board.cols[c], row = board.rows[r]}
            elseif where == "discard" then
                discards[#discards + 1] = obj
            elseif where == "board" then
                stray = stray + 1
                highlight(obj, COLOR_BAD)
            end
        end
    end
    if stray > 0 then
        setStatus(stray .. " model(s) lie on the board outside any cell (red). Move them into a cell "
            .. "or onto Discard, then close again.")
        return
    end

    busy = true
    setStatus("Storing " .. #stores .. " model(s)...")
    -- Bags first (creating a missing one is asynchronous), one after another.
    local order, seen, bagOf = {}, {}, {}
    for _, st in ipairs(stores) do
        local key = st.col.f .. "/" .. st.col.u
        if not seen[key] then
            seen[key] = true
            order[#order + 1] = st.col
        end
    end
    local i = 0
    local function nextBag()
        i = i + 1
        local col = order[i]
        if col then
            ensureBag(col.f, col.u, function(bag)
                bagOf[col.f .. "/" .. col.u] = bag
                nextBag()
            end)
            return
        end
        for _, st in ipairs(stores) do
            queue[#queue + 1] = function()
                if st.obj == nil then return end
                storeTag(st.obj, st.col, st.row)
                bagOf[st.col.f .. "/" .. st.col.u].putObject(st.obj)
            end
        end
        for _, obj in ipairs(discards) do
            queue[#queue + 1] = function() if obj ~= nil then obj.destruct() end end
        end
        for _, obj in ipairs(getAllObjects()) do
            if obj.hasTag(BOARD_TAG) then queue[#queue + 1] = function() if obj ~= nil then obj.destruct() end end end
        end
        flushQueue(function()
            busy = false
            local name = factionIndex[board.f] and factionIndex[board.f].faction.name or board.f
            board, keyByGuid = nil, {}
            saveState()
            setStatus("Board closed: " .. #stores .. " model(s) tagged and stored in " .. #order .. " bag(s)"
                .. (#discards > 0 and (", " .. #discards .. " destroyed") or "") .. " (" .. name .. ").")
        end)
    end
    nextBag()
end

-- ============ PULL FROM CATALOG ============
-- Brings the bags up to date with the published catalog: every catalog model of the chosen
-- faction's board columns (its units, hired mercenaries, Golem) that no bag holds yet is
-- spawned with a tag rebuilt from its catalog entry (s may contain "_" = vanilla too; the
-- board splits such tags into one copy per cell when it opens) and put into its unit bag.
-- Only adds, never removes or retags: models in the bags win, so new models that aren't
-- exported yet are safe. A model discarded here but not yet exported comes back, so export
-- before pulling. Manual (a button), not on load, for the same reason.
local function fetchJson(url, callback)
    WebRequest.get(url, function(req)
        if req.is_error or (req.response_code and req.response_code >= 400) then
            callback(nil, tostring(req.error or req.response_code))
            return
        end
        local ok, data = pcall(JSON.decode, req.text)
        if not ok or type(data) ~= "table" then callback(nil, "bad JSON") return end
        callback(data)
    end)
end

local function pullCatalog()
    if busy or board or not config then return end
    local fe = factionIndex[sel.f]
    if not fe then return end
    local cols = boardSkeleton(fe).cols
    busy = true
    setStatus("Pulling " .. fe.faction.name .. " from the catalog...")
    local function fail(what, err)
        busy = false
        setStatus("Pull from catalog failed: " .. what .. " (" .. tostring(err) .. ").")
    end

    fetchJson(RAW_BASE .. "catalog/version.json?v=" .. os.time(), function(v, err)
        if not v then fail("version.json", err) return end
        local version = tostring(v.catalog)
        fetchJson(RAW_BASE .. "catalog/index.json?v=" .. version, function(index, err2)
            if not index then fail("index.json", err2) return end
            local files = {}   -- "f/u" -> unit file
            for _, f in ipairs(index.factions or {}) do
                for _, u in ipairs(f.units or {}) do files[f.id .. "/" .. u.id] = u.file end
            end
            local added, present, bagsTouched, i = 0, 0, 0, 0
            local function nextCol()
                i = i + 1
                local col = cols[i]
                if not col then
                    flushQueue(function()
                        busy = false
                        setStatus("Pulled " .. added .. " model(s) from catalog " .. version .. " into " .. bagsTouched
                            .. " bag(s); " .. present .. " were already in the bags.")
                    end)
                    return
                end
                local file = files[col.f .. "/" .. col.u]
                if not file then nextCol() return end
                fetchJson(RAW_BASE .. "catalog/" .. file .. "?v=" .. version, function(entries, err3)
                    if not entries then fail(file, err3) return end
                    -- Models this unit's bag already holds.
                    local have = {}
                    local bag = findBag(col.f, col.u)
                    if bag then
                        for _, d in ipairs(bag.getData().ContainedObjects or {}) do have[modelKey(d)] = true end
                    end
                    local missing = {}
                    for _, e in ipairs(entries) do
                        if type(e.data) == "table" and have[modelKey(e.data)] then
                            present = present + 1
                        elseif type(e.data) == "table" then
                            missing[#missing + 1] = e
                        end
                    end
                    if #missing == 0 then nextCol() return end
                    ensureBag(col.f, col.u, function(target)
                        bagsTouched = bagsTouched + 1
                        local bp = target.getPosition()
                        for _, e in ipairs(missing) do
                            queue[#queue + 1] = function()
                                local tag = {tc = 1, f = col.f, u = col.u, s = list(e.s), w = e.w, d = e.d}
                                if e.i and #list(e.i) > 0 then tag.i = list(e.i) end
                                e.data.GMNotes = JSON.encode(tag)
                                spawnObjectData({data = e.data, position = {bp.x, bp.y + 4, bp.z},
                                    callback_function = function(o) if target ~= nil then target.putObject(o) end end})
                                added = added + 1
                            end
                        end
                        flushQueue(nil)
                        nextCol()
                    end)
                end)
            end
            nextCol()
        end)
    end)
end

-- ============ UNSORTED CHECK ============
-- Loose models (off the board) without a valid tag, and bag contents whose tag is missing,
-- invalid or for a different unit than the bag.
local function checkUnsorted()
    if not config or busy then return end
    clearHighlights()

    local loose, problems = 0, {}
    for _, obj in ipairs(getAllObjects()) do
        if isModel(obj) and not (board and locate(obj.getPosition())) then
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

    local lines = {"Loose untagged models off the board: " .. loose .. (loose > 0 and " (highlighted red)" or "")}
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
        if f.name == value then
            sel.f = f.id
            saveState()
            break
        end
    end
end

function ui_open() openBoard() end
function ui_pull() pullCatalog() end
function ui_close() closeBoard() end
function ui_unsorted() checkUnsorted() end
function ui_reload() if not board then loadConfig() end end

-- ============ EVENTS ============
-- Global event, also delivered to object scripts. Debounced so dropping a stack of models
-- gives one report.
function onObjectDrop(player_color, obj)
    if busy or not board or not isModel(obj) then return end
    pendingDrops[#pendingDrops + 1] = obj
    dropToken = dropToken + 1
    local token = dropToken
    Wait.time(function()
        if token == dropToken then checkDrops() end
    end, 0.5)
end

function onSave()
    return JSON.encode({f = sel.f, board = board})
end

function onLoad(saved_data)
    if saved_data and saved_data ~= "" then
        local ok, data = pcall(JSON.decode, saved_data)
        if ok and type(data) == "table" then
            sel.f = data.f or (data.sel and data.sel.f)   -- data.sel: older intake versions
            -- An open board's tiles and models were saved with the game; only its geometry
            -- needs restoring.
            if type(data.board) == "table" and data.board.frame then board = data.board end
        end
    end
    self.setVectorLines({})   -- older versions outlined an intake zone
    render()
    loadConfig()
end
