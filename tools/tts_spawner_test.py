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
d.LuaScript, d.LuaScriptState, d.XmlUI, d.Memo, d.Tags, d.Nickname = '', '', '', '', {{'TCM_Test'}}, 'Extend test'
local hub = getObjectFromGUID('{hub}')
local s = hub.getScale()
local w = hub.positionToWorld(Vector(-12 / s.x, 0, -6 / s.z))
return spawnObjectData({{data = d, position = {{w.x, w.y + 1, w.z}}}}).getGUID()""")
    t.lua("ui_click(nil, nil, 'extend') ui_click(nil, nil, 'extendf:trench-pilgrims') return 0", guid=hub)
    time.sleep(2)
    t.lua(f"onObjectDrop('White', getObjectFromGUID('{copy}')) return 0", guid=hub)
    time.sleep(3)
    ext = t.lua("""for _, o in ipairs(getAllObjects()) do
    if o.getName() == 'Extend test' then local st = o.getTable('state') return {model = o.hasTag('TCM_Model'), f = st and st.f} end
end return {}""")
    t.check("extend: dropped model gets the script with the picked faction",
            ext.get("model") and ext.get("f") == "trench-pilgrims", ext)

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
