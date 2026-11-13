-- =====================================================================
-- PSEUDOVIRUS CHECK & REMOVE  (Tabletop Simulator object script)
-- =====================================================================
-- Put this script on any object (a block, a token, anything). It gets two buttons:
--   Check   counts the scripts that carry the pseudovirus (changes nothing)
--   Remove  cuts it out of every script in the game
--
-- The "pseudovirus" ("Spawning object" script) spreads through workshop mods: one second after
-- an object loads it copies itself into the script of every object on the table, and into
-- everything spawned later. Its copy sits at the end of a script, after 400 spaces, between
-- the two markers below (VIRUS_START, VIRUS_END). Besides lag, it breaks other scripts:
-- e.g. dice scripts that catch number keys get skipped, so the dice drop again.
--
-- Remove keeps every object and all of its own code. It cleans:
--   - the Global script and every object's own script (hand zones too),
--   - objects inside bags and decks, attached parts and object states: those bags / models are
--     spawned again in the same place with the same contents and the same GUID, only without
--     the pseudovirus (a script can't edit an object while it is inside a bag).
-- The copies that are already running stay loaded until the game is loaded again. They can't
-- spread any more (they copy themselves from their own object's script, which is clean now),
-- but they print an error whenever something spawns. So: Remove, then save the game and load
-- it again. Objects you bring in later from an infected save or saved object can bring it
-- back; press Check now and then.
--
-- From the TC Miniatures spawner (https://github.com/PriestofMork/TTS-TC-Model-Collection),
-- free to share and change.
-- =====================================================================

-- Built from pieces, so this script never contains the markers whole: cleaning this object
-- would otherwise cut its own code.
local VIRUS_START = "--[[Object base" .. " code]]"
local VIRUS_END   = "--[[Spawning" .. " object]]"

local busy = false

-- Trailing whitespace off, by hand: Lua patterns on big scripts fail in TTS ("pattern too complex").
local function rtrim(s)
    local n = #s
    while n > 0 do
        local c = string.byte(s, n)
        if c ~= 32 and c ~= 9 and c ~= 10 and c ~= 13 then break end
        n = n - 1
    end
    return string.sub(s, 1, n)
end

-- The script without the pseudovirus, or nil if it had none.
local function withoutVirus(script)
    if type(script) ~= "string" or not string.find(script, VIRUS_START, 1, true) then return nil end
    local s = script
    while true do
        local a = string.find(s, VIRUS_START, 1, true)
        if not a then break end
        local b = string.find(s, VIRUS_END, a, true)
        local rest = b and string.sub(s, b + #VIRUS_END) or ""
        s = rtrim(string.sub(s, 1, a - 1)) .. rest
    end
    return rtrim(s)
end

-- Cleans the scripts inside object data (contents, attached parts, states; not the object's
-- own) in place; true if anything was cut.
local function cleanNested(d)
    local found = false
    local function each(list)
        for _, c in pairs(list or {}) do
            local clean = withoutVirus(c.LuaScript)
            if clean then c.LuaScript, found = clean, true end
            if cleanNested(c) then found = true end
        end
    end
    each(d.ContainedObjects)
    each(d.ChildObjects)
    each(d.States)
    return found
end

-- Only containers and objects with attached parts can hide copies inside.
local function canHide(o)
    return o.getQuantity() > 0 or #(o.getAttachments() or {}) > 0
end

local function tell(player_color, text)
    print("[Pseudovirus] " .. text)
    if player_color and Player[player_color] and Player[player_color].seated then
        broadcastToColor(text, player_color, {1, 0.85, 0.4})
    end
end

function check(_, player_color)
    if busy then return end
    -- getObjects, not getAllObjects: only getObjects includes hand zones, and the pseudovirus
    -- infects those too.
    local own, inside = 0, 0
    if withoutVirus(Global.getLuaScript()) then own = own + 1 end
    for _, o in ipairs(getObjects()) do
        if withoutVirus(o.getLuaScript()) then own = own + 1 end
        if canHide(o) and cleanNested(o.getData()) then inside = inside + 1 end   -- getData is a copy
    end
    if own + inside == 0 then
        tell(player_color, "No pseudovirus in this game.")
    else
        tell(player_color, "Pseudovirus found: " .. own .. " script(s)"
            .. (inside > 0 and (", and inside " .. inside .. " bag(s) or model(s)") or "")
            .. ". Press Remove to remove it.")
    end
end

-- Cuts every copy out of one object's own script; true if there was one.
local function cleanOwn(o)
    local clean = withoutVirus(o.getLuaScript())
    if clean then o.setLuaScript(clean) end
    return clean ~= nil
end

function remove(_, player_color)
    if busy then return end
    busy = true
    local cleaned = 0
    local g = withoutVirus(Global.getLuaScript())
    if g then Global.setLuaScript(g) cleaned = cleaned + 1 end
    -- First every object's own script, in one go. The running copies infect whatever spawns,
    -- but they copy themselves from their own object's script, so once all scripts are clean,
    -- the objects spawned again below can't catch it.
    local objects = getObjects()
    for _, o in ipairs(objects) do
        if cleanOwn(o) then cleaned = cleaned + 1 end
    end
    -- Then bags and models that hide copies inside: spawned again from their cleaned data, a
    -- few per frame. Each is spawned a frame after the old one is gone, so it keeps its GUID
    -- (other scripts may look it up by GUID).
    local jobs = {}
    for _, o in ipairs(objects) do
        if canHide(o) then jobs[#jobs + 1] = o end
    end
    local i = 0
    local function step()
        for _ = 1, 5 do
            i = i + 1
            local o = jobs[i]
            if not o then break end
            local ok, err = pcall(function()
                if o == nil then return end   -- deleted meanwhile
                local d = o.getData()
                if not cleanNested(d) then return end
                cleaned = cleaned + 1
                local pos, rot = o.getPosition(), o.getRotation()
                o.destruct()
                Wait.frames(function() spawnObjectData({data = d, position = pos, rotation = rot}) end, 1)
            end)
            if not ok then print("[Pseudovirus] " .. tostring(err)) end
        end
        if i < #jobs then
            Wait.frames(step, 1)
            return
        end
        -- A second sweep: an object that loaded just before the click runs the pseudovirus's
        -- "infect everything one second after loading" step afterwards.
        Wait.time(function()
            for _, o in ipairs(getObjects()) do
                if cleanOwn(o) then cleaned = cleaned + 1 end
            end
            busy = false
            if cleaned == 0 then
                tell(player_color, "No pseudovirus in this game.")
            else
                tell(player_color, "Removed the pseudovirus from " .. cleaned .. " script(s). Save the game now and "
                    .. "load it again: the copies already running stay loaded until then.")
            end
        end, 2)
    end
    step()
end

-- Two buttons on top of the object, the same size on any object (button sizes scale with it).
function onLoad()
    -- Measured before the buttons exist (getBoundsNormalized counts buttons).
    local s = self.getScale()
    local top = self.getBoundsNormalized().size.y / 2 / s.y + 0.05
    local scale = {1 / s.x, 1 / s.y, 1 / s.z}
    for i, b in ipairs({{"check", "Check for\npseudovirus", {0.25, 0.25, 0.3}},
                         {"remove", "Remove\npseudovirus", {0.55, 0.15, 0.15}}}) do
        self.createButton({
            click_function = b[1], function_owner = self, label = b[2],
            position = {0, top, (i == 1 and -0.45 or 0.45) / s.z}, rotation = {0, 0, 0}, scale = scale,
            width = 800, height = 380, font_size = 110, color = b[3], font_color = {1, 1, 1},
            tooltip = b[1] == "check" and "Count infected scripts (changes nothing)"
                or "Remove the pseudovirus from every script, then save and reload the game",
        })
    end
end
