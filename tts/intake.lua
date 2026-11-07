-- =============================================
-- TC MINIATURES - INTAKE STATION (dev save only)
-- =============================================
-- Sorting board for the maintainer. The catalog is the storage: there are no bags. Choose a
-- faction (and a subfaction to focus on) and press Open board: the station lays out a grid to
-- its right, one column per unit (leader first, then the mercenaries the faction can hire),
-- two rows per context (Vanilla and each subfaction, each with General and Import), and spawns
-- every catalog model of those units into its cells, read from the local repo that
-- tools/tts_bridge.py listen serves (so the board shows the latest state, also before a push).
--
-- Work by moving models: drop new ones into a cell, move them to retag, copy (Ctrl+C / V) to
-- put a model in several cells, drop it on Discard to remove it. Models added since the board
-- opened (or the last Publish) are outlined green, moved ones yellow. Publish sends every
-- model lying in a cell to the bridge listener, which writes catalog/ (tools/publish.py) and
-- answers with a report (changes, catalog version, gaps). Then commit and push the catalog.
--
-- One object = one cell. A model that belongs in several cells is copied, one copy per cell;
-- export merges copies of the same model within a unit. What a cell means:
--   General, Vanilla        no subfaction theme
--   General, subfaction C   made for C
--   Import, context X       preferred pick for X's warband imports
-- A model that sits only in Import rows (no General copy) also counts as General for those
-- contexts, so after a Publish it shows in both. A faction's mercenaries use the faction id
-- for its vanilla import pick; the Mercenaries board's own pick is "_" (see tools/publish.py).

-- ===================== CONFIG =====================
-- The local repo, served by `python tools/tts_bridge.py listen` (needed for Open and Publish).
local REPO = "http://127.0.0.1:8765/"

local MERC = "mercenaries"

-- Board layout, in world units relative to the station (its position and rotation when the
-- board was opened, not its scale). x runs to the right of a player standing on the station's
-- local +z side (where a panel with rotation "0 0 180" reads upright, tested on the spawner),
-- z away from them. Columns read left to right from the faction's leader to its mercenaries;
-- rows start level with the station's front edge and grow away from the player, the focused
-- subfaction's rows first.
local BOARD_GAP   = 3      -- between the station and the board's left edge
local ROW_LABEL_W = 8      -- columns of row labels at the board's left and right edges
local HEADER_D    = 2.5    -- rows of column labels: nearest to the player and at the far end
local CELL_GAP    = 0.5    -- between cells
local CELL_PAD    = 0.3    -- around and between models in a cell
local MIN_COL_W   = 6
local MAX_COL_W   = 24
local MIN_ROW_D   = 3
local SPARE_D     = 2      -- empty room at the far side of every row, for new models
local FOCUS_SPARE = 4      -- extra room in the focused rows (where new models usually go)
local DISCARD_D   = 5      -- Discard strip beyond the last row
local TILE_THICKNESS = 0.1
local DEFAULT_SIZE   = 1.5 -- footprint of a model without w/d

-- Yaw of models on the board (relative to the station) so they face the player, and of the
-- flat 3D text labels so they read upright from the player's side. Same values as the
-- spawner, whose reader also stands on the +z side.
local MODEL_YAW   = 0
local LABEL_PITCH = 90
local LABEL_YAW   = 180
local LABEL_FONT  = 40     -- column and row names
local COUNT_FONT  = 28     -- model count in each cell's corner

local COLOR_GENERAL = {0.18, 0.18, 0.18}
local COLOR_IMPORT  = {0.12, 0.22, 0.15}
local COLOR_FOCUS   = {0.24, 0.2, 0.12}   -- General cells of the focused context
local COLOR_FOCUS_I = {0.16, 0.24, 0.14}  -- Import cells of the focused context
local COLOR_DISCARD = {0.4, 0.08, 0.08}
local COLOR_HEADER  = {0.08, 0.08, 0.08}

-- TTS object names that count as models. Custom_Model has a CustomMesh; some source mods
-- use asset bundles or image figurines instead.
local MODEL_NAMES = {Custom_Model = true, Custom_Assetbundle = true, Figurine_Custom = true}
local BOARD_TAG   = "TCM_Board"         -- tiles and labels of the open board

local BATCH_SIZE = 10   -- objects spawned or destroyed per frame
local PUBLISH_TIMEOUT = 90   -- seconds to wait for the bridge listener's report
local PART_BYTES      = 500000   -- Publish message size (models' JSON per message)
local MIN_FOOTPRINT   = 0.2      -- a new model measuring less (inches) hasn't loaded yet

-- Object XML UI is positioned from the object's centre; its z is height (negative = up) in
-- UI units (100 per local unit). The panel is lifted to the top face automatically, plus
-- this margin in UI units.
local UI_MARGIN = 5

local COLOR_NEW   = {0.2, 1, 0.2}    -- added since the board opened / the last Publish
local COLOR_MOVED = {1, 0.8, 0.1}    -- in another cell than when the board opened
local COLOR_BAD   = {1, 0.2, 0.2}    -- duplicate in its cell, on Discard, or outside any cell
-- ==================================================

local config       = nil        -- decoded units.json
local factionIndex = {}         -- faction id -> {faction=, units={id->unit}}
local sel          = {f = nil, focus = "_"}   -- faction and focused context ("_" = Vanilla)
-- The open board (saved): f, focus, frame = {x, y, z, yaw}, cols = {f, u, name, x0, x1}, rows =
-- {kind = "g"|"i", ctx, name, z0, z1}, discard = {z0, z1}, bounds, counts = {"c:r" -> label
-- GUID}, origin = {model GUID -> "c:r"}: where each model was when the board opened (or at the
-- last Publish), for the new / moved marks and the change report.
local board        = nil
local status       = "Loading config..."
local busy         = false
local renderPending = false
local highlighted  = {}
local keyByGuid    = {}         -- model identity (see modelKey) of objects on the board
local pendingDrops = {}
local dropToken    = 0
local closeArmed   = 0          -- os.time() until which a second Close discards the changes
local publishId    = nil        -- the Publish waiting for its report
local publishLines = {}         -- what that Publish changes (shown above the report)
local publishSizes = {}         -- the footprints it sent (kept as the models' sizes once done)

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

-- Locked ones count too: some source mods ship their models locked, and a model left out
-- silently would never reach the catalog (export unlocks them).
local function isModel(obj)
    return obj ~= nil and MODEL_NAMES[obj.name] and not obj.hasTag(BOARD_TAG)
end

-- ============ MEMBERSHIPS ============
-- What a catalog entry's s / i say, as single memberships {kind = "g"|"i", ctx}: one per board
-- cell (on some board) the model belongs in. "_" in s (vanilla next to themes) or an empty s
-- = General Vanilla.
local function membershipsOf(t)
    local out = {}
    local s = list(t.s)
    if #s == 0 then out[#out + 1] = {kind = "g", ctx = "_"} end
    for _, sid in ipairs(s) do out[#out + 1] = {kind = "g", ctx = sid} end
    for _, x in ipairs(list(t.i)) do out[#out + 1] = {kind = "i", ctx = x} end
    return out
end

-- Identity of a model for the duplicate check, like dedupe_key in tools/export.py: the
-- object's own asset URLs and scale plus all attached parts. Scale to 2 decimals: the catalog
-- rounds transforms.
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

local function contexts(fe)
    local out = {{id = "_", name = "Vanilla"}}
    for _, sf in ipairs(fe.faction.subfactions or {}) do out[#out + 1] = sf end
    return out
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
            .. 'to put it in several cells, drop it on Discard to remove it. Green = new, yellow = moved.</Text>')
        row(44, '<HorizontalLayout preferredHeight="44" spacing="6">'
            .. '<Button onClick="ui_publish"' .. green .. '>Publish to catalog</Button>'
            .. '<Button onClick="ui_close">Close board</Button></HorizontalLayout>')
    elseif config then
        local opts = {}
        for _, f in ipairs(config.factions) do
            opts[#opts + 1] = '<Option' .. (f.id == sel.f and ' selected="true"' or '') .. '>' .. xmlEscape(f.name) .. '</Option>'
        end
        row(40, '<Dropdown id="faction" preferredHeight="40" onValueChanged="ui_faction">' .. table.concat(opts) .. '</Dropdown>')
        local fe = factionIndex[sel.f]
        if fe then
            opts = {}
            for _, c in ipairs(contexts(fe)) do
                opts[#opts + 1] = '<Option' .. (c.id == sel.focus and ' selected="true"' or '') .. '>Focus: ' .. xmlEscape(c.name) .. '</Option>'
            end
            row(40, '<Dropdown id="focus" preferredHeight="40" onValueChanged="ui_focus">' .. table.concat(opts) .. '</Dropdown>')
        end
        row(44, '<HorizontalLayout preferredHeight="44" spacing="6">'
            .. '<Button onClick="ui_open"' .. green .. '>Open board</Button>'
            .. '<Button onClick="ui_reload" fontSize="16">Reload config</Button></HorizontalLayout>')
    else
        row(44, '<Button preferredHeight="44" onClick="ui_reload">Reload config</Button>')
    end

    row(180, '<Text preferredHeight="180" fontSize="16" alignment="UpperLeft">' .. xmlEscape(status) .. '</Text>')

    return '<Defaults><Text fontSize="18" color="#FFFFFF"/><Button fontSize="18"/><Dropdown fontSize="18"/></Defaults>'
        .. '<Panel position="0 0 ' .. uiHeight() .. '" rotation="0 0 180" width="520" height="' .. height
        .. '" color="#1A1A1AEE">'
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
-- Spawning and destroying run BATCH_SIZE per frame, so a whole faction (hundreds of models)
-- doesn't freeze the game. A job may return a number of frames to wait before the next one
-- (e.g. to let the tiles exist before models drop onto them).
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

-- ============ LOADING FROM THE REPO ============
-- Downloads a file of the local repo and calls done(text), or done(nil, reason).
local function fetch(path, done)
    WebRequest.get(REPO .. path .. "?v=" .. os.time(), function(req)
        if req.is_error or (req.response_code and req.response_code >= 400) or not req.text then
            done(nil, tostring(req.error or req.response_code))
        else
            done(req.text)
        end
    end)
end

local NO_LISTENER = "Start the bridge listener on this PC (python tools/tts_bridge.py listen), then press Reload config."

local function applyConfig(text)
    local ok, data = pcall(JSON.decode, text)
    if not ok or type(data) ~= "table" or type(data.factions) ~= "table" or #data.factions == 0 then
        config = nil
        setStatus("units.json could not be parsed (no factions).")
        return
    end
    config, factionIndex = data, {}
    for _, f in ipairs(data.factions) do
        local fe = {faction = f, units = {}}
        f.units = f.units or {}
        for _, u in ipairs(f.units) do fe.units[u.id] = u end
        factionIndex[f.id] = fe
    end
    if not factionIndex[sel.f] then sel.f, sel.focus = data.factions[1].id, "_" end
    setStatus("Config loaded: " .. #data.factions .. " faction(s). Choose a faction and a focus, then Open board.")
end

local function loadConfig()
    setStatus("Loading config...")
    fetch("config/units.json", function(text, err)
        if not text then
            config = nil
            setStatus("Could not load config/units.json (" .. err .. "). " .. NO_LISTENER)
            return
        end
        applyConfig(text)
    end)
end

-- A catalog unit file: one model per line, its info as JSON, a tab, its object data as JSON
-- (see dump_unit in tools/export.py). Only the small info part is decoded (MoonSharp's
-- JSON.decode is very slow on big text); the object data is spawned as text.
local function parseUnit(text)
    local entries, p = {}, 1
    while p <= #text do
        local nl = string.find(text, "\n", p, true) or (#text + 1)
        local tab = string.find(text, "\t", p, true)
        if tab and tab < nl then
            local ok, e = pcall(JSON.decode, string.sub(text, p, tab - 1))
            local json = string.sub(text, tab + 1, nl - 1)
            if string.sub(json, -1) == "\r" then json = string.sub(json, 1, -2) end
            if ok and type(e) == "table" then
                e.json = json
                entries[#entries + 1] = e
            end
        end
        p = nl + 1
    end
    return entries
end

-- ============ BOARD GEOMETRY ============
-- A Mercenaries unit on a faction board (hired mercenary or a unit every warband can get) has
-- no Vanilla General cell (untagged ones belong to the Mercenaries board). A hired mercenary
-- also has no cells in the rows of a subfaction whose own `mercenaries` list leaves it out
-- (Trench Ghosts hire none). tools/publish.py follows the same rules.
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
        if ctx == "_" then return nil end            -- the Mercenaries board's
        if m.kind == "i" and ctx == board.f then ctx = "_" end   -- this faction's vanilla pick
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
    if z >= board.discard.z0 and z <= board.discard.z1 then return "discard" end
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

-- Columns and rows of a faction's board, without sizes. The focused context's rows come
-- first (nearest to the player), then Vanilla and the subfactions in config order.
local function boardSkeleton(fe, focus)
    local b = {f = fe.faction.id, focus = focus, cols = {}, rows = {}, colIndex = {}, rowIndex = {}}
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
    local ordered = {}
    for _, ctx in ipairs(contexts(fe)) do
        if ctx.id == focus then table.insert(ordered, 1, ctx) else ordered[#ordered + 1] = ctx end
    end
    for _, ctx in ipairs(ordered) do
        for _, kind in ipairs({"g", "i"}) do
            b.rows[#b.rows + 1] = {kind = kind, ctx = ctx.id, name = ctx.name .. (kind == "g" and " - General" or " - Import"),
                                   mercs = ctx.mercenaries, focus = ctx.id == focus}
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

-- A flat label; done(obj) gets the text object (cell counts are kept to update them).
local function spawnLabel(text, cx, cz, fontSize, done)
    spawnObject({
        type     = "3DText",
        position = frameToWorld(cx, cz, board.frame.y + TILE_THICKNESS + 0.05),
        rotation = {LABEL_PITCH, board.frame.yaw + LABEL_YAW, 0},
        callback_function = function(obj)
            obj.TextTool.setValue(text)
            obj.TextTool.setFontSize(fontSize or LABEL_FONT)
            obj.addTag(BOARD_TAG)
            if done then done(obj) end
        end,
    })
end

-- Spawns one catalog entry at pos (its object data as text; the unit file keeps name,
-- description, tags and tilt beside it) and records the cell it came from.
local function spawnEntry(e, pos, cellKey)
    local extra = ',"Nickname":' .. JSON.encode(e.n or "") .. ',"Description":' .. JSON.encode(e.desc or "")
    if #list(e.t) > 0 then extra = extra .. ',"Tags":' .. JSON.encode(e.t) end   -- an empty table may encode as {}
    local obj = spawnObjectJSON({json = string.sub(e.json, 1, -2) .. extra .. "}", position = pos,
                                 rotation = {e.rx or 0, board.frame.yaw + MODEL_YAW, e.rz or 0}})
    if obj then
        board.origin[obj.getGUID()] = cellKey
        board.size[obj.getGUID()] = {tonumber(e.w) or DEFAULT_SIZE, tonumber(e.d) or DEFAULT_SIZE}
    end
end

local refreshMarks

-- Lays out the board for the catalog entries {col = c, e} and spawns tiles, labels and models.
local function buildBoard(fe, entries)
    -- Plan: which entries go into which cells (one model per membership shown on this board).
    local cells = {}     -- "c:r" -> items {w, d, e}
    local placed = 0
    for _, it in ipairs(entries) do
        local col = board.cols[it.c]
        for _, m in ipairs(membershipsOf(it.e)) do
            local r = rowFor(col, m)
            if r then
                local key = it.c .. ":" .. r
                cells[key] = cells[key] or {}
                table.insert(cells[key], {w = tonumber(it.e.w) or DEFAULT_SIZE, d = tonumber(it.e.d) or DEFAULT_SIZE, e = it.e})
                placed = placed + 1
            end
        end
    end

    -- Sizes: each column wide enough for its fullest cell at roughly 2:1, each row as deep as
    -- its deepest cell plus spare room (more in the focused rows, where new models go).
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
    local right = x + CELL_GAP + ROW_LABEL_W
    local z0 = -half
    local z = z0 + HEADER_D
    for r, row in ipairs(board.rows) do
        local depth = MIN_ROW_D
        for c, col in ipairs(board.cols) do
            local used = shelve(cells[c .. ":" .. r] or {}, col.w) + (row.focus and FOCUS_SPARE or SPARE_D)
            if used > depth then depth = used end
        end
        row.z0 = z + CELL_GAP
        row.z1 = row.z0 + depth
        z = row.z1
    end
    board.discard = {z0 = z + CELL_GAP * 2, z1 = z + CELL_GAP * 2 + DISCARD_D}
    local farHeader = board.discard.z1 + CELL_GAP
    board.bounds = {x0 = left, x1 = right, z0 = z0, z1 = farHeader + HEADER_D}

    local rot, pos = self.getRotation(), self.getPosition()
    board.frame = {x = pos.x, y = tableY(), z = pos.z, yaw = rot.y}
    board.origin, board.counts, board.size = {}, {}, {}
    saveState()

    -- Tiles and labels first, then the models.
    local bd = board.bounds
    local midX = (left + right) / 2
    for _, hz in ipairs({z0 + HEADER_D / 2, farHeader + HEADER_D / 2}) do
        queue[#queue + 1] = function()
            spawnTile(midX, hz, right - left, HEADER_D, COLOR_HEADER, "Board header")
            for _, col in ipairs(board.cols) do
                spawnLabel(wrapWords(col.name, 16), (col.x0 + col.x1) / 2, hz)
            end
        end
    end
    for r, row in ipairs(board.rows) do
        queue[#queue + 1] = function()
            local name = wrapWords(row.name, 18)
            spawnLabel(name, left + ROW_LABEL_W / 2, (row.z0 + row.z1) / 2)
            spawnLabel(name, right - ROW_LABEL_W / 2, (row.z0 + row.z1) / 2)
            for c, col in ipairs(board.cols) do
                if cellExists(col, row) then
                    local color = row.kind == "i" and (row.focus and COLOR_FOCUS_I or COLOR_IMPORT)
                        or (row.focus and COLOR_FOCUS or COLOR_GENERAL)
                    spawnTile((col.x0 + col.x1) / 2, (row.z0 + row.z1) / 2, col.w, row.z1 - row.z0, color,
                        col.name .. " / " .. row.name)
                    -- Model count in the cell's far-right corner (models fill it from the near left).
                    local key = c .. ":" .. r
                    spawnLabel("0", col.x1 - 0.5, row.z1 - 0.4, COUNT_FONT, function(o) board.counts[key] = o.getGUID() end)
                end
            end
        end
    end
    queue[#queue + 1] = function()
        spawnTile(midX, (board.discard.z0 + board.discard.z1) / 2, right - left, DISCARD_D, COLOR_DISCARD, "Discard")
        spawnLabel("DISCARD - removed from the catalog on Publish", midX, (board.discard.z0 + board.discard.z1) / 2)
        return 10   -- let the tiles exist and be scaled before models drop onto them
    end
    local yLift = board.frame.y + TILE_THICKNESS + 0.4
    for key, items in pairs(cells) do
        local sep = string.find(key, ":", 1, true)
        local col, row = board.cols[tonumber(string.sub(key, 1, sep - 1))], board.rows[tonumber(string.sub(key, sep + 1))]
        for _, it in ipairs(items) do
            local p = frameToWorld(col.x0 + it.x, row.z0 + it.z, yLift)
            queue[#queue + 1] = function() spawnEntry(it.e, p, key) end
        end
    end
    flushQueue(function()
        busy = false
        saveState()
        setStatus("Board open: " .. placed .. " model(s) in their cells (" .. fe.faction.name .. ").")
        Wait.time(function() refreshMarks() end, 2)   -- counts once the models have landed
    end)
end

local function openBoard()
    if busy or board or not config then return end
    local fe = factionIndex[sel.f]
    if not fe then return end
    clearHighlights()
    board = boardSkeleton(fe, sel.focus)
    keyByGuid = {}
    busy = true
    setStatus("Opening the " .. fe.faction.name .. " board...")
    fetch("catalog/index.json", function(text, err)
        local ok, index = pcall(JSON.decode, text or "")
        if not text or not ok or type(index) ~= "table" then
            board, busy = nil, false
            setStatus("Could not load catalog/index.json (" .. tostring(err or "bad JSON") .. "). " .. NO_LISTENER)
            return
        end
        local files = {}   -- column index -> unit file
        for _, f in ipairs(index.factions or {}) do
            for _, u in ipairs(f.units or {}) do
                local c = board.colIndex[f.id .. "/" .. u.id]
                if c then files[#files + 1] = {c = c, file = u.file} end
            end
        end
        local entries, i = {}, 0
        local function nextFile()
            i = i + 1
            local job = files[i]
            if not job then
                buildBoard(fe, entries)
                return
            end
            fetch("catalog/" .. job.file, function(t, ferr)
                -- A unit that failed to load must not open empty: publishing that board would
                -- delete all its models from the catalog.
                if not t then
                    board, busy = nil, false
                    setStatus("Could not load catalog/" .. job.file .. " (" .. tostring(ferr) .. "). "
                        .. "The board was not opened. " .. NO_LISTENER)
                    return
                end
                for _, e in ipairs(parseUnit(t)) do entries[#entries + 1] = {c = job.c, e = e} end
                nextFile()
            end)
        end
        nextFile()
    end)
end

-- ============ MARKS, COUNTS AND DROP FEEDBACK ============
-- Every model on the board: where it lies, and whether it is new (not there when the board
-- opened), moved (another cell) or a duplicate (the same model, see modelKey, twice in one
-- cell). Outlines: green new, yellow moved, red duplicate / on Discard / outside any cell.
-- Also updates the cell counts. Returns the per-unit changes for the Publish report.
local function survey()
    local seen, perCell, byCellKey, models = {}, {}, {}, {}
    for _, obj in ipairs(getAllObjects()) do
        if isModel(obj) then
            local where, c, r = locate(obj.getPosition())
            if where then
                local m = {obj = obj, where = where, c = c, r = r, guid = obj.getGUID()}
                models[#models + 1] = m
                if where == "cell" then
                    local key = c .. ":" .. r
                    perCell[key] = (perCell[key] or 0) + 1
                    local dk = key .. "|" .. keyOf(obj)
                    m.dup = byCellKey[dk] ~= nil
                    byCellKey[dk] = true
                end
                seen[m.guid] = true
            end
        end
    end
    local changes = {}   -- column name -> {new, moved, removed}
    local function bump(c, what)
        local name = board.cols[c].name
        changes[name] = changes[name] or {new = 0, moved = 0, removed = 0}
        changes[name][what] = changes[name][what] + 1
    end
    clearHighlights()
    for _, m in ipairs(models) do
        local from = board.origin[m.guid]
        if m.where ~= "cell" then
            highlight(m.obj, COLOR_BAD)
            if from and m.where == "discard" then bump(tonumber(string.sub(from, 1, string.find(from, ":", 1, true) - 1)), "removed") end
            -- New models not (yet) in a cell are changes too: Close must not drop them unasked.
            if not from and m.where == "board" then changes._loose = (changes._loose or 0) + 1 end
        elseif m.dup then
            highlight(m.obj, COLOR_BAD)
            if not from then bump(m.c, "new") end
        elseif not from then
            highlight(m.obj, COLOR_NEW)
            bump(m.c, "new")
        elseif from ~= m.c .. ":" .. m.r then
            highlight(m.obj, COLOR_MOVED)
            bump(m.c, "moved")
        end
    end
    -- Models that were on the board and are gone (deleted) count as removed.
    for guid, from in pairs(board.origin) do
        if not seen[guid] then bump(tonumber(string.sub(from, 1, string.find(from, ":", 1, true) - 1)), "removed") end
    end
    for key, guid in pairs(board.counts or {}) do
        local label = getObjectFromGUID(guid)
        if label then label.TextTool.setValue(tostring(perCell[key] or 0)) end
    end
    return models, changes
end

function refreshMarks()   -- assigns the local declared above buildBoard
    if board and not busy then survey() end
end

local function changeLines(changes)
    local lines = {}
    for _, col in ipairs(board.cols) do
        local ch = changes[col.name]
        if ch then
            local parts = {}
            if ch.new > 0 then parts[#parts + 1] = "+" .. ch.new .. " new" end
            if ch.moved > 0 then parts[#parts + 1] = ch.moved .. " moved" end
            if ch.removed > 0 then parts[#parts + 1] = ch.removed .. " removed" end
            lines[#lines + 1] = col.name .. ": " .. table.concat(parts, ", ")
        end
    end
    if changes._loose then lines[#lines + 1] = changes._loose .. " new model(s) outside any cell" end
    return lines
end

-- After a drop: the dropped models' cells and counts, then all marks.
local function checkDrops()
    local drops = pendingDrops
    pendingDrops = {}
    if not board or busy then return end
    local models = survey()
    local lines = {}
    for _, obj in ipairs(drops) do
        if obj ~= nil then
            local where, c, r = locate(obj.getPosition())
            if where == "discard" then
                lines[#lines + 1] = "On Discard: removed from the catalog on Publish."
            elseif where == "board" then
                lines[#lines + 1] = "Not in a cell: move it into one."
            elseif where == "cell" then
                local others = {}
                local k = keyOf(obj)
                for _, m in ipairs(models) do
                    if m.obj ~= obj and m.where == "cell" and (m.c ~= c or m.r ~= r) and keyOf(m.obj) == k then
                        others[#others + 1] = cellName(m.c, m.r)
                    end
                end
                local line = cellName(c, r)
                for _, m in ipairs(models) do
                    if m.obj == obj and m.dup then line = line .. ": DUPLICATE, this model is already in this cell." end
                end
                if #others > 0 then
                    line = line .. " (also in " .. table.concat(others, ", ", 1, math.min(#others, 3)) .. (#others > 3 and ", ..." or "") .. ")"
                end
                lines[#lines + 1] = line
            end
        end
    end
    if #lines > 6 then
        local n = #lines
        lines = {lines[1], lines[2], lines[3], lines[4], lines[5], "... and " .. (n - 5) .. " more"}
    end
    if #lines > 0 then setStatus(table.concat(lines, "\n")) end
end

-- ============ PUBLISH ============
-- Sends every model lying in a cell to the bridge listener, one message per column (keeps
-- each message small), which writes catalog/ with tools/publish.py and calls publishDone.
-- Refused while models lie on the board outside any cell, or a cell holds a duplicate.
local function publishBoard()
    if busy or not board then return end
    local models, changes = survey()
    local stray, dups = 0, 0
    for _, m in ipairs(models) do
        if m.where == "board" then stray = stray + 1 end
        if m.dup then dups = dups + 1 end
    end
    if stray > 0 or dups > 0 then
        setStatus((stray > 0 and (stray .. " model(s) lie outside any cell") or "")
            .. (stray > 0 and dups > 0 and " and " or "")
            .. (dups > 0 and (dups .. " duplicate(s) share a cell") or "")
            .. " (red). Fix them, then Publish again.")
        return
    end
    -- Footprints (bounds aren't in the object JSON; the spawner needs them before models load).
    -- Catalog models keep their stored one, copies take their original's (same model), and only
    -- new models are measured. Measuring everything gave models still loading their assets a
    -- size of 0, and export then dropped them from the catalog (tested on a fresh game).
    local sizeByKey = {}
    for _, m in ipairs(models) do
        local sz = board.size[m.guid]
        if sz and m.where == "cell" then sizeByKey[keyOf(m.obj)] = sz end
    end
    local sizes, unmeasured = {}, 0
    for _, m in ipairs(models) do
        if m.where == "cell" then
            local sz = board.size[m.guid] or sizeByKey[keyOf(m.obj)]
            if not sz and not m.obj.loading_custom then
                local b = m.obj.getBounds().size
                if b.x >= MIN_FOOTPRINT and b.z >= MIN_FOOTPRINT then sz = {round(b.x, 2), round(b.z, 2)} end
            end
            if sz then sizes[m.guid] = sz else unmeasured = unmeasured + 1 end
        end
    end
    if unmeasured > 0 then
        setStatus(unmeasured .. " new model(s) are still loading (no size yet). Wait until they show, then Publish again.")
        return
    end
    local byCol = {}
    for _, m in ipairs(models) do
        if m.where == "cell" then
            local col, row = board.cols[m.c], board.rows[m.r]
            local mem = cellMembership(col, row)
            local sz = sizes[m.guid]
            byCol[m.c] = byCol[m.c] or {}
            -- The object's JSON goes in as it is (it already is JSON), so nothing big is encoded.
            table.insert(byCol[m.c], '{"f":' .. JSON.encode(col.f) .. ',"u":' .. JSON.encode(col.u)
                .. ',"kind":' .. JSON.encode(mem.kind) .. ',"ctx":' .. JSON.encode(mem.ctx)
                .. ',"w":' .. sz[1] .. ',"d":' .. sz[2] .. ',"data":' .. m.obj.getJSON() .. '}')
        end
    end
    publishSizes = sizes
    -- sendExternalMessage silently drops messages with nested tables (even a list of strings;
    -- tested), so each part's models travel as one JSON text field. Parts are cut by size
    -- (messages of 1 MB arrived intact, tested; models from source mods can carry big scripts).
    local parts, cur, size = {}, {}, 0
    for c = 1, #board.cols do
        for _, m in ipairs(byCol[c] or {}) do
            if #cur > 0 and size + #m > PART_BYTES then
                parts[#parts + 1] = "[" .. table.concat(cur, ",") .. "]"
                cur, size = {}, 0
            end
            cur[#cur + 1] = m
            size = size + #m
        end
    end
    parts[#parts + 1] = "[" .. table.concat(cur, ",") .. "]"
    busy = true
    publishId = tostring(os.time()) .. tostring(math.random(1000, 9999))
    local id, guid = publishId, self.getGUID()
    local report = changeLines(changes)
    publishLines = report
    local fname = factionIndex[board.f] and factionIndex[board.f].faction.name or board.f
    setStatus("Publishing the " .. fname .. " board...\n"
        .. (#report > 0 and table.concat(report, "\n") or "No changes on the board."))
    for k, models in ipairs(parts) do
        queue[#queue + 1] = function()
            sendExternalMessage({tcm = "publish", id = id, part = k, parts = #parts, board = board.f, guid = guid, models = models})
            return 2
        end
    end   -- models: JSON text, see above
    flushQueue(nil)
    Wait.time(function()
        if publishId == id then
            publishId, busy = nil, false
            setStatus("No answer from the bridge listener after " .. PUBLISH_TIMEOUT .. " s. " .. NO_LISTENER
                .. " The board is unchanged; Publish again.")
        end
    end, PUBLISH_TIMEOUT)
end

-- Called by the bridge listener with the report (a JSON list of lines). The board now matches
-- the catalog: models on Discard go, and every model's current cell becomes its origin.
function publishDone(reportJson)
    if not board then return end
    local ok, report = pcall(JSON.decode, reportJson)
    publishId = nil
    local failed = ok and type(report) == "table" and string.find(tostring(report[1]), "FAILED", 1, true)
    if not failed then
        for _, obj in ipairs(getAllObjects()) do
            if isModel(obj) then
                local where, c, r = locate(obj.getPosition())
                if where == "discard" then
                    obj.destruct()
                elseif where == "cell" then
                    board.origin[obj.getGUID()] = c .. ":" .. r
                    board.size[obj.getGUID()] = publishSizes[obj.getGUID()] or board.size[obj.getGUID()]
                end
            end
        end
        -- Gone objects drop out of the origin list.
        for guid in pairs(board.origin) do
            if not getObjectFromGUID(guid) then board.origin[guid], board.size[guid] = nil, nil end
        end
        saveState()
    end
    busy = false
    local text = ok and type(report) == "table" and table.concat(report, "\n") or tostring(reportJson)
    if #publishLines > 0 then text = table.concat(publishLines, "\n") .. "\n" .. text end
    setStatus(text)
    Wait.frames(function() refreshMarks() end, 5)
end

-- ============ CLOSE BOARD ============
-- Removes the board and every model on it (they are copies of the catalog). With unpublished
-- changes the first press only warns; a second press within 6 s discards them.
local function closeBoard()
    if busy or not board then return end
    local models, changes = survey()
    local pending = changeLines(changes)
    if #pending > 0 and os.time() > closeArmed then
        closeArmed = os.time() + 6
        setStatus("Unpublished changes:\n" .. table.concat(pending, "\n") .. "\nPress Close again within 6 s to discard them, or Publish first.")
        return
    end
    busy = true
    clearHighlights()
    for _, m in ipairs(models) do
        queue[#queue + 1] = function() if m.obj ~= nil then m.obj.destruct() end end
    end
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag(BOARD_TAG) then queue[#queue + 1] = function() if obj ~= nil then obj.destruct() end end end
    end
    flushQueue(function()
        busy = false
        board, keyByGuid = nil, {}
        saveState()
        setStatus("Board closed.")
    end)
end

-- ============ UI CALLBACKS ============
-- XML UI passes (player, value, id). Dropdown value is the selected option's text.
function ui_faction(player, value)
    for _, f in ipairs(config.factions) do
        if f.name == value and f.id ~= sel.f then
            sel.f, sel.focus = f.id, "_"
            saveState()
            render()
            break
        end
    end
end

function ui_focus(player, value)
    local fe = factionIndex[sel.f]
    for _, c in ipairs(fe and contexts(fe) or {}) do
        if "Focus: " .. c.name == value then sel.focus = c.id end
    end
    saveState()
end

function ui_open() openBoard() end
function ui_publish() publishBoard() end
function ui_close() closeBoard() end
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

-- Deleting a model also changes the board (it counts as removed).
function onObjectDestroy(obj)
    if busy or not board or not isModel(obj) then return end
    dropToken = dropToken + 1
    local token = dropToken
    Wait.time(function()
        if token == dropToken then refreshMarks() end
    end, 0.5)
end

function onSave()
    return JSON.encode({f = sel.f, focus = sel.focus, board = board})
end

function onLoad(saved_data)
    if saved_data and saved_data ~= "" then
        local ok, data = pcall(JSON.decode, saved_data)
        if ok and type(data) == "table" then
            sel.f, sel.focus = data.f, data.focus or "_"
            -- An open board's tiles and models were saved with the game; only its geometry
            -- and origins need restoring.
            if type(data.board) == "table" and data.board.frame and data.board.origin then
                board = data.board
                board.size = board.size or {}   -- boards saved before footprints were kept
            end
        end
    end
    render()
    loadConfig()
    if board then Wait.time(function() refreshMarks() end, 3) end
end
