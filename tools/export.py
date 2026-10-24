"""Export tagged models from a TTS save into catalog/.

Usage:
    python tools/export.py "<path to TS_Save_N.json>" [--dry-run]

Reads every object whose GM Notes hold a {"tc":1,...} tag (written by tts/intake.lua),
including models inside bags, validates the tags against config/units.json, removes
duplicates, cleans the TTS object data and writes:

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


def load_config():
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    lookup = {}
    for faction in config["factions"]:
        lookup[faction["id"]] = {
            "faction": faction,
            "units": {u["id"]: u for u in faction.get("units", [])},
            "subs": {s["id"] for s in faction.get("subfactions", [])},
        }
    return config, lookup


def validate(tag, lookup):
    """Return (faction_id, unit_id, subs, imp, w, d) or raise ValueError with the reason.
    imp = import sets the model belongs to: "_" (vanilla) and/or subfaction ids."""
    f, u = tag.get("f"), tag.get("u")
    entry = lookup.get(f)
    if not entry:
        raise ValueError(f"unknown faction '{f}'")
    if u not in entry["units"]:
        raise ValueError(f"unknown unit '{u}' in faction '{f}'")
    subs = tag.get("s") or []
    if isinstance(subs, dict):  # TTS's JSON.encode can write an empty table as {}
        subs = list(subs.values())
    unknown = [s for s in subs if s not in entry["subs"]]
    if unknown:
        raise ValueError(f"unknown subfaction(s) {unknown} in faction '{f}'")
    imp = tag.get("i") or []
    bad_imp = [i for i in imp if i != "_" and i not in entry["subs"]]
    if bad_imp:
        raise ValueError(f"unknown import set(s) {bad_imp} in faction '{f}'")
    w, d = tag.get("w"), tag.get("d")
    if not all(isinstance(v, (int, float)) and v > 0 for v in (w, d)):
        raise ValueError("missing or invalid footprint w/d (re-tag it in the intake)")
    return f, u, sorted(set(subs)), sorted(set(imp)), float(w), float(d)


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
    tagged = 0
    for obj in iter_objects(save.get("ObjectStates", [])):
        tag = parse_tag(obj.get("GMNotes"))
        if not tag:
            continue
        tagged += 1
        name = (obj.get("Nickname") or obj.get("Name") or "").splitlines()[0] if (obj.get("Nickname") or obj.get("Name")) else "?"
        label = f"'{name}' ({obj.get('GUID', '?')})"
        try:
            f, u, subs, imp, w, d = validate(tag, lookup)
        except ValueError as err:
            warnings.append(f"SKIPPED {label}: {err}")
            continue

        key = dedupe_key(obj)
        data, w, d = clean(json.loads(json.dumps(obj)), lookup[f]["units"][u]["name"], w, d)
        entry = {"s": subs, "w": round(w, 2), "d": round(d, 2), "data": data}
        if imp:
            entry["i"] = imp   # import sets (see validate)
        bucket = units.setdefault((f, u), {})
        if key is None:
            warnings.append(f"no mesh/asset URL on {label}; kept without duplicate check")
            bucket[("nokey", len(bucket))] = entry
        elif key in bucket:
            # Same model tagged twice for this unit: keep one, widen its subfactions.
            kept = bucket[key]
            kept["s"] = [] if not kept["s"] or not subs else sorted(set(kept["s"]) | set(subs))
            if imp:
                kept["i"] = sorted(set(kept.get("i", [])) | set(imp))
            warnings.append(f"duplicate in {f}/{u}: {label} (asset {short_key(key)})")
        else:
            bucket[key] = entry

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
            # The spawner's subfaction filter shows any + subs[filter] models for a unit.
            subs = {}
            for e in entries:
                for s in e["s"]:
                    subs[s] = subs.get(s, 0) + 1
            entry = {
                "id": unit["id"], "name": unit["name"], "count": len(entries),
                "any": sum(1 for e in entries if not e["s"]),  # usable by every subfaction
                "subs": dict(sorted(subs.items())),            # subfaction id -> model count
                "file": rel,
            }
            # Trench Companion model ids that don't match the unit name (warband import).
            if unit.get("companion"):
                entry["companion"] = unit["companion"]
            index_units.append(entry)
            summary.append(f"  {faction['name']} / {unit['name']}: {len(entries)}")
        if index_units:
            index_factions.append({
                "id": f, "name": faction["name"],
                "subfactions": faction.get("subfactions", []),
                "units": index_units,
            })

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
    print(f"Tagged objects found: {tagged}, exported models: {total}")
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
