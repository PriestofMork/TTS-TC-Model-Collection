"""Regression test for tts/model.lua in a running Tabletop Simulator (through the bridge).

    python tools/tts_bridge.py listen        (in the background, as for debugging)
    python tools/tts_test.py [--keep]

Builds its own test objects near the table's centre (plain blocks as stand-in models running
the local tts/model.lua, a fake spawn platform, real dice), runs the scenarios below, prints
PASS / FAIL per check and removes everything it made (tag TCM_Test) unless --keep is given.
Run it after every change to the model script; it needs a loaded game (any table) and
nothing else.

Scenarios: load (id, tags, base guess), activation icon per faction (shared asset names),
token height stable while lifted / tilted / redrawn, Set base size, dice link / 1-6 / 0,
Ready all through the TCUIOperative interface, copies get a new id, swap on the platform
and not off it.
"""

import argparse
import json
import socket
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG = ROOT / "tts.log"
# As the spawner puts it into models: whole comment lines and blank lines removed (stripComments).
MODEL_SCRIPT = "\n".join(
    line for line in (ROOT / "tts" / "model.lua").read_text(encoding="utf-8").split("\n")
    if line.strip() and not line.strip().startswith("--")) + "\n"
TTS_PORT = 39999
PREFIX = "TESTRESULT: "

results = []


def lua(code, guid="-1", wait=6):
    """Runs Lua in the game and returns the decoded result (JSON) of its `return`."""
    start = LOG.stat().st_size if LOG.exists() else 0
    wrapped = ("local __ok, __r = pcall(function()\n" + code + "\nend)\n"
               "if not __ok then print('" + PREFIX + "' .. JSON.encode({error = tostring(__r)}))\n"
               "else print('" + PREFIX + "' .. JSON.encode({value = __r})) end")
    with socket.create_connection(("127.0.0.1", TTS_PORT), timeout=5) as s:
        s.sendall(json.dumps({"messageID": 3, "guid": guid, "script": wrapped}).encode("utf-8"))
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(0.2)
        with open(LOG, encoding="utf-8") as f:
            f.seek(start)
            for line in f.read().splitlines():
                try:
                    msg = json.loads(line).get("message", "")
                except ValueError:
                    continue
                if msg.startswith(PREFIX):
                    data = json.loads(msg[len(PREFIX):])
                    if "error" in data:
                        raise RuntimeError(data["error"])
                    return data.get("value")
    raise TimeoutError("no answer from TTS (is the listener running and a game loaded?)")


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))


def long_string(text):
    level = 1
    while ("]" + "=" * level + "]") in text:
        level += 1
    return "[" + "=" * level + "[" + text + "]" + "=" * level + "]"


def spawn_model(x, z, state, width=1.26):
    """A stand-in model: a flat block the size of a base, running the local model script."""
    code = f"""
local w = {width}
local o = spawnObjectData({{data = {{
    Name = "BlockSquare", Nickname = "TC test model",
    Transform = {{posX = {x}, posY = 3, posZ = {z}, rotX = 0, rotY = 0, rotZ = 0, scaleX = w, scaleY = 0.15, scaleZ = w}},
    Tags = {{"TCM_Test"}},
    LuaScript = {long_string(MODEL_SCRIPT)},
    LuaScriptState = {long_string(json.dumps(state))},
}}}})
return o.getGUID()"""
    return lua(code)


def model_state(guid):
    return lua(f"return getObjectFromGUID('{guid}').getTable('state')")


def panel_height(guid):
    """Height of the marker panel above the model's pivot, inches (from its XML)."""
    return lua(f"""
local o = getObjectFromGUID('{guid}')
local z = tonumber(string.match(o.UI.getXml(), 'position="0 0 (%-?[%d%.]+)"'))
return z and -z * o.getScale().y / 100 or nil""")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="don't remove the test objects")
    args = parser.parse_args()

    lua("for _, o in ipairs(getAllObjects()) do if o.hasTag('TCM_Test') then o.destruct() end end return 0")
    try:
        run()
    finally:
        if not args.keep:
            lua("for _, o in ipairs(getAllObjects()) do if o.hasTag('TCM_Test') then o.destruct() end end return 0")
    failed = results.count(False)
    print(f"\n{len(results) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def run():
    # --- load -------------------------------------------------------------------------
    a = spawn_model(-6, -6, {"f": "new-antioch"})
    b = spawn_model(-3, -6, {"f": "trench-pilgrims"})
    time.sleep(3)
    sa = model_state(a)
    tags = lua(f"local o = getObjectFromGUID('{a}') return {{o.hasTag('TCM_Model'), o.hasTag('TCUIOperative')}}")
    check("load: model has an id", bool(sa.get("id")))
    check("load: tags TCM_Model and TCUIOperative", tags == [True, True], tags)
    check("load: state version 2", sa.get("v") == 2, sa.get("v"))
    check("load: geometry measured at rest", sa.get("geo") is not None)

    # --- activation icons: per-faction asset names ------------------------------------
    for g, f in ((a, "new-antioch"), (b, "trench-pilgrims")):
        lua(f"getObjectFromGUID('{g}').call('setFaction', {{f = '{f}'}}) return 0")
    time.sleep(1)
    icons = lua(f"""local r = {{}}
for _, g in ipairs({{'{a}', '{b}'}}) do r[#r + 1] = string.match(getObjectFromGUID(g).UI.getXml(), 'image="(act_[^"]+)"') end
return r""")
    check("activation: one icon name per faction", icons == ["act_new-antioch", "act_trench-pilgrims"], icons)

    # --- height: from the base size, stable ------------------------------------------
    h1 = panel_height(a)
    # 32 mm base guessed from 1.26": 1.75 + 1 headroom + 0.4 gap, measured from the base bottom.
    bottom = model_state(a)["geo"]["bottom"]
    check("height: 32 mm base, 1\" headroom", abs(h1 - (bottom + 1.75 + 1.0 + 0.4)) < 0.05, f"{h1:.2f}")
    lua(f"""local o = getObjectFromGUID('{a}') local p = o.getPosition()
o.setPositionSmooth({{p.x, p.y + 3, p.z}}) o.setRotation({{35, 0, 25}}) o.call('toggleState') return 0""")
    time.sleep(0.5)
    h2 = panel_height(a)
    check("height: unchanged while lifted and tilted", abs(h1 - h2) < 0.01, f"{h1:.2f} -> {h2:.2f}")
    lua(f"local o = getObjectFromGUID('{a}') o.setRotation({{0, 0, 0}}) o.call('toggleState') return 0")
    time.sleep(2)

    # --- Set base size ----------------------------------------------------------------
    lua("ui_pickBase(nil, nil, 'base:50') return 0", guid=a)
    time.sleep(0.5)
    sa = model_state(a)
    h3 = panel_height(a)
    check("base size: set to 50 mm", sa.get("base") == 50, sa.get("base"))
    check("base size: height follows (50 mm = 2.5\")", abs(h3 - (bottom + 2.5 + 1.0 + 0.4)) < 0.05, f"{h3:.2f}")

    # --- dice -------------------------------------------------------------------------
    die = lua(f"""local p = getObjectFromGUID('{a}').getPosition()
return spawnObject({{type = 'Die_6', position = {{p.x, p.y + 1, p.z}}}}).getGUID()""")
    time.sleep(1.5)
    lua(f"onObjectDrop('White', getObjectFromGUID('{die}')) return 0", guid=a)
    time.sleep(3)   # the die gets its script (reload) and is placed
    sa = model_state(a)
    d = lua(f"""local d = getObjectFromGUID('{die}')
return {{memo = d.memo, tag = d.hasTag('TCM_Die'), locked = d.getLock(),
        script = string.find(d.getLuaScript(), 'TC Miniatures die marker v2', 1, true) ~= nil}}""")
    check("dice: linked", die in sa.get("dice", []), sa.get("dice"))
    check("dice: memo is the model's id (not its GUID)", d["memo"] == sa["id"], d["memo"])
    check("dice: tagged, locked, script v2", d["tag"] and d["locked"] and d["script"], d)
    lua("onNumberTyped('White', 5) return 0", guid=die)
    time.sleep(1.5)
    check("dice: 5 turns it to 5", lua(f"return getObjectFromGUID('{die}').getValue()") == 5)
    lua("onNumberTyped('White', 0) return 0", guid=die)
    time.sleep(1.5)
    d = lua(f"local d = getObjectFromGUID('{die}') return {{memo = d.memo, locked = d.getLock()}}")
    check("dice: 0 releases it", d == {"memo": "", "locked": False} and die not in model_state(a).get("dice", []), d)
    lua(f"getObjectFromGUID('{die}').addTag('TCM_Test') return 0")

    # --- Ready all through the TCUIOperative interface (as a scoreboard does it) ------
    for g in (a, b):
        lua(f"local o = getObjectFromGUID('{g}') if not o.getTable('state').activated then o.call('toggleState') end return 0")
    time.sleep(0.5)
    lua("""for _, o in ipairs(getAllObjects()) do
if o.hasTag('TCUIOperative') then
    o.call('savePosition')
    local st = o.getTable('state')
    if type(st) == 'table' and st.activated then o.call('toggleState') end
end end return 0""")
    time.sleep(0.5)
    sa, sb = model_state(a), model_state(b)
    check("ready all: both ready", not sa["activated"] and not sb["activated"])
    check("ready all: positions saved", sa.get("savePos") is not None and sb.get("savePos") is not None)
    icons = lua(f"""local r = {{}}
for _, g in ipairs({{'{a}', '{b}'}}) do r[#r + 1] = string.match(getObjectFromGUID(g).UI.getXml(), 'image="(act_[^"]+)"') end
return r""")
    check("ready all: icons stay per faction", icons == ["act_new-antioch", "act_trench-pilgrims"], icons)

    # --- copies get their own id --------------------------------------------------------
    copy = lua(f"""local o = getObjectFromGUID('{a}') local p = o.getPosition()
return o.clone({{position = {{p.x, p.y + 2, p.z - 3}}}}).getGUID()""")
    time.sleep(3)
    ida, idc = model_state(a)["id"], model_state(copy)["id"]
    check("copy: new id, original keeps its id", ida == sa["id"] and idc != ida, f"{ida} / {idc}")

    # --- swap only on the import platform -------------------------------------------------
    lua("""spawnObjectData({data = {Name = 'BlockSquare', Nickname = 'TC spawn platform', Locked = true,
    Transform = {posX = 4, posY = 1.5, posZ = -6, rotX = 0, rotY = 0, rotZ = 0, scaleX = 6, scaleY = 0.2, scaleZ = 4},
    Tags = {'TCM_Test'}}}) return 0""")
    time.sleep(1)
    m = spawn_model(4, -6, {"f": "new-antioch", "u": "yeoman", "member": True})
    n = spawn_model(6, -4, {"f": "new-antioch", "u": "yeoman"})
    time.sleep(3)
    lua(f"""getObjectFromGUID('{m}').setName('Member name') local p = getObjectFromGUID('{m}').getPosition()
getObjectFromGUID('{n}').setPosition({{p.x, p.y + 1, p.z}}) return 0""")
    time.sleep(0.3)
    lua(f"onObjectDrop('White', getObjectFromGUID('{n}')) return 0", guid=m)
    time.sleep(1.5)
    gone = lua(f"return getObjectFromGUID('{m}') == nil")
    sn = model_state(n)
    check("swap: on the platform the member is replaced", gone and sn["member"] and sn["taken"] is False, sn)
    check("swap: name taken over", lua(f"return getObjectFromGUID('{n}').getName()") == "Member name")
    # Off the platform: a new member on the plain table must not swap.
    m2 = spawn_model(-6, -2, {"f": "new-antioch", "u": "yeoman", "member": True})
    n2 = spawn_model(-3, -2, {"f": "new-antioch", "u": "yeoman"})
    time.sleep(3)
    lua(f"""local p = getObjectFromGUID('{m2}').getPosition()
getObjectFromGUID('{n2}').setPosition({{p.x, p.y + 1, p.z}}) return 0""")
    time.sleep(0.3)
    lua(f"onObjectDrop('White', getObjectFromGUID('{n2}')) return 0", guid=m2)
    time.sleep(1.5)
    check("swap: off the platform nothing swaps", lua(f"return getObjectFromGUID('{m2}') ~= nil"))
    lua(f"for _, g in ipairs({{'{copy}', '{n}', '{m2}', '{n2}'}}) do local o = getObjectFromGUID(g) if o then o.addTag('TCM_Test') end end return 0")


if __name__ == "__main__":
    main()
