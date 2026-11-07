"""Regression test for tts/intake.lua in a running Tabletop Simulator (through the bridge).

    python tools/tts_bridge.py listen        (in the background: serves the repo, handles Publish)
    python tools/tts_intake_test.py [--keep]

Spawns its own intake station running the local script (any game; the dev save isn't needed),
opens the Mercenaries board from the local catalog and checks: every cell's model is there,
publishing the unchanged board leaves catalog/ unchanged, a copied model is marked as a
change, Close warns first and discards on a second press. The catalog is backed up first and
restored if anything changed it. Removes everything it made unless --keep is given.
"""

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import export          # noqa: E402
import test_publish    # noqa: E402  (board_models: what a board shows)
import tts_test as t   # noqa: E402  lua(), check(), long_string(), results

ROOT = Path(__file__).resolve().parent.parent
FACTION = ("mercenaries", "Mercenaries")
made = []   # set once the test spawned anything (cleanup needed)


def catalog_hash():
    h = hashlib.sha256()
    for p in sorted((ROOT / "catalog").rglob("*")):
        if p.is_file():
            h.update(p.relative_to(ROOT).as_posix().encode())
            h.update(p.read_bytes())
    return h.hexdigest()


def wait_for(fn, timeout=60, step=0.5):
    end = time.time() + timeout
    value = fn()
    while not value and time.time() < end:
        time.sleep(step)
        value = fn()
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="don't remove the test objects")
    args = parser.parse_args()
    backup = Path(tempfile.mkdtemp(prefix="tcm_catalog_"))
    shutil.copytree(ROOT / "catalog", backup / "catalog")
    before = catalog_hash()
    try:
        run()
    finally:
        if catalog_hash() != before:
            changed = Path(tempfile.gettempdir()) / "tcm_catalog_changed"
            shutil.rmtree(changed, ignore_errors=True)
            shutil.copytree(ROOT / "catalog", changed)
            print(f"     (the changed catalog is kept in {changed} for comparing)")
            shutil.rmtree(ROOT / "catalog")
            shutil.copytree(backup / "catalog", ROOT / "catalog")
            print("     (catalog restored from the backup)")
        shutil.rmtree(backup, ignore_errors=True)
        if made and not args.keep:
            t.lua(f"""for _, o in ipairs(getAllObjects()) do
    if o.hasTag('TCM_Board') or o.hasTag('TCM_Test') then o.destruct() end
end return 0""")
            time.sleep(1)
            # Models of the board: any figure lying right of where the station stood.
            t.lua("""for _, o in ipairs(getAllObjects()) do
    if (o.name == 'Custom_Model' or o.name == 'Custom_Assetbundle') and o.getPosition().x > -26 and o.memo == 'TCM intake test' then o.destruct() end
end return 0""")
    failed = t.results.count(False)
    print(f"\n{len(t.results) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def run():
    others = t.lua("""local n = 0 for _, o in ipairs(getAllObjects()) do
    if o.name == 'Custom_Model' or o.name == 'Custom_Assetbundle' or o.hasTag('TCM_Board') then n = n + 1 end
end return n""")
    if others:
        print(f"SKIP: {others} model(s) or board pieces are already on the table; run this in an empty game.")
        return None
    made.append(True)
    script = (ROOT / "tts" / "intake.lua").read_text(encoding="utf-8")
    station = t.lua(f"""local o = spawnObjectData({{data = {{
    Name = 'BlockSquare', Nickname = 'TC intake test', Tags = {{'TCM_Test'}},
    Transform = {{posX = -24, posY = 2, posZ = 10, rotX = 0, rotY = 180, rotZ = 0, scaleX = 2, scaleY = 0.4, scaleZ = 2}},
    LuaScript = {t.long_string(script)}}}}})
return o.getGUID()""")

    def status():
        return t.lua(f"""local x = getObjectFromGUID('{station}').UI.getXml()
local i = string.find(x, 'preferredHeight="180"', 1, true)
return i and string.sub(x, i + 50, i + 700) or ''""") or ""

    ok = wait_for(lambda: "Config loaded" in status(), timeout=20)
    t.check("config: loaded from the listener", ok, status())
    if not ok:
        return station

    config, lookup = export.load_config()
    cells = len(test_publish.board_models(FACTION[0], config, lookup))
    t.lua(f"ui_faction(nil, '{FACTION[1]}') ui_open() return 0", guid=station)
    ok = wait_for(lambda: "Board open:" in status(), timeout=120)
    t.check("open: board built", ok, status())
    if not ok:
        return station
    time.sleep(3)
    # Mark the board's models so cleanup finds them (they have no tag of their own).
    n = t.lua("""local n = 0 for _, o in ipairs(getAllObjects()) do
    if (o.name == 'Custom_Model' or o.name == 'Custom_Assetbundle') and not o.hasTag('TCM_Board') then o.memo = 'TCM intake test' n = n + 1 end
end return n""")
    t.check(f"open: one model per cell membership ({cells})", n == cells, n)

    # --- unchanged publish ----------------------------------------------------------------------
    before = catalog_hash()
    t.lua("Wait.frames(ui_publish, 1) return 0", guid=station)   # it takes seconds: no reply would come
    ok = wait_for(lambda: "Catalog version" in status(), timeout=90)
    t.check("publish: report came back", ok, status())
    t.check("publish: unchanged board leaves the catalog unchanged",
            "(unchanged)" in status() and catalog_hash() == before, status())

    # --- a real change: move one Observer into the Witchburner column, Vanilla General ----------
    def counts():
        idx = json.loads((ROOT / "catalog" / "index.json").read_text(encoding="utf-8"))
        return {u["id"]: u["count"] for f in idx["factions"] if f["id"] == FACTION[0] for u in f["units"]}
    old = counts()
    moved = t.lua(f"""local b = JSON.decode(getObjectFromGUID('{station}').script_state).board
local a = math.rad(b.frame.yaw)
local c, s = math.cos(a), math.sin(a)
local function toWorld(x, z, y)   -- frameToWorld in intake.lua
    local lx, lz = -x, -z
    return Vector(b.frame.x + lx * c + lz * s, y, b.frame.z - lx * s + lz * c)
end
local function toFrame(p)
    local dx, dz = p.x - b.frame.x, p.z - b.frame.z
    return -(dx * c - dz * s), -(dx * s + dz * c)
end
local from, to, row
for i, col in ipairs(b.cols) do
    if col.u == 'observer' then from = col end
    if col.u == 'witchburner' then to = col end
end
for _, r in ipairs(b.rows) do if r.kind == 'g' and r.ctx == '_' then row = r end end
for _, o in ipairs(getAllObjects()) do
    if o.memo == 'TCM intake test' then
        local x, z = toFrame(o.getPosition())
        if x >= from.x0 and x <= from.x1 and z >= row.z0 and z <= row.z1 then
            o.setPosition(toWorld(to.x1 - 1, row.z1 - 1, b.frame.y + 1))
            return o.getName()
        end
    end
end""")
    time.sleep(3)
    t.lua("Wait.frames(ui_publish, 1) return 0", guid=station)
    ok = wait_for(lambda: "Catalog version" in status() and "(changed)" in status(), timeout=90)
    new = counts()
    t.check("publish: a moved model changes its unit (Observer -1, Witchburner +1)",
            ok and moved == "Observer" and new.get("observer") == old.get("observer") - 1
            and new.get("witchburner") == old.get("witchburner") + 1,
            (moved, old.get("observer"), new.get("observer"), old.get("witchburner"), new.get("witchburner")))
    t.check("publish: the report lists the change first (counted where it went)",
            status().startswith('erLeft">Witchburner (merc): 1 moved') or 'Witchburner: 1 moved' in status(), status())
    before = catalog_hash()

    # --- a change, then Close: warns once, discards on the second press ---------------------------
    t.lua("""for _, o in ipairs(getAllObjects()) do
    if o.memo == 'TCM intake test' then
        local p = o.getPosition()
        o.clone({position = {p.x, p.y + 2, p.z}}).memo = 'TCM intake test'
        return 1
    end
end return 0""")
    time.sleep(3)
    t.lua("Wait.frames(ui_close, 1) return 0", guid=station)
    time.sleep(1)
    t.check("close: first press lists the unpublished change", "Unpublished changes" in status() and "+1 new" in status(), status())
    t.lua("Wait.frames(ui_close, 1) return 0", guid=station)
    ok = wait_for(lambda: "Board closed" in status(), timeout=60)
    t.check("close: second press discards and removes the board", ok, status())
    left = t.lua("""local n = 0 for _, o in ipairs(getAllObjects()) do
    if o.hasTag('TCM_Board') or o.memo == 'TCM intake test' then n = n + 1 end
end return n""")
    t.check("close: no board pieces or models left", left == 0, left)
    t.check("close: catalog unchanged", catalog_hash() == before)
    return station


if __name__ == "__main__":
    main()
