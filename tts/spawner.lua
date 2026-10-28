-- =============================================
-- TC MINIATURES - SPAWNER
-- =============================================
-- Contains no models. On load it fetches catalog/version.json and catalog/index.json from
-- GitHub. The spawner (the hub, a tile with art) draws a side console as object XML UI: status
-- beside it, action icons below it, then faction icons with the open faction's unit list next
-- to them. Clicking a unit fetches that unit's file and spawns its models on a labelled
-- platform to the right of the console (clicking it again removes them).
--
-- Spawned objects carry the tag TCM_Spawned and a memo "<token>|<faction>/<unit>". The token
-- is a random id saved in this object's state, so it survives GUID changes (TTS reassigns
-- GUIDs on collision, e.g. when a save with another spawner is loaded).

local SPAWNER_VERSION = 11

-- ===================== CONFIG =====================
local RAW_BASE  = "https://raw.githubusercontent.com/PriestofMork/TTS-TC-Model-Collection/main/"
-- Converter page (docs/index.html on GitHub Pages): Trench Companion export -> import code.
local CODE_PAGE = "https://priestofmork.github.io/TTS-TC-Model-Collection/"
local SPAWN_TAG = "TCM_Spawned"
local MODEL_TAG      = "TCM_Model"        -- models running tts/model.lua
local PLATFORM_NAME  = "TC spawn platform"

-- Layout, in world units relative to the spawner (follows its position and rotation, not its
-- scale). The player reading the spawner sits on its local +z side (tested in TTS: an XML panel
-- with rotation "0 0 180" reads upright from there). The console runs from the hub toward the
-- player; the spawn area lies to its right, its top edge level with the hub's far edge.
local AREA_GAP      = 1.0    -- between the console and the spawn area
-- Each unit is a block (its platform). Blocks are packed into an area AREA_WIDTH wide, rows from
-- the top edge toward the player, nearest free spot first, so a removed unit's space is reused.
local AREA_WIDTH    = 27     -- fits two full-width units (MAX_ROW_WIDTH + margins) side by side
local MAX_ROW_WIDTH = 12     -- a unit's models wrap after this width
local MODEL_PAD     = 0.4    -- space between models in a row
local ROW_GAP       = 0.6    -- space between rows
local LABEL_DEPTH   = 1.1    -- room reserved for a unit's label in front of its first row
local LABEL_CHAR    = 0.4    -- estimated label width per character at LABEL_FONT
local NOTE_DEPTH    = 0.5    -- room for a block's small note line (warbands: how to swap)
local NOTE_FONT     = 20
local NOTE_CHAR     = 0.17   -- estimated note width per character at NOTE_FONT
local BLOCK_GAP     = 0.8    -- space between two units' platforms

-- Each unit stands on its own locked platform, raised above the surface the spawner stands
-- on, so spawned models never land in terrain or on the board.
local PLATFORM_HEIGHT    = 2      -- top of the platform above the spawner's base (inches)
local PLATFORM_THICKNESS = 0.2
local PLATFORM_MARGIN    = 0.5    -- platform border around the label and rows
local PLATFORM_COLOR     = {0.12, 0.12, 0.12}
local SPAWN_HEIGHT       = 0.3    -- models are spawned this far above the platform and settle

-- Catalog models have rotY 0 (export resets it). They get the spawner's yaw plus this.
-- Change to 180 if models come out facing away from the players.
local MODEL_YAW = 0
-- 3D text lying flat on the table: pitch 90. Yaw 180 reads upright for the panel's reader.
local LABEL_PITCH = 90
local LABEL_YAW   = 180
local LABEL_FONT  = 36

local BATCH_SIZE = 15        -- objects spawned or destroyed per frame

local UI_MARGIN = 5          -- console: extra lift above the hub's top face, in UI units

-- Extend UI area: above the spawn area (away from the player), as wide as two units. Any model
-- dropped into it gets the model script (tts/model.lua) with the faction picked in it.
local EXT_GAP    = 2.0       -- between the spawn area's top edge and the Extend area (platforms are 2" high and hide what's just behind them)
local EXT_W      = 14
local EXT_D      = 6
local COL_EXT    = "#E0B050"
local FIGURES    = {Custom_Model = true, Custom_Assetbundle = true, Figurine_Custom = true}

-- Side console, in world inches (the root panel undoes the hub's scale: 100 UI units = 1").
local CON_GAP    = 0.3       -- spacing between console parts
local STATUS_W   = 4.0       -- status box beside the hub
local ACTION     = 1.0       -- action icons below the hub
local ICON       = 1.1       -- faction icons
local LIST_W     = 4.6       -- unit list column
local ROW_H      = 0.46      -- unit rows
local TAB_H      = 0.4       -- subfaction tabs
local TAB_CHAR   = 0.12      -- estimated tab width per character
local COL_TEXT   = "#EEE6D8"
local COL_BOX    = "#0D0B0BD9"                          -- status / import background
local COL_ROW    = "#2A2624|#3A3532|#1E1B1A|#2A2624"    -- normal|hover|pressed|disabled
local COL_ON     = "#7F2119|#9A2A20|#5E1812|#7F2119"    -- unit on the table / chosen tab
local COL_ALL    = "#6B5420|#80662A|#4E3D17|#6B5420"    -- "Spawn whole faction"
local COL_ICON   = "#FFFFFF|#FFFFFF|#CCCCCC|#FFFFFF"
local COL_DIM    = "#707070|#B0B0B0|#909090|#707070"    -- faction icons that aren't open

local UI_TAG     = "TCM_UI"  -- menu tokens of v8 (spawned objects); leftovers are removed on load

-- Art for the action icons (Trench Crusade art by Mike Franchina, hotlinked from ArtStation).
local ART = {
    import   = "https://cdnb.artstation.com/p/assets/images/images/031/677/223/large/mike-franchina-procession-pilgrimage-web.jpg?1604303199",
    settings = "https://cdnb.artstation.com/p/assets/images/images/031/363/803/large/mike-franchina-flak-battery2.jpg?1603392122",
    clear    = "https://cdnb.artstation.com/p/assets/images/images/024/247/491/large/mike-franchina-cardinal-of-malady.jpg?1581794458",
    extend   = "https://cdna.artstation.com/p/assets/images/images/021/700/638/large/mike-franchina-aspect-of-the-wolf-small.jpg?1572626489",
}
-- Faction icons: the same images as the activation token in tts/model.lua.
local ICONS = {
    ["default"]                           = "https://steamusercontent-a.akamaihd.net/ugc/17565077082788158933/75472FA5DF4D9A5A79DFCACCF02E6D044B0AB70F/",
    ["new-antioch"]                       = "https://steamusercontent-a.akamaihd.net/ugc/12140870569665962018/647EDFF35D1397EC9577768D1913B378FD7F36CB/",
    ["trench-pilgrims"]                   = "https://steamusercontent-a.akamaihd.net/ugc/10865693481180792483/AE8CC3A0A475582AAA8BB10EC12569BAC5AF6C1A/",
    ["iron-sultanate"]                    = "https://steamusercontent-a.akamaihd.net/ugc/11011531862432102694/E93E2E25F8A724A188A450B906DFAA25E146F085/",
    ["heretic-legion"]                    = "https://steamusercontent-a.akamaihd.net/ugc/11780656566766941905/005DCBF2BD729C494E5EC0DA58CF0398ABA447A8/",
    ["cult-of-the-black-grail"]           = "https://steamusercontent-a.akamaihd.net/ugc/15933842057862161695/5D24970A3042BDF9747BFC7DC74039B64C17BD99/",
    ["court-of-the-seven-headed-serpent"] = "https://steamusercontent-a.akamaihd.net/ugc/12527179569780597784/62EFCEC8605897141AC23B9F8E49A464589B2001/",
}
-- ==================================================

local index        = nil     -- decoded catalog/index.json
local factionById  = {}
local token        = nil
local sel          = {f = nil, sub = nil}
local spawned      = {}      -- "faction/unit" -> true
local blocks       = {}      -- "faction/unit" -> {x, z, w, d}: its platform in layout units
local busy         = false
local status       = "Loading catalog..."
local renderPending = false
local unitCache    = {}      -- unit file -> decoded entries (for the loaded catalog version)
local scriptsOn    = true    -- put tts/model.lua into spawned models
local modelScript  = nil     -- tts/model.lua, fetched on load
local listMode     = "units" -- what the console's list column shows: "units", "import", "settings"
local importText   = ""      -- what was pasted; kept here, the box itself isn't re-rendered
local extendOn     = false   -- the Extend UI area is shown (and active)
local extendF      = nil     -- faction id picked in the Extend UI area

-- ============ UTIL ============
local function xmlEscape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- The spawner is always the same object: a Custom_Tile with Mike Franchina's Sword Saint art
-- (published at scale 1.5, 1, 1.5). HUB_SIZE is its size at scale 1, measured in TTS; it's a
-- constant because getBoundsNormalized would also count any buttons on the object.
local HUB_SIZE = {x = 2.5686, y = 0.2, z = 2}

-- The spawner's size in world units, rotation ignored.
local function hubBounds()
    local s = self.getScale()
    return {x = HUB_SIZE.x * s.x, y = HUB_SIZE.y * s.y, z = HUB_SIZE.z * s.z}
end

local function uiHeight()
    -- UI units are 100 per local unit.
    local halfLocal = hubBounds().y / 2 / self.getScale().y
    return -math.ceil(halfLocal * 100 + UI_MARGIN)
end

local function tableY()
    local b = self.getBounds()
    return b.center.y - b.size.y / 2
end

-- Spawner-relative (x, z) -> world position at world height y: x to the player's right, z away
-- from them. positionToWorld takes local (scaled) units, so world units are divided by the scale.
local function toWorld(x, z, y)
    local s = self.getScale()
    local pos = self.positionToWorld(Vector(-x / s.x, 0, -z / s.z))
    pos.y = y
    return pos
end

-- The spawn area's left edge (x) and top edge (z), spawner-relative: right of the console's
-- widest part, level with the hub's far edge.
local function areaOrigin()
    local hb = hubBounds()
    local hw = hb.x / 2
    local right = math.max(hw + CON_GAP + STATUS_W, -hw + ICON + CON_GAP + LIST_W)
    return right + AREA_GAP, hb.z / 2
end

-- Layout (x, z) -> world: x from the area's left edge to the right, z from its top edge toward
-- the player.
local function layoutToWorld(x, z, y)
    local x0, top = areaOrigin()
    return toWorld(x0 + x, top - z, y)
end

local function platformTop()
    return tableY() + PLATFORM_HEIGHT
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

local MERC = "mercenaries"

local function contains(list, x)
    for _, v in ipairs(type(list) == "table" and list or {}) do
        if v == x then return true end
    end
    return false
end

-- An entry's s lists the subfactions its model was made for; empty (or "_", where export
-- merged a vanilla copy with themed ones) = the faction's vanilla look.
local function isVanilla(entry)
    local s = type(entry.s) == "table" and entry.s or {}
    return #s == 0 or contains(s, "_")
end

-- Subfaction filter (sel.sub): nil = all models, "_" = vanilla models, a subfaction id =
-- models made for it, or the vanilla ones where a unit has none of its own (subfactions often
-- just use vanilla models). Returns the count and whether it fell back to vanilla.
local function unitCount(unit)
    if not sel.sub then return unit.count, false end
    if sel.sub == "_" then return unit.any or 0, false end
    local n = (unit.subs or {})[sel.sub] or 0
    if n > 0 then return n, false end
    return unit.any or 0, true
end

local function filterEntries(entries)
    if not sel.sub then return entries end
    local themed, vanilla = {}, {}
    for _, e in ipairs(entries) do
        if sel.sub ~= "_" and contains(e.s, sel.sub) then themed[#themed + 1] = e end
        if isVanilla(e) then vanilla[#vanilla + 1] = e end
    end
    return (#themed > 0) and themed or vanilla
end

-- The mercenary units a faction can hire (index.json copies the lists from config/units.json).
-- A subfaction with its own list overrides the faction's (Trench Ghosts hire none). Then the
-- Mercenaries units every warband can get (`everyone`: Golem, an exploration reward), which
-- no subfaction list removes.
local function hiredUnits(fe)
    local mercs, out = factionById[MERC], {}
    if not mercs or fe.id == MERC then return out end
    local hires = fe.mercenaries
    for _, sf in ipairs(fe.subfactions or {}) do
        if sf.id == sel.sub and sf.mercenaries then hires = sf.mercenaries end
    end
    local seen = {}
    for _, uid in ipairs(hires or {}) do
        for _, u in ipairs(mercs.units) do
            if u.id == uid then
                out[#out + 1] = u
                seen[uid] = true
            end
        end
    end
    for _, u in ipairs(mercs.units) do
        if u.everyone and not seen[u.id] then out[#out + 1] = u end
    end
    return out
end

local function subName(fe, id)
    if id == "_" then return "Vanilla" end
    for _, sf in ipairs(fe.subfactions or {}) do
        if sf.id == id then return sf.name end
    end
    return tostring(id)
end

-- ============ STATUS / CONSOLE ============
local render

local function setStatus(text)
    status = text
    render()
end

-- The images the console uses, by name (setCustomAssets fails on a nil URL).
local function loadAssets()
    local assets = {}
    for name, url in pairs(ART) do assets[#assets + 1] = {name = "a_" .. name, url = url} end
    for id, url in pairs(ICONS) do assets[#assets + 1] = {name = "f_" .. id, url = url} end
    self.UI.setCustomAssets(assets)
end

-- Warband import box (in the list column while importing). Trench Companion's export is too big
-- for a TTS text box (Unity cuts UI text at ~16,000 characters), so players turn it into a short
-- code on the converter page first. TTS can't open a browser from a script, so the address is
-- shown in a read-only box to copy. The code box is single-line (only draws the visible part)
-- and read once in onEndEdit; the text lives in importText because re-rendering empties the box.
-- Returns the panel's content and its height in UI units.
local function importBox()
    local x, height = {}, 24   -- 24 = top + bottom padding
    local function row(h, el)
        height = height + h + 6   -- 6 = layout spacing
        x[#x + 1] = el
    end
    row(22, '<Text preferredHeight="22" fontSize="17" alignment="MiddleLeft">1. Open this page in your browser:</Text>')
    row(36, '<InputField preferredHeight="36" fontSize="17" readOnly="true" lineType="SingleLine">'
        .. CODE_PAGE .. '</InputField>')
    row(66, '<Text preferredHeight="66" fontSize="17" alignment="MiddleLeft">2. In Trench Companion: Export Warband, '
        .. 'style "TTS JSON", Copy to Clipboard. Paste it on that page and copy the code. 3. Paste the code here:</Text>')
    row(40, '<InputField id="importBox" preferredHeight="40" fontSize="17" lineType="SingleLine" '
        .. 'characterLimit="0" onEndEdit="ui_importText"></InputField>')
    row(44, '<HorizontalLayout preferredHeight="44" spacing="6">'
        .. '<Button onClick="ui_importModels" colors="' .. COL_ON .. '" fontSize="19">Spawn models</Button>'
        .. '<Button onClick="ui_importSlots" colors="' .. COL_ROW .. '" fontSize="19">Spawn slots</Button>'
        .. '<Button onClick="ui_importCancel" colors="' .. COL_ROW .. '" fontSize="19">Cancel</Button></HorizontalLayout>')
    return '<VerticalLayout padding="12 12 12 12" spacing="6" childForceExpandHeight="false">'
        .. table.concat(x) .. '</VerticalLayout>', height
end

-- The console as one XML panel. Coordinates are world inches relative to the hub's centre,
-- x to the player's right and y away from them (UI y = away: the root is turned "0 0 180" to
-- read from the player's side); the root panel's scale undoes the hub's, so 100 UI units = 1".
-- Clicks go to ui_click with the element's id as the action ("faction:<id>", "unit:<f>/<u>"...).
local function buildXml()
    local hb, sc = hubBounds(), self.getScale()
    local hw, hd = hb.x / 2, hb.z / 2
    local out = {}
    local function n(v) return string.format("%.1f", v * 100) end
    local function put(tag, x, y, w, h, attrs, inner)
        out[#out + 1] = '<' .. tag .. ' position="' .. n(x) .. ' ' .. n(y) .. ' 0" width="' .. n(w) .. '" height="' .. n(h)
            .. '" ' .. (attrs or '') .. '>' .. (inner or '') .. '</' .. tag .. '>'
    end
    local function text(x, y, w, h, str, attrs) put("Text", x, y, w, h, attrs, xmlEscape(str)) end
    -- A clickable row: name on the left, an optional count on the right.
    local function row(x, y, w, h, id, colors, name, count)
        local inner = '<Text width="' .. n(w - 0.24) .. '" height="' .. n(h) .. '" alignment="MiddleLeft">' .. xmlEscape(name) .. '</Text>'
        if count then
            inner = inner .. '<Text width="' .. n(w - 0.24) .. '" height="' .. n(h) .. '" alignment="MiddleRight">' .. count .. '</Text>'
        end
        put("Button", x, y, w, h, 'id="' .. xmlEscape(id) .. '" onClick="ui_click" colors="' .. colors .. '"', inner)
    end

    -- Status beside the hub.
    local sx = hw + CON_GAP + STATUS_W / 2
    put("Panel", sx, 0, STATUS_W, 2 * hd, 'color="' .. COL_BOX .. '"',
        '<Text width="' .. n(STATUS_W - 0.3) .. '" height="' .. n(2 * hd - 0.3) .. '" alignment="UpperLeft" fontSize="26">'
        .. xmlEscape(status) .. '</Text>')

    if not index then
        -- The catalog didn't load (no connection?): a way to try again.
        row(-hb.x / 2 + LIST_W / 2, -hd - CON_GAP - ROW_H / 2, LIST_W, ROW_H, "reload", COL_ROW, "Reload catalog")
    else
        -- Action icons below the hub, with their names under them.
        local ay = -hd - CON_GAP - ACTION / 2
        local actions = {{"import", "Import"}, {"extend", "Extend UI"}, {"settings", "Settings"}, {"clear", "Clear all"}}
        for i, a in ipairs(actions) do
            local x = -hw + ACTION / 2 + (i - 1) * (ACTION + 0.25)
            put("Button", x, ay, ACTION, ACTION, 'id="' .. a[1] .. '" onClick="ui_click" image="a_' .. a[1] .. '" colors="' .. COL_ICON .. '"')
            text(x, ay - ACTION / 2 - 0.15, ACTION + 0.25, 0.28, a[2], 'fontSize="20" alignment="MiddleCenter"'
                .. ((listMode == a[1] or (a[1] == "extend" and extendOn)) and ' color="#E0B050"' or ''))
        end

        -- Faction icons in a column.
        local top = ay - ACTION / 2 - 0.3 - CON_GAP
        for i, f in ipairs(index.factions) do
            local open = sel.f == nil or sel.f == f.id
            put("Button", -hw + ICON / 2, top - ICON / 2 - (i - 1) * (ICON + 0.15), ICON, ICON,
                'id="faction:' .. f.id .. '" onClick="ui_click" image="f_' .. (ICONS[f.id] and f.id or "default")
                .. '" colors="' .. (open and COL_ICON or COL_DIM) .. '"')
        end

        -- The list column next to them.
        local lx = -hw + ICON + CON_GAP
        local cx, y = lx + LIST_W / 2, top
        local fe = factionById[sel.f]
        if listMode == "import" then
            local inner, h = importBox()
            text(cx, y - 0.22, LIST_W, 0.44, "Import warband", 'fontSize="30" fontStyle="Bold" alignment="MiddleLeft"')
            y = y - 0.5
            put("Panel", cx, y - h / 200, LIST_W, h / 100, 'color="' .. COL_BOX .. '"', inner)
        elseif listMode == "settings" then
            text(cx, y - 0.22, LIST_W, 0.44, "Settings", 'fontSize="30" fontStyle="Bold" alignment="MiddleLeft"')
            y = y - 0.5
            row(cx, y - ROW_H / 2, LIST_W, ROW_H, "scripts", COL_ROW, scriptsOn and "Model scripts: on" or "Model scripts: off")
            y = y - ROW_H - 0.06
            row(cx, y - ROW_H / 2, LIST_W, ROW_H, "reload", COL_ROW, "Reload catalog")
        elseif not fe then
            text(cx, y - 0.4, LIST_W, 0.8, "Pick a faction on the left.", 'fontSize="26" alignment="UpperLeft"')
        else
            text(cx, y - 0.22, LIST_W, 0.44, fe.name, 'fontSize="30" fontStyle="Bold" alignment="MiddleLeft"')
            y = y - 0.5
            -- Filter tabs: All models, Vanilla, each subfaction; wrapped into rows.
            local tabs = {{id = "", name = "All models"}, {id = "_", name = "Vanilla"}}
            for _, sf in ipairs(fe.subfactions or {}) do tabs[#tabs + 1] = sf end
            local tx = lx
            for _, t in ipairs(tabs) do
                local w = 0.3 + #t.name * TAB_CHAR
                if tx > lx and tx + w > lx + LIST_W then tx, y = lx, y - TAB_H - 0.08 end
                local chosen = (t.id == "" and sel.sub == nil) or t.id == sel.sub
                put("Button", tx + w / 2, y - TAB_H / 2, w, TAB_H, 'id="sub:' .. t.id .. '" onClick="ui_click" fontSize="20" textColor="'
                    .. COL_TEXT .. '" colors="' .. (chosen and COL_ON or COL_ROW) .. '"', xmlEscape(t.name))
                tx = tx + w + 0.08
            end
            y = y - TAB_H - 0.2
            -- Units with their model counts under the filter, then the mercenaries it hires.
            local any = false
            local function unitRow(f, u, merc)
                local count, fallback = unitCount(u)
                if count == 0 then return end
                any = true
                local key = unitKey(f, u.id)
                row(cx, y - ROW_H / 2, LIST_W, ROW_H, "unit:" .. key, spawned[key] and COL_ON or COL_ROW,
                    u.name .. (merc and " (merc)" or "") .. (fallback and " (vanilla)" or ""), count)
                y = y - ROW_H - 0.06
            end
            for _, u in ipairs(fe.units) do unitRow(fe.id, u) end
            for _, u in ipairs(hiredUnits(fe)) do unitRow(MERC, u, true) end
            y = y - 0.1
            row(cx, y - ROW_H / 2, LIST_W, ROW_H, "all", any and COL_ALL or COL_ROW,
                any and "Spawn whole faction" or "No models for this filter")
        end
    end

    -- Extend UI area above the spawn area. Its fill, frame and texts don't take clicks
    -- (raycastTarget false), so models standing on it can still be picked up.
    if index and extendOn then
        local ax, top = areaOrigin()
        local y0 = top + EXT_GAP                -- edge toward the player
        local cx, cy = ax + EXT_W / 2, y0 + EXT_D / 2
        local deco = 'raycastTarget="false" color="' .. COL_EXT .. '"'
        put("Panel", cx, cy, EXT_W, EXT_D, 'raycastTarget="false" color="#E0B05018"')
        put("Panel", cx, y0, EXT_W, 0.06, deco)
        put("Panel", cx, y0 + EXT_D, EXT_W, 0.06, deco)
        put("Panel", ax, cy, 0.06, EXT_D, deco)
        put("Panel", ax + EXT_W, cy, 0.06, EXT_D, deco)
        text(cx, y0 + EXT_D - 0.4, EXT_W - 0.5, 0.5, "Extend UI: drop any model in here",
            'raycastTarget="false" fontSize="34" fontStyle="Bold" alignment="MiddleLeft"')
        text(cx, y0 + EXT_D - 0.9, EXT_W - 0.5, 0.4, "It gets the TC model script (activation, dice, tokens, "
            .. "range rings) with this faction's icon:", 'raycastTarget="false" fontSize="22" alignment="MiddleLeft"')
        for i, f in ipairs(index.factions) do
            put("Button", ax + 0.65 + (i - 1) * 0.95, y0 + EXT_D - 1.6, 0.8, 0.8,
                'id="extendf:' .. f.id .. '" onClick="ui_click" image="f_' .. (ICONS[f.id] and f.id or "default")
                .. '" colors="' .. (extendF == f.id and COL_ICON or COL_DIM) .. '"')
        end
    end

    return '<Defaults><Text color="' .. COL_TEXT .. '" fontSize="24"/><Button textColor="' .. COL_TEXT .. '" fontSize="24"/></Defaults>'
        .. '<Panel position="0 0 ' .. uiHeight() .. '" rotation="0 0 180" width="0" height="0" scale="'
        .. 1 / sc.x .. ' ' .. 1 / sc.z .. ' 1">' .. table.concat(out) .. '</Panel>'
end

-- Coalesce several render() calls in one frame.
function render()
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

local function spawnLabel(text, pos, memo, fontSize)
    local yaw = self.getRotation().y
    spawnObject({
        type     = "3DText",
        position = pos,
        rotation = {LABEL_PITCH, yaw + LABEL_YAW, 0},
        callback_function = function(obj)
            obj.TextTool.setValue(text)
            obj.TextTool.setFontSize(fontSize or LABEL_FONT)
            obj.memo = memo
            obj.addTag(SPAWN_TAG)
        end,
    })
end

-- state: the model script's starting state ({f = faction for the activation icon, u = unit
-- id for swapping, member = true for warband members}). raw: the data brings its own script
-- (warband slots) and is spawned as is. size: rescale to {x, z} once spawned (slots are
-- plain blocks whose native size isn't known up front).
local function spawnModel(data, pos, memo, state, raw, size)
    local t = data.Transform or {}
    -- The model script and its starting state go into the data, so no "extend" step is
    -- needed. The data is cached per unit, so both are set (or cleared) on every spawn.
    if not raw then
        if scriptsOn and modelScript then
            data.LuaScript = modelScript
            data.LuaScriptState = JSON.encode(state or {})
        else
            data.LuaScript, data.LuaScriptState = nil, nil
        end
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
            if size then
                local b, sc = obj.getBoundsNormalized().size, obj.getScale()
                obj.setScale({sc.x * size[1] / b.x, sc.y * 0.1 / b.y, sc.z * size[2] / b.z})
            end
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
-- MAX_ROW_WIDTH, each row as deep as its deepest model. items = {data=, w=, d=, state=, raw=,
-- size=, label=} (see spawnModel; label = small text on the item); w/d come from the intake
-- because bounds aren't known before the models load.
-- Nearest free spot for a w x d block: the smallest z, then the leftmost x, at which it overlaps
-- no other block (bottom-left packing). Candidates are the area's edge and the edges of the
-- blocks already there. x is the block's left edge, from 0 (the area's left edge); z its top
-- edge. A block wider than the area gets a row of its own.
local function findSpot(w, d)
    local left = 0
    local xs, zs = {left}, {0}
    for _, b in pairs(blocks) do
        xs[#xs + 1] = b.x + b.w + BLOCK_GAP
        zs[#zs + 1] = b.z + b.d + BLOCK_GAP
    end
    table.sort(xs)
    table.sort(zs)
    local function free(x, z)
        for _, b in pairs(blocks) do
            if x < b.x + b.w + BLOCK_GAP and b.x < x + w + BLOCK_GAP
                and z < b.z + b.d + BLOCK_GAP and b.z < z + d + BLOCK_GAP then return false end
        end
        return true
    end
    for _, z in ipairs(zs) do
        for _, x in ipairs(xs) do
            if (x + w <= left + AREA_WIDTH or x == left) and free(x, z) then return x, z end
        end
    end
    return left, zs[#zs]   -- not reached: the last z is behind every block
end

-- note: an optional small line in front of the label (warbands: how to swap models).
local function queueBlock(key, label, items, note)
    local memo = token .. "|" .. key
    local noteDepth = note and NOTE_DEPTH or 0

    -- First the block's own layout, relative to its centre line (x) and its edge facing the
    -- player (z, growing away from them): the note and label there, the rows behind them.
    local z = PLATFORM_MARGIN + noteDepth + LABEL_DEPTH
    local placed = {}   -- {item, x, z}

    local x, rowDepth, row, widest = 0, 0, {}, 0   -- x = width used so far in this row
    local function flushRow()
        local rowWidth = x - MODEL_PAD
        if rowWidth > widest then widest = rowWidth end
        for _, item in ipairs(row) do
            placed[#placed + 1] = {item = item.item, x = item.x - rowWidth / 2, z = z + rowDepth / 2}
        end
        z = z + rowDepth + ROW_GAP
        x, rowDepth, row = 0, 0, {}
    end

    for _, item in ipairs(items) do
        local w, d = item.w or 1.5, item.d or 1.5
        if #row > 0 and x + w > MAX_ROW_WIDTH then flushRow() end
        row[#row + 1] = {item = item, x = x + w / 2}
        x = x + w + MODEL_PAD
        if d > rowDepth then rowDepth = d end
    end
    if #row > 0 then flushRow() end

    -- The platform covers the label and the widest row. Then the block gets its place.
    local depth = z - ROW_GAP + PLATFORM_MARGIN
    local width = math.max(widest, #label * LABEL_CHAR, note and #note * NOTE_CHAR or 0) + 2 * PLATFORM_MARGIN
    local bx, bz = findSpot(width, depth)
    blocks[key] = {x = bx, z = bz, w = width, d = depth}
    local cx, top = bx + width / 2, platformTop()

    -- Layout z grows toward the player, so the block's player edge is at bz + depth.
    local front = bz + depth
    local platformPos = layoutToWorld(cx, bz + depth / 2, top - PLATFORM_THICKNESS / 2)
    queue[#queue + 1] = function()
        spawnPlatform(platformPos, width, depth, memo)
        return 5   -- let the platform exist and be scaled before models drop onto it
    end
    local labelPos = layoutToWorld(cx, front - PLATFORM_MARGIN - noteDepth - LABEL_DEPTH / 2, top + 0.05)
    queue[#queue + 1] = function() spawnLabel(label, labelPos, memo) end
    if note then
        local notePos = layoutToWorld(cx, front - PLATFORM_MARGIN - noteDepth / 2, top + 0.05)
        queue[#queue + 1] = function() spawnLabel(note, notePos, memo, NOTE_FONT) end
    end
    for _, p in ipairs(placed) do
        local it = p.item
        local pos = layoutToWorld(cx + p.x, front - p.z, top + SPAWN_HEIGHT)
        queue[#queue + 1] = function() spawnModel(it.data, pos, memo, it.state, it.raw, it.size) end
        if it.label then
            local lpos = layoutToWorld(cx + p.x, front - p.z, top + 0.35)
            queue[#queue + 1] = function() spawnLabel(it.label, lpos, memo, 18) end
        end
    end

    spawned[key] = true
    saveState()
end

-- Hired mercenaries spawned from a faction's menu get that faction's activation icon.
local function queueUnit(f, unit, entries)
    local items = {}
    for _, e in ipairs(entries) do
        items[#items + 1] = {data = e.data, w = e.w, d = e.d, state = {f = sel.f or f, u = unit.id}}
    end
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

-- Spawns the given units ({f =, unit =}) one after another, then calls done.
local function spawnUnits(units, done)
    local i, total = 0, 0
    local function nextUnit()
        i = i + 1
        local job = units[i]
        if not job then
            flushQueue(function() done(total) end)
            return
        end
        local unit = job.unit
        setStatus("Loading " .. unit.name .. "...")
        fetchUnit(unit, function(entries)
            if entries then
                local list = filterEntries(entries)
                if #list > 0 then
                    queueUnit(job.f, unit, list)
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

-- Warband slot: a flat locked tile that holds one member's name and description. Any model
-- put on it gets them (and, if it runs the model script, becomes that member: activation,
-- swapping). Used to dress models a player picked themselves, or to update existing ones.
local SLOT_SCRIPT = [[
-- TC Miniatures warband slot: put a model on this tile and it becomes this warband member.
function onLoad(saved_data)
    member = (saved_data ~= "" and JSON.decode(saved_data)) or {}
end

function onObjectDrop(player_color, obj)
    if obj == nil or obj == self or obj.type == "Dice" or obj.name == "3DText" or not member.name then return end
    local p, c = obj.getPosition(), self.getPosition()
    local r = math.max(self.getBounds().size.x, self.getBounds().size.z) / 2 + 0.2
    if (p.x - c.x) ^ 2 + (p.z - c.z) ^ 2 > r * r then return end
    obj.setName(member.name)
    obj.setDescription(member.desc)
    if obj.hasTag("TCM_Model") then obj.call("becomeMember", {f = member.f, u = member.u}) end
    self.setColorTint({0.2, 0.45, 0.2})   -- filled
end
]]

local function slotData(name, desc, f, u, shortName)
    return {
        Name = "BlockSquare",
        Nickname = shortName,
        Transform = {posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1},
        ColorDiffuse = {r = 0.3, g = 0.3, b = 0.3},
        Locked = true,
        LuaScript = SLOT_SCRIPT,
        LuaScriptState = JSON.encode({name = name, desc = desc, f = f, u = u}),
    }
end

-- Which catalog models a warband member may get: the first non-empty of
--   1. models picked for imports of the chosen subfaction (i contains it),
--   2. models made for that subfaction (s contains it),
--   3. models picked for vanilla imports (i contains a vanilla key),
--   4. vanilla models,  5. any model of the unit.
-- theme = the chosen subfaction or nil. vanillaKeys: {"_"} for a faction's own units; for
-- hired mercenaries the warband's faction id first (its maintainer pick), then "_".
local function importPicks(all, theme, vanillaKeys)
    local function where(test)
        local out = {}
        for _, e in ipairs(all) do
            if test(e) then out[#out + 1] = e end
        end
        return out
    end
    local steps = {}
    if theme then
        steps[#steps + 1] = function(e) return contains(e.i, theme) end
        steps[#steps + 1] = function(e) return contains(e.s, theme) end
    end
    for _, k in ipairs(vanillaKeys) do
        steps[#steps + 1] = function(e) return contains(e.i, k) end
    end
    steps[#steps + 1] = isVanilla
    for _, test in ipairs(steps) do
        local list = where(test)
        if #list > 0 then return list end
    end
    return all
end

-- Spawns a whole warband on one platform labelled with its name. Each warband member gets a
-- catalog model of its unit (found by its Trench Companion model id, whatever faction is open
-- in the console); copies of the same unit get different models where the catalog has several.
-- The export doesn't name the warband's subfaction, so models come from the vanilla picks.
-- Mercenaries get the warband's faction (the most common one) for their activation icon.
-- mode "models": catalog models (see importPicks). mode "slots": one slot per member instead.
local function importWarband(warband, mode, done)
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
    local warbandFaction, best = nil, 0
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
    if mode == "slots" then units = {} end   -- slots don't need any catalog models
    local entriesByKey, i = {}, 0
    local function finish()
        local items, used = {}, {}
        for _, mb in ipairs(members) do
            local key, uid = unitKey(mb.hit.f, mb.hit.unit.id), mb.hit.unit.id
            local name, desc = nameBlock(mb.m), describe(mb.m)
            if mode == "slots" then
                items[#items + 1] = {data = slotData(name, desc, warbandFaction, uid, tostring(mb.m.name)),
                                     w = 1.4, d = 1.4, raw = true, size = {1.3, 1.3}, label = tostring(mb.m.name)}
            else
                local merc = mb.hit.f == MERC and warbandFaction ~= nil
                local list = importPicks(entriesByKey[key] or {}, nil, merc and {warbandFaction, "_"} or {"_"})
                if #list > 0 then
                    used[key] = (used[key] or 0) + 1
                    local e = list[(used[key] - 1) % #list + 1]
                    local data = JSON.decode(JSON.encode(e.data))   -- own copy: name/description differ
                    data.Nickname = name
                    data.Description = desc
                    items[#items + 1] = {data = data, w = e.w, d = e.d,
                                         state = {f = warbandFaction, u = uid, member = true}}
                end
            end
        end
        if #items > 0 then
            local name = tostring(warband["warband-name"] or "Warband")
            queueBlock("warband/" .. tostring(warband["warband-id"] or name) .. "/" .. mode,
                name .. (mode == "slots" and " - slots" or ""), items,
                mode == "models" and "To swap a model: drop another model of the same unit on it (while it stands here)" or nil)
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
    if key then spawned[key], blocks[key] = nil, nil else spawned, blocks = {}, {} end
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
    if sel.f and not factionById[sel.f] then sel.f, sel.sub = nil, nil end
    setStatus("Catalog version " .. tostring(data.version) .. " loaded. Pick a faction on the left, then click units to spawn them.")
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

-- ============ CONSOLE ACTIONS ============
local function notBusy()
    if busy then setStatus("Still busy, try again in a moment.") end
    return not busy
end

local ACTIONS = {}

-- A faction icon opens its unit list; clicking the open one closes it.
function ACTIONS.faction(fid)
    listMode = "units"
    if sel.f == fid then
        sel.f, sel.sub = nil, nil
        setStatus("Pick a faction.")
    else
        sel.f, sel.sub = fid, nil
        setStatus(factionById[fid].name .. ": click a unit to spawn it, click it again to remove it.")
    end
    saveState()
end

function ACTIONS.sub(id)
    sel.sub = (id ~= "" and id) or nil
    saveState()
    render()
end

-- key = "faction/unit" (a hired mercenary is listed under the faction that hires it).
function ACTIONS.unit(key)
    if not notBusy() or not index then return end
    local slash = string.find(key or "", "/", 1, true)
    if not slash then return end
    local fe, uid = factionById[string.sub(key, 1, slash - 1)], string.sub(key, slash + 1)
    if not fe then return end
    busy = true
    if spawned[key] then
        clearSpawned(key, function(n)
            busy = false
            setStatus("Removed " .. n .. " object(s).")
        end)
        return
    end
    for _, u in ipairs(fe.units) do
        if u.id == uid then
            spawnUnits({{f = fe.id, unit = u}}, function(n)
                busy = false
                setStatus("Spawned " .. n .. " model(s) of " .. u.name .. ".")
            end)
            return
        end
    end
    busy = false
end

ACTIONS["all"] = function()
    if not notBusy() or not index then return end
    local fe = factionById[sel.f]
    if not fe then return end
    local units = {}
    for _, u in ipairs(fe.units) do
        if unitCount(u) > 0 and not spawned[unitKey(fe.id, u.id)] then units[#units + 1] = {f = fe.id, unit = u} end
    end
    if #units == 0 then setStatus("Everything in this faction is already spawned.") return end
    busy = true
    spawnUnits(units, function(n)
        busy = false
        setStatus("Spawned " .. n .. " model(s) from " .. fe.name .. ".")
    end)
end

function ACTIONS.clear()
    if not notBusy() then return end
    busy = true
    clearSpawned(nil, function(n)
        busy = false
        setStatus("Removed " .. n .. " object(s).")
    end)
end

-- Import and Settings swap the list column; clicking them again goes back to the units.
function ACTIONS.import()
    if listMode == "import" then listMode = "units" render() return end
    if not notBusy() then return end
    listMode, importText = "import", ""
    setStatus('In Trench Companion: Export Warband, export style "TTS JSON", Copy to Clipboard. '
        .. "Then follow the steps in the import box.")
end

-- Extend UI shows / hides its drop area; the faction defaults to the one open in the console.
function ACTIONS.extend()
    extendOn = not extendOn
    if extendOn and not extendF then extendF = sel.f or (index and index.factions[1].id) end
    saveState()
    setStatus(extendOn and "Drop any model into the Extend UI area to give it the TC model script. "
        .. "Pick the faction for its activation icon there." or "Extend UI area hidden.")
end

function ACTIONS.extendf(fid)
    extendF = fid
    saveState()
    render()
end

function ACTIONS.settings()
    listMode = (listMode == "settings") and "units" or "settings"
    render()
end

function ACTIONS.reload() listMode = "units" loadCatalog() end

function ACTIONS.scripts()
    scriptsOn = not scriptsOn
    saveState()
    setStatus(scriptsOn and "New models get the model script (activation, dice, range rings)."
        or "New models spawn without scripts.")
end

-- XML clicks: the element's id is "<action>" or "<action>:<arg>".
function ui_click(player, value, id)
    local colon = string.find(id or "", ":", 1, true)
    local action, arg = id, nil
    if colon then action, arg = string.sub(id, 1, colon - 1), string.sub(id, colon + 1) end
    local fn = ACTIONS[action]
    if fn then
        local ok, err = pcall(fn, arg)
        if not ok then setStatus("Error: " .. tostring(err)) end
    end
end


-- Global event: a model dropped into the Extend UI area gets the model script with the picked
-- faction (models that already run it only change faction). The script is installed like the
-- spawner's own self-update: state first, then the script, then reload.
local function inExtendArea(pos)
    local l, s = self.positionToLocal(pos), self.getScale()
    local x, y = -l.x * s.x, -l.z * s.z   -- the console's coordinates (see toWorld)
    local ax, top = areaOrigin()
    return x >= ax and x <= ax + EXT_W and y >= top + EXT_GAP and y <= top + EXT_GAP + EXT_D
end

function onObjectDrop(player_color, obj)
    if not extendOn or obj == nil or obj == self or not FIGURES[obj.name] then return end
    if not inExtendArea(obj.getPosition()) then return end
    local fe = factionById[extendF]
    local fname = fe and fe.name or "no faction"
    if obj.hasTag(MODEL_TAG) then
        obj.call("setFaction", {f = extendF})
        setStatus(obj.getName() .. " now shows the " .. fname .. " activation icon.")
        return
    end
    if not modelScript then
        setStatus("The model script isn't loaded (no connection?). Try Settings > Reload catalog.")
        return
    end
    obj.UI.setXml("")
    obj.script_state = JSON.encode({f = extendF, taken = true})
    obj.setLuaScript(modelScript)
    obj.reload()   -- replaces the object; obj isn't used afterwards
    setStatus("Gave the TC model script to a model (" .. fname .. " activation icon).")
end

-- ============ WARBAND IMPORT CALLBACKS (XML) ============
-- Unpacks a code from the converter page ("TCM1" + JSON, see docs/index.html) into the shape
-- of Trench Companion's TTS export that importWarband reads. Returns nil if it isn't a code.
local function decodeWarband(text)
    text = string.gsub(text or "", "^%s+", "")
    if string.sub(text, 1, 4) ~= "TCM1" then return nil end
    local ok, c = pcall(JSON.decode, string.sub(text, 5))
    if not ok or type(c) ~= "table" or type(c.s) ~= "table" or type(c.m) ~= "table" then return nil end
    local S = c.s
    local function str(i) return S[(tonumber(i) or -1) + 1] end   -- indexes are 0-based
    local function list(ids, field)
        local out = {}
        for _, i in ipairs(ids or {}) do out[#out + 1] = {[field] = str(i)} end
        return out
    end
    local models = {}
    for _, m in ipairs(c.m) do
        local equipment = {}
        for _, e in ipairs(m[8] or {}) do
            local abilities = {}
            for k = 3, #e do abilities[#abilities + 1] = {["ability-name"] = str(e[k])} end
            equipment[#equipment + 1] = {["equipment-name"] = str(e[1]), ["equipment-type"] = str(e[2]),
                                         ["equipment-abilities"] = abilities}
        end
        models[#models + 1] = {
            ["model-id"] = str(m[1]), ["model-name"] = str(m[2]), name = str(m[3]),
            ["stat-move"] = str(m[4]), ["stat-melee"] = str(m[5]), ["stat-ranged"] = str(m[6]), ["stat-armour"] = str(m[7]),
            equipment = equipment,
            abilities = list(m[9], "ability-name"),
            upgrades = list(m[10], "upgrade-name"),
            advancements = list(m[11], "advancement-name"),
            injuries = list(m[12], "injury-name"),
            keywords = list(m[13], "keyword-name"),
        }
    end
    return {["warband-name"] = c.n, ["warband-id"] = c.i, models = models}
end

function ui_importCancel()
    listMode, importText = "units", ""
    setStatus("Import cancelled.")
end

function ui_importText(player, value) importText = value or "" end

local function importGo(mode)
    if busy then return end
    local warband = decodeWarband(importText)
    if not warband or #warband.models == 0 then
        setStatus("That isn't a warband code. Make one on the page in the import box from your Trench Companion "
            .. "TTS export, copy it with the Copy button and paste it there.")
        return
    end
    listMode, importText, busy = "units", "", true
    importWarband(warband, mode, function(n, order, missing)
        busy = false
        local text = (mode == "slots" and ("Spawned " .. n .. " slot(s) for ") or ("Imported " .. n .. " model(s) of "))
            .. tostring(warband["warband-name"]) .. "."
        if mode == "slots" then
            text = text .. " Put a model on each slot to give it that member's name and rules."
        else
            text = text .. " Don't like a model? Spawn its unit and drop another model on it (or one of your own "
                .. "from the Extend UI area) while it's still on the platform."
        end
        if #order > 0 then
            local parts = {}
            for _, name in ipairs(order) do parts[#parts + 1] = name .. (missing[name] > 1 and (" x" .. missing[name]) or "") end
            text = text .. " Not in the catalog yet: " .. table.concat(parts, ", ")
        end
        setStatus(text)
    end)
end

function ui_importModels() importGo("models") end
function ui_importSlots() importGo("slots") end

-- ============ SAVE / LOAD ============
function onSave()
    return JSON.encode({token = token, blocks = blocks, f = sel.f, sub = sel.sub, extendOn = extendOn, extendF = extendF,
                        scriptsOn = scriptsOn})
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
                token = data.token
                if type(data.blocks) == "table" then blocks = data.blocks end
                sel.f, sel.sub = data.f, data.sub
                extendOn, extendF = data.extendOn == true, data.extendF
                if data.scriptsOn == false then scriptsOn = false end
            end
        end
    end)
    if not token then
        math.randomseed(os.time())
        token = "tcm" .. os.time() .. math.random(100000, 999999)
        saveState()
    end
    self.setVectorLines({})   -- older versions drew a spawn-area outline
    loadAssets()
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
            -- Places of units that are gone (deleted by hand) are free again.
            for key in pairs(blocks) do
                if not spawned[key] then blocks[key] = nil end
            end
            -- Menu tokens of v8 (spawned objects) saved with the game.
            for _, obj in ipairs(getAllObjects()) do
                if obj.hasTag(UI_TAG) and string.find(obj.memo or "", prefix, 1, true) == 1 then obj.destruct() end
            end
        end)
        step("loading the catalog", loadCatalog)
    end, 1)
end
