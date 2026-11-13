"""Regression test for tts/spawner.lua in a running Tabletop Simulator (through the bridge).

    python tools/tts_bridge.py listen        (in the background, as for debugging)
    python tools/tts_spawner_test.py [--keep]

Serves this repo folder on http://127.0.0.1:8765 and spawns its own test hub running the
local tts/spawner.lua pointed at it, so it tests the local catalog and scripts before anything
is pushed. Checks: catalog load, spawning a unit (platform, label, models with tag, memo,
stripped model script, faction), reload keeps the unit, clicking it again removes it, warband
import (legacy/example-export-new-antioch.json), the Extend UI area, and Clear all (skipped if
other spawned objects are on the table: Clear all removes every spawned object). Removes
everything it made unless --keep is given.
"""

import argparse
import functools
import http.server
import json
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tts_test as t   # lua(), check(), long_string(), results

ROOT = Path(__file__).resolve().parent.parent
PORT = 8765
HUB_ART = "https://cdnb.artstation.com/p/assets/images/images/022/892/925/large/mike-franchina-sword-saint-female.jpg?1577126961"
UNIT = ("mercenaries", "observer")   # a small unit
GROUPED = ("new-antioch", "combat-medic")   # few models, several themes (theme headings)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve():
    """Serves the repo; None if the port is taken (the bridge listener already serves it)."""
    handler = functools.partial(QuietHandler, directory=str(ROOT))
    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), handler)
    except OSError:
        return None
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def warband_code():
    """The converter page's code (docs/index.html makeCode) for the New Antioch sample."""
    exp = json.loads((ROOT / "legacy" / "example-export-new-antioch.json").read_text(encoding="utf-8"))
    strings, index = [], {}

    def s(x):
        x = "" if x is None else str(x)
        if x not in index:
            index[x] = len(strings)
            strings.append(x)
        return index[x]

    def names(lst, field):
        return [s(e.get(field)) for e in (lst or [])]

    models = [[s(m.get("model-id")), s(m.get("model-name")), s(m.get("name")), s(m.get("stat-move")),
               s(m.get("stat-melee")), s(m.get("stat-ranged")), s(m.get("stat-armour")),
               [[s(e.get("equipment-name")), s(e.get("equipment-type"))] + names(e.get("equipment-abilities"), "ability-name")
                for e in (m.get("equipment") or [])],
               names(m.get("abilities"), "ability-name"), names(m.get("upgrades"), "upgrade-name"),
               names(m.get("advancements"), "advancement-name"), names(m.get("injuries"), "injury-name"),
               names(m.get("keywords"), "keyword-name")] for m in exp["models"]]
    return "TCM1" + json.dumps({"n": exp.get("warband-name") or "Warband", "i": exp.get("warband-id"),
                                "s": strings, "m": models}, separators=(",", ":"), ensure_ascii=False), len(models)


def wait_for(fn, timeout=60, step=0.5):
    end = time.time() + timeout
    value = fn()
    while not value and time.time() < end:
        time.sleep(step)
        value = fn()
    return value


def count(memo_part, model_only=True):
    tag = "o.hasTag('TCM_Model')" if model_only else "true"
    return t.lua(f"""local n = 0
for _, o in ipairs(getAllObjects()) do
    if {tag} and string.find(o.memo or '', {json.dumps(memo_part)}, 1, true) then n = n + 1 end
end return n""")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="don't remove the test objects")
    args = parser.parse_args()
    server = serve()
    script = (ROOT / "tts" / "spawner.lua").read_text(encoding="utf-8").replace(
        "https://raw.githubusercontent.com/PriestofMork/TTS-TC-Model-Collection/main/", f"http://127.0.0.1:{PORT}/")
    # In a game infected with the self-spreading "Spawning object" script everything spawned
    # catches it (and its hooks slow every spawn down), so the Extend checks can't pass there.
    infected = t.lua("""local n = 0 for _, o in ipairs(getObjects()) do
    if string.find(o.getLuaScript() or '', '--[[Object base' .. ' code]]', 1, true) then n = n + 1 end
end return n""")
    if infected:
        print(f"STOP: {infected} object(s) carry the 'Spawning object' virus. Remove it (spawner Settings > "
              "Remove virus), save and load the game again, then rerun this test.")
        sys.exit(1)
    others = t.lua("local n = 0 for _, o in ipairs(getAllObjects()) do if o.hasTag('TCM_Spawned') then n = n + 1 end end return n")
    hub = None
    try:
        hub = run(script, others == 0)
    finally:
        if hub and not args.keep:
            t.lua(f"""local hub = getObjectFromGUID('{hub}')
local token = hub and JSON.decode(hub.script_state).token or 'none'
for _, o in ipairs(getAllObjects()) do
    if o.hasTag('TCM_Test') or string.find(o.memo or '', token, 1, true) == 1 then o.destruct() end
end
if hub then hub.destruct() end return 0""")
        if server:
            server.shutdown()
    failed = t.results.count(False)
    print(f"\n{len(t.results) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def run(script, may_clear):
    index = json.loads((ROOT / "catalog" / "index.json").read_text(encoding="utf-8"))
    unit = next(u for f in index["factions"] if f["id"] == UNIT[0] for u in f["units"] if u["id"] == UNIT[1])

    hub = t.lua(f"""local o = spawnObjectData({{data = {{
    Name = 'Custom_Tile', Nickname = 'TC test hub', Tags = {{'TCM_Test'}},
    Transform = {{posX = 0, posY = 2, posZ = 0, rotX = 0, rotY = 180, rotZ = 0, scaleX = 1.5, scaleY = 1, scaleZ = 1.5}},
    CustomImage = {{ImageURL = '{HUB_ART}', ImageSecondaryURL = '', ImageScalar = 1, WidthScale = 0,
                   CustomTile = {{Type = 0, Thickness = 0.2, Stackable = false, Stretch = true}}}},
    LuaScript = {t.long_string(script)}}}}})
return o.getGUID()""")

    def status():
        return t.lua(f"""local x = getObjectFromGUID('{hub}').UI.getXml()
local i = string.find(x, 'fontSize="26">', 1, true)
return i and string.sub(x, i + 14, i + 300) or ''""")

    loaded = wait_for(lambda: "loaded" in status(), timeout=30)
    t.check("load: catalog loaded", bool(loaded), status())
    if not loaded:
        return hub
    time.sleep(2)   # the model script is fetched after the index

    # --- spawn a unit --------------------------------------------------------------------
    key = f"{UNIT[0]}/{UNIT[1]}"
    t.lua(f"ui_click(nil, nil, 'faction:{UNIT[0]}') ui_click(nil, nil, 'unit:{key}') return 0", guid=hub)
    n = wait_for(lambda: count("|" + key) >= unit["count"] and count("|" + key), timeout=60)
    t.check(f"spawn: all {unit['count']} models of {unit['name']}", n == unit["count"], n)
    info = t.lua(f"""local r = {{platform = 0, label = 0}}
for _, o in ipairs(getAllObjects()) do
    if string.find(o.memo or '', '|{key}', 1, true) then
        if o.getName() == 'TC spawn platform' then r.platform = r.platform + 1
        elseif o.name == '3DText' then r.label = r.label + 1
        elseif o.hasTag('TCM_Model') and not r.model then
            local sc = o.getLuaScript()
            r.model = {{tag = o.hasTag('TCM_Spawned'), name = o.getName(), kb = math.floor(#sc / 1024),
                       comments = string.find(sc, '-- ====', 1, true) ~= nil, f = o.getTable('state').f}}
        end
    end
end return r""")
    t.check("spawn: one platform and one label", info["platform"] == 1 and info["label"] == 1, info)
    m = info.get("model") or {}
    t.check("spawn: model has spawn tag and unit name", m.get("tag") and m.get("name") == unit["name"], m)
    t.check("spawn: model script without comments", m.get("kb", 99) < 30 and not m.get("comments"), m)
    t.check("spawn: model faction set", m.get("f") == UNIT[0], m)

    # --- reload keeps the unit; clicking again removes it -----------------------------------
    t.lua(f"getObjectFromGUID('{hub}').reload() return 0")
    time.sleep(1)
    wait_for(lambda: "loaded" in status(), timeout=30)
    red = t.lua(f"""local x = getObjectFromGUID('{hub}').UI.getXml()
local i = string.find(x, 'unit:{key}', 1, true)
return i ~= nil and string.find(string.sub(x, i, i + 120), '7F2119', 1, true) ~= nil""")
    t.check("reload: the unit still counts as spawned", red)
    t.lua(f"ui_click(nil, nil, 'unit:{key}') return 0", guid=hub)
    gone = wait_for(lambda: count("|" + key, model_only=False) == 0, timeout=20)
    t.check("remove: clicking the unit again removes everything of it", gone)

    # --- All models: one heading per theme ---------------------------------------------------
    gf, gu = GROUPED
    gunit = next(u for f in index["factions"] if f["id"] == gf for u in f["units"] if u["id"] == gu)
    themes = (1 if gunit.get("any") else 0) + len(gunit.get("subs") or {})
    gkey = f"{gf}/{gu}"
    t.lua(f"ui_click(nil, nil, 'faction:{gf}') ui_click(nil, nil, 'unit:{gkey}') return 0", guid=hub)
    wait_for(lambda: count("|" + gkey) >= gunit["count"], timeout=60)
    time.sleep(1)
    texts = t.lua(f"""local r = {{}}
for _, o in ipairs(getAllObjects()) do
    if o.name == '3DText' and string.find(o.memo or '', '|{gkey}', 1, true) then r[#r + 1] = o.TextTool.getValue() end
end return r""")
    t.check(f"groups: {gunit['name']} has a heading per theme ({themes}) plus its label",
            len(texts or []) == themes + 1 and any("Vanilla (" in x for x in texts), texts)
    t.lua(f"ui_click(nil, nil, 'unit:{gkey}') return 0", guid=hub)
    wait_for(lambda: count("|" + gkey, model_only=False) == 0, timeout=20)

    # --- warband import --------------------------------------------------------------------
    code, members = warband_code()
    t0 = time.time()
    t.lua(f"ui_click(nil, nil, 'import') ui_importText(nil, {t.long_string(code)}) ui_importGo() return 0", guid=hub)
    n = wait_for(lambda: count("|warband/") >= members and count("|warband/"), timeout=90)
    t.check(f"import: {members} warband members", n == members, n)
    print(f"     (import took {time.time() - t0:.1f} s)")
    mem = t.lua("""for _, o in ipairs(getAllObjects()) do
    if o.hasTag('TCM_Model') and string.find(o.memo or '', '|warband/', 1, true) then
        local st = o.getTable('state')
        return {member = st.member, name = o.getName(), desc = o.getDescription()}
    end
end""")
    t.check("import: members dressed (name, description, member)",
            mem["member"] and mem["name"].startswith("[b]") and len(mem["desc"]) > 10, mem)

    # --- Extend UI area ---------------------------------------------------------------------------
    copy = t.lua(f"""local src
for _, o in ipairs(getAllObjects()) do
    if o.hasTag('TCM_Model') and string.find(o.memo or '', '|warband/', 1, true) then src = o break end
end
local d = src.getData()
-- A stand-in for a source mod's model: its own script on the model and on an attached part.
d.LuaScript, d.LuaScriptState, d.XmlUI, d.Memo, d.Tags, d.Nickname = 'SOURCE_MARKER = 1', '', '', '', {{'TCM_Test'}}, 'Extend test'
if d.ChildObjects and d.ChildObjects[1] then d.ChildObjects[1].LuaScript = 'SOURCE_MARKER = 2' end
local hub = getObjectFromGUID('{hub}')
local s = hub.getScale()
local w = hub.positionToWorld(Vector(-12 / s.x, 0, -6 / s.z))
return spawnObjectData({{data = d, position = {{w.x, w.y + 1, w.z}}}}).getGUID()""")
    t.lua("ui_click(nil, nil, 'extend') ui_click(nil, nil, 'extendf:trench-pilgrims') return 0", guid=hub)
    time.sleep(2)

    def extend_state():
        return t.lua("""for _, o in ipairs(getAllObjects()) do
    if o.getName() == 'Extend test' then
        local d, st = o.getData(), o.getTable('state')
        local child = ''
        for _, c in ipairs(d.ChildObjects or {}) do child = child .. (c.LuaScript or '') end
        return {model = o.hasTag('TCM_Model'), f = st and st.f, source = string.find(d.LuaScript or '', 'SOURCE_MARKER', 1, true) ~= nil,
                child = child, script = #(d.LuaScript or '')}
    end
end return {}""") or {}

    t.lua(f"if onObjectDrop then onObjectDrop('White', getObjectFromGUID('{copy}')) end return 0", guid=hub)
    time.sleep(2)
    t.check("extend: dropping alone changes nothing", extend_state().get("source") is True, extend_state())
    t.lua("ui_click(nil, nil, 'extendapply') return 0", guid=hub)
    ext = wait_for(lambda: (lambda s: s if s.get("model") else None)(extend_state()), timeout=15) or extend_state()
    t.check("extend: Apply script replaces all scripts with the model script (picked faction)",
            ext.get("model") and ext.get("f") == "trench-pilgrims" and not ext.get("source") and ext.get("child") == "", ext)
    t.lua("ui_click(nil, nil, 'extendremove') return 0", guid=hub)
    time.sleep(3)
    ext = extend_state()
    t.check("extend: Remove all scripts leaves a plain model", ext.get("script") == 0 and not ext.get("model"), ext)
    t.lua("ui_click(nil, nil, 'extendapply') return 0", guid=hub)   # Clear all below checks it stays
    time.sleep(3)

    # --- Remove virus --------------------------------------------------------------------------
    # Stand-ins with a fake copy of the self-spreading "Spawning object" script (only its start
    # and end markers matter): a block whose own code must stay, and a bag holding an infected
    # object. Remove virus cleans every object in the game, so this also cleans a real infection.
    fake = ("string.rep(' ', 400) .. '--[[Object base' .. ' code]] FAKE_VIRUS = 1 --[[Spawning' .. ' object]]' "
            ".. string.char(10, 10)")
    bag_guid = t.lua(f"""local p = getObjectFromGUID('{hub}').getPosition()
spawnObjectData({{data = {{Name = 'BlockSquare', Nickname = 'Virus test block', Tags = {{'TCM_Test'}},
    Transform = {{posX = p.x - 4, posY = p.y + 1, posZ = p.z - 8, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1}},
    LuaScript = 'KEEP_ME = 1' .. {fake}}}}})
local bag = spawnObjectData({{data = {{Name = 'Bag', Nickname = 'Virus test bag', Tags = {{'TCM_Test'}},
    Transform = {{posX = p.x - 7, posY = p.y + 1, posZ = p.z - 8, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1}},
    ContainedObjects = {{{{Name = 'BlockSquare', Nickname = 'Virus test inside',
        Transform = {{posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1}},
        LuaScript = 'INSIDE = 1' .. {fake}}}}}}}}})
return bag.getGUID()""")
    time.sleep(2)
    # Wait.frames: the cleanup takes seconds on a big table, longer than the bridge waits for a reply.
    t.lua("ui_click(nil, nil, 'settings') Wait.frames(function() ui_click(nil, nil, 'virus') end, 1) return 0", guid=hub)
    wait_for(lambda: "Removed the virus" in status() or "No virus" in status(), timeout=60)
    time.sleep(1)
    v = t.lua("""local r = {}
for _, o in ipairs(getAllObjects()) do
    if o.getName() == 'Virus test block' then r.block = o.getLuaScript() end
    if o.getName() == 'Virus test bag' then
        local d = o.getData()
        r.inside = d.ContainedObjects and d.ContainedObjects[1] and d.ContainedObjects[1].LuaScript
        r.bagGuid = o.getGUID()
    end
end
local n = 0
for _, o in ipairs(getAllObjects()) do
    if string.find(o.getLuaScript() or '', '--[[Object base' .. ' code]]', 1, true) then n = n + 1 end
end
r.left = n
return r""")
    t.check("virus: removed, the object's own code kept", v.get("block") == "KEEP_ME = 1", v.get("block"))
    t.check("virus: removed from an object inside a bag", v.get("inside") == "INSIDE = 1", v.get("inside"))
    t.check("virus: the rebuilt bag keeps its GUID", v.get("bagGuid") == bag_guid, (bag_guid, v.get("bagGuid")))
    t.check("virus: no copy left on the table", v.get("left") == 0, v.get("left"))
    print("     (" + status()[:160].replace("\n", " ") + ")")
    t.lua("ui_click(nil, nil, 'settings') return 0", guid=hub)

    # --- Clear all ----------------------------------------------------------------------------
    if may_clear:
        t.lua("ui_click(nil, nil, 'clear') return 0", guid=hub)
        cleared = wait_for(lambda: t.lua(
            "local n = 0 for _, o in ipairs(getAllObjects()) do if o.hasTag('TCM_Spawned') then n = n + 1 end end return n") == 0,
            timeout=20)
        t.check("clear all: nothing spawned left", cleared)
        kept = t.lua("for _, o in ipairs(getAllObjects()) do if o.getName() == 'Extend test' then return true end end return false")
        t.check("clear all: the Extend model (not spawned) stays", kept)
    else:
        print("SKIP clear all: other spawned objects are on the table")
    return hub


if __name__ == "__main__":
    main()
