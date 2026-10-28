"""Export tagged models from a TTS save into catalog/.

Usage:
    python tools/export.py "<path to TS_Save_N.json>" [--dry-run]

Reads every object whose GM Notes hold a {"tc":1,...} tag (written by tts/intake.lua),
including models inside bags, validates the tags against config/units.json, merges copies
of the same model within a unit, cleans the TTS object data and writes:

    catalog/units/<faction>/<unit>.json   one file per unit, one model per line
    catalog/index.json                    small menu index for the spawner
    catalog/version.json                  "catalog" is bumped only if the output changed
"""

import argparse
import json
import math
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONFIG = REPO / "config" / "units.json"
CATALOG = REPO / "catalog"

# Keys stripped from the model and from everything attached to it. Source mods often ship
# heavy per-model scripts and UI; GUIDs are reassigned by TTS anyway.
STRIP_KEYS = ("LuaScript", "LuaScriptState", "XmlUI", "GUID", "ContainedObjects", "GMNotes")


# ---------------------------------------------------------------- reading

def iter_objects(objects):
    """Yield every object, descending into bags (ContainedObjects). Attached objects
    (ChildObjects, e.g. bases) are part of their parent model and are not yielded."""
    for obj in objects:
        yield obj
        yield from iter_objects(obj.get("ContainedObjects") or [])


def parse_tag(notes):
    if not notes or '"tc"' not in notes:
        return None
    try:
        tag = json.loads(notes)
    except ValueError:
        return None
    return tag if isinstance(tag, dict) and tag.get("tc") == 1 else None


MERC = "mercenaries"


def load_config():
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    lookup = {}
    all_subs = set()
    for faction in config["factions"]:
        subs = {s["id"] for s in faction.get("subfactions", [])}
        all_subs |= subs
        lookup[faction["id"]] = {
            "faction": faction,
            "units": {u["id"]: u for u in faction.get("units", [])},
            "subs": subs,
        }
    # A mercenary can be made for, or picked by, any faction's subfaction (a Goetic Warlock
    # for Knights of Avarice); its vanilla import picks per faction use the faction id.
    lookup[MERC]["subs"] = all_subs
    lookup[MERC]["imports"] = all_subs | set(lookup) - {MERC}
    return config, lookup


def as_list(value):
    if isinstance(value, dict):  # TTS's JSON.encode can write an empty table as {}
        return list(value.values())
    return list(value or [])


def validate(tag, lookup):
    """Return (faction_id, unit_id, subs, imp, is_import_copy, w, d) or raise ValueError.
    subs = theme (subfactions the model was made for, empty = vanilla); imp = import
    contexts that prefer it ("_" = vanilla, subfaction ids, and for mercenaries faction ids);
    is_import_copy = written by an Import row of the sorting board (k = "i"): s means nothing."""
    f, u = tag.get("f"), tag.get("u")
    entry = lookup.get(f)
    if not entry:
        raise ValueError(f"unknown faction '{f}'")
    if u not in entry["units"]:
        raise ValueError(f"unknown unit '{u}' in faction '{f}'")
    subs = as_list(tag.get("s"))
    unknown = [s for s in subs if s not in entry["subs"]]
    if unknown:
        raise ValueError(f"unknown subfaction(s) {unknown} for faction '{f}'")
    imp = as_list(tag.get("i"))
    allowed = entry.get("imports", entry["subs"])
    bad_imp = [i for i in imp if i != "_" and i not in allowed]
    if bad_imp:
        raise ValueError(f"unknown import context(s) {bad_imp} for faction '{f}'")
    k = tag.get("k")
    if k not in (None, "i"):
        raise ValueError(f"unknown copy kind k='{k}'")
    if k == "i" and not imp:
        raise ValueError("import copy without an import context")
    w, d = tag.get("w"), tag.get("d")
    if not all(isinstance(v, (int, float)) and v > 0 for v in (w, d)):
        raise ValueError("missing or invalid footprint w/d (re-tag it in the intake)")
    return f, u, sorted(set(subs)), sorted(set(imp)), k == "i", float(w), float(d)


def merge_copies(copies, lookup):
    """Theme (s) and import contexts (i) of one model from all its copies in one unit.
    copies = [(subs, imp, is_import_copy)]. The sorting board writes one cell per object, so
    a model in several cells arrives as several copies:
      - s = union of the General copies' themes; a vanilla General copy adds "_" when themed
        copies exist too (empty s alone = vanilla);
      - i = union of all copies' import contexts;
      - a model with no General copy (only in Import rows) counts as General for each of its
        import contexts: moving a model into an Import row is the natural workflow.
        "_" and faction ids (a mercenary's per-faction vanilla pick) mean vanilla."""
    themes, vanilla, imports = set(), False, set()
    general = [c for c in copies if not c[2]]
    for subs, imp, _ in general:
        themes |= set(subs)
        vanilla |= not subs
        imports |= set(imp)
    for subs, imp, _ in copies:
        imports |= set(imp)
    if not general:
        for ctx in imports:
            if ctx == "_" or ctx in lookup:
                vanilla = True
            else:
                themes.add(ctx)
    s = sorted(themes)
    if vanilla and themes:
        s.append("_")
    return s, sorted(imports)


# ---------------------------------------------------------------- cleaning

def part_key(data):
    """Mesh + texture + scale of a single object, or None if it has no custom asset."""
    t = data.get("Transform", {})
    scale = tuple(round(t.get(k, 1.0), 3) for k in ("scaleX", "scaleY", "scaleZ"))
    if "CustomMesh" in data:
        m = data["CustomMesh"]
        return ("mesh", m.get("MeshURL", ""), m.get("DiffuseURL", ""), scale)
    if "CustomAssetbundle" in data:
        a = data["CustomAssetbundle"]
        return ("bundle", a.get("AssetbundleURL", ""), a.get("AssetbundleSecondaryURL", ""), scale)
    if "CustomImage" in data:
        return ("image", data["CustomImage"].get("ImageURL", ""), "", scale)
    return None


def dedupe_key(data):
    """Identity of a whole model for duplicate detection. The tagged object is often just
    the base, with the sculpt attached as a ChildObject, so every attached part counts."""
    own = part_key(data)
    children = tuple(sorted(
        (dedupe_key(c) for c in data.get("ChildObjects") or []),
        key=lambda k: json.dumps(k),
    ))
    if own is None and not any(children):
        return None
    return (own, children)


def short_key(key):
    """Readable tail of the first asset URL in a key, for warnings."""
    own, children = key
    for part in (own, *(c[0] for c in children if c)):
        if part and part[1]:
            return part[1].rstrip("/")[-40:]
    return "?"


def strip(data):
    """Remove scripts/UI/GUIDs from an object, its attachments and its alternative states."""
    for key in STRIP_KEYS:
        data.pop(key, None)
    for child in data.get("ChildObjects") or []:
        strip(child)
    for state in (data.get("States") or {}).values():
        strip(state)


def round_transform(t):
    for key, value in t.items():
        if isinstance(value, float):
            t[key] = round(value, 4) + 0.0  # + 0.0 turns -0.0 into 0.0


def clean(data, unit_name, w, d):
    """Return (cleaned data, w, d). The input is modified in place."""
    strip(data)
    data["Nickname"] = unit_name  # source nicknames are often another player's stat block
    data["Locked"] = False
    # Spawned models are Figurines (TypeIndex 1): other table scripts look for that type.
    for asset in ("CustomMesh", "CustomAssetbundle"):
        if asset in data:
            data[asset]["TypeIndex"] = 1

    t = data.setdefault("Transform", {})
    t["posX"] = t["posY"] = t["posZ"] = 0.0
    # Models face whatever way they were dropped at intake. Reset the yaw so every model
    # faces its mesh's own forward; the spawner adds its own rotation. The footprint was
    # measured at the old yaw, so swap it when the model was turned sideways.
    yaw = math.radians(t.get("rotY", 0.0))
    if abs(math.sin(yaw)) > math.sqrt(0.5):
        w, d = d, w
    t["rotY"] = 0.0
    for child in data.get("ChildObjects") or []:
        round_transform(child.get("Transform", {}))
    round_transform(t)
    return data, w, d


# ---------------------------------------------------------------- writing

def dump_unit(entries):
    """One entry per line so git diffs show added/removed models clearly."""
    lines = [json.dumps(e, sort_keys=True, ensure_ascii=False, separators=(",", ":")) for e in entries]
    return "[\n" + ",\n".join(lines) + "\n]\n"


def dump_json(obj):
    return json.dumps(obj, ensure_ascii=False, indent=1) + "\n"


def read_text(path):
    return path.read_text(encoding="utf-8") if path.exists() else None


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # Windows console + unit names with accents

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("save", type=Path, help="TTS save file (Saves/TS_Save_N.json)")
    parser.add_argument("--dry-run", action="store_true", help="report only, write nothing")
    args = parser.parse_args()

    config, lookup = load_config()
    save = json.loads(args.save.read_text(encoding="utf-8"))

    warnings = []
    units = {}  # (f, u) -> {dedupe key or index: entry}
    copies = {}  # (f, u, key) -> [(subs, imp, is_import_copy)], merged after reading
    tagged = merged = 0
    for obj in iter_objects(save.get("ObjectStates", [])):
        tag = parse_tag(obj.get("GMNotes"))
        if not tag:
            continue
        tagged += 1
        name = (obj.get("Nickname") or obj.get("Name") or "").splitlines()[0] if (obj.get("Nickname") or obj.get("Name")) else "?"
        label = f"'{name}' ({obj.get('GUID', '?')})"
        try:
            f, u, subs, imp, is_import, w, d = validate(tag, lookup)
        except ValueError as err:
            warnings.append(f"SKIPPED {label}: {err}")
            continue

        key = dedupe_key(obj)
        bucket = units.setdefault((f, u), {})
        if key is None:
            warnings.append(f"no mesh/asset URL on {label}; kept without duplicate check")
            key = ("nokey", len(bucket))
        if key in bucket:
            # Another copy of a model already in this unit. Copies in different board cells
            # are intended and merged; the same cell twice is a real duplicate.
            group = copies[(f, u, key)]
            if (subs, imp, is_import) in group:
                warnings.append(f"duplicate in {f}/{u}: {label} (asset {short_key(key)})")
            else:
                merged += 1
            group.append((subs, imp, is_import))
            continue
        data, w, d = clean(json.loads(json.dumps(obj)), lookup[f]["units"][u]["name"], w, d)
        bucket[key] = {"w": round(w, 2), "d": round(d, 2), "data": data}
        copies[(f, u, key)] = [(subs, imp, is_import)]

    for (f, u, key), group in copies.items():
        entry = units[(f, u)][key]
        entry["s"], imp = merge_copies(group, lookup)
        if imp:
            entry["i"] = imp

    # Same model under several units is intended: one model can fit several units (e.g. a
    # Takwin Homunculus that is also a Golem). The maintainer copies it in TTS and tags the
    # copy for the other unit. Listed as info so accidental double tags can still be spotted.
    shared = []
    seen = {}
    for (f, u), bucket in units.items():
        for key in bucket:
            if not (isinstance(key, tuple) and key[0] == "nokey"):
                seen.setdefault(key, []).append(f"{f}/{u}")
    for key, where in seen.items():
        if len(where) > 1:
            shared.append(f"{', '.join(where)} (asset {short_key(key)})")

    # ---- build output in config order, entries sorted by their identity
    files = {}  # path relative to catalog/ -> text
    index_factions = []
    summary = []
    for faction in config["factions"]:
        f = faction["id"]
        index_units = []
        for unit in faction.get("units", []):
            bucket = units.get((f, unit["id"]))
            if not bucket:
                continue
            entries = [bucket[k] for k in sorted(bucket, key=lambda k: json.dumps(k))]
            rel = f"units/{f}/{unit['id']}.json"
            files[rel] = dump_unit(entries)
            # Spawner filters: Vanilla shows `any`, a subfaction C shows subs[C] (or `any`
            # when that is 0), All shows `count`.
            subs = {}
            for e in entries:
                for s in e["s"]:
                    if s != "_":
                        subs[s] = subs.get(s, 0) + 1
            entry = {
                "id": unit["id"], "name": unit["name"], "count": len(entries),
                "any": sum(1 for e in entries if not e["s"] or "_" in e["s"]),  # vanilla models
                "subs": dict(sorted(subs.items())),            # subfaction id -> models made for it
                "file": rel,
            }
            # Trench Companion model ids that don't match the unit name (warband import).
            if unit.get("companion"):
                entry["companion"] = unit["companion"]
            if unit.get("everyone"):
                entry["everyone"] = True   # every warband can get it (Golem)
            index_units.append(entry)
            summary.append(f"  {faction['name']} / {unit['name']}: {len(entries)}")
        if index_units:
            # Subfactions are copied whole: they may carry their own `mercenaries` list.
            index_faction = {
                "id": f, "name": faction["name"],
                "subfactions": faction.get("subfactions", []),
            }
            if "mercenaries" in faction:
                index_faction["mercenaries"] = faction["mercenaries"]   # units it can hire
            index_faction["units"] = index_units
            index_factions.append(index_faction)

    # ---- decide whether anything changed (index compared without its version number)
    version_path = CATALOG / "version.json"
    version = json.loads(read_text(version_path) or '{"catalog": 0, "spawner": 1, "spawnerUrl": "tts/spawner.lua"}')
    old_index = json.loads(read_text(CATALOG / "index.json") or "{}")
    old_index.pop("version", None)
    changed = old_index != {"factions": index_factions}
    for rel, text in files.items():
        changed |= read_text(CATALOG / rel) != text
    stale = [p for p in (CATALOG / "units").rglob("*.json")
             if p.relative_to(CATALOG).as_posix() not in files] if (CATALOG / "units").exists() else []
    changed |= bool(stale)

    if changed:
        version["catalog"] = version.get("catalog", 0) + 1
    files["index.json"] = dump_json({"version": version["catalog"], "factions": index_factions})
    files["version.json"] = dump_json(version)

    # ---- report
    total = sum(len(b) for b in units.values())
    print(f"Tagged objects found: {tagged}, exported models: {total}, copies merged: {merged}")
    print("\n".join(summary) or "  (nothing to export)")
    if shared:
        print(f"\nModels used by several units ({len(shared)}):")
        for line in shared:
            print("  " + line)
    if warnings:
        print(f"\nWarnings ({len(warnings)}):")
        for w in warnings:
            print("  " + w)
    for p in stale:
        print(f"Removing stale file: {p.relative_to(CATALOG).as_posix()}")
    print(f"\nCatalog version: {version['catalog']} ({'changed' if changed else 'unchanged'})")

    if args.dry_run:
        print("Dry run: nothing written.")
        return
    if not changed:
        return
    for p in stale:
        p.unlink()
    for rel, text in files.items():
        path = CATALOG / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
    print(f"Wrote {len(files)} file(s) to {CATALOG}")


if __name__ == "__main__":
    main()
