"""Publish one sorting board from the intake into catalog/ (called by tts_bridge.py listen).

The catalog is the storage: the intake's board opens straight from catalog/ (served by the
bridge listener) and Publish sends every model lying in a cell back here. This turns the
current catalog into tagged objects (one per board cell, as the board shows them), replaces
the cells the published board shows with the board's models, and runs export's build() and
write() over everything, so merging, cleaning, the index and the version bump follow the
same rules as an export from a save.

A board shows its faction's own units completely, but a Mercenaries unit only partly: on a
faction's board a hired mercenary (or Golem) shows the faction's subfaction rows and its
vanilla import pick (i = faction id); its untagged models and the vanilla import pick of the
Mercenaries board, and other factions' rows, live on other boards and are kept. Same rules as
rowFor / cellExists in tts/intake.lua.

    python tools/publish.py --check    the current catalog round-trips unchanged (no writes)
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import export   # noqa: E402

MERC = export.MERC


def memberships(info):
    """One (kind, ctx) per board cell an entry stands for, like membershipsOf in intake.lua:
    General per theme in s ("_" or empty s = vanilla), Import per context in i."""
    out = []
    s = info.get("s") or []
    if not s:
        out.append(("g", "_"))
    out += [("g", x) for x in s]
    out += [("i", x) for x in info.get("i") or []]
    return out


def tagged(f, u, m, w, d, data):
    """A copy of an object carrying the board tag of one membership (membershipTag)."""
    kind, ctx = m
    tag = {"tc": 1, "f": f, "u": u, "s": [], "w": w, "d": d}
    if kind == "g":
        if ctx != "_":
            tag["s"] = [ctx]
    else:
        tag["i"], tag["k"] = [ctx], "i"
    obj = dict(data)
    obj["GMNotes"] = json.dumps(tag)
    return obj


def catalog_cells(config):
    """The current catalog as (f, u, membership, tagged object) per board cell."""
    index = json.loads(export.read_text(export.CATALOG / "index.json") or '{"factions": []}')
    for faction in index["factions"]:
        for unit in faction["units"]:
            text = export.read_text(export.CATALOG / unit["file"]) or ""
            for line in text.split("\n"):
                if "\t" not in line:
                    continue
                info_text, data_text = line.split("\t", 1)
                info, data = json.loads(info_text), json.loads(data_text)
                # Fields the unit file keeps beside the data (see export.dump_unit).
                for short, key in (("n", "Nickname"), ("desc", "Description"), ("t", "Tags")):
                    if short in info:
                        data[key] = info[short]
                for m in memberships(info):
                    yield faction["id"], unit["id"], m, tagged(faction["id"], unit["id"], m, info["w"], info["d"], data)


def board_columns(board_f, config):
    """(f, u) of the columns of a faction's board: its units, then (not on the Mercenaries
    board) the mercenaries it hires and the units every warband can get."""
    factions = {f["id"]: f for f in config["factions"]}
    fe = factions[board_f]
    cols = {(board_f, u["id"]) for u in fe.get("units", [])}
    if board_f != MERC and MERC in factions:
        mercs = factions[MERC]
        hired = set(fe.get("mercenaries", []))
        for u in mercs.get("units", []):
            if u["id"] in hired or u.get("everyone"):
                cols.add((MERC, u["id"]))
    return cols


def on_board(board_f, f, m, subs):
    """Whether a membership of a column's model is shown (and so owned) by board_f's board."""
    if f == board_f:
        return True
    kind, ctx = m
    if ctx == "_":
        return False            # untagged / vanilla pick of a mercenary: the Mercenaries board
    if kind == "i" and ctx == board_f:
        return True             # this faction's vanilla import pick of the mercenary
    return ctx in subs          # this faction's subfaction rows


def publish(board_f, models, dry_run=False):
    """models: [{"f", "u", "kind", "ctx", "w", "d", "data"}] for every model lying in a cell of
    the board (data = the object's TTS object data). Returns a report (lines of text)."""
    config, lookup = export.load_config()
    cols = board_columns(board_f, config)
    subs = lookup[board_f]["subs"]
    objects = [obj for f, u, m, obj in catalog_cells(config)
               if not ((f, u) in cols and on_board(board_f, f, m, subs))]
    kept = len(objects)
    for mdl in models:
        if (mdl["f"], mdl["u"]) not in cols:
            continue
        data = mdl["data"] if isinstance(mdl.get("data"), dict) else json.loads(mdl["json"])
        objects.append(tagged(mdl["f"], mdl["u"], (mdl["kind"], mdl["ctx"]), mdl["w"], mdl["d"], data))
    result = export.build(objects, config, lookup)
    changed, version = export.write(result, dry_run)
    report = [f"Published {len(models)} model cell(s) of {board_f}; {kept} cell(s) of other boards kept.",
              f"Catalog version {version} ({'changed' if changed else 'unchanged'})."]
    if result["warnings"]:
        report.append(f"{len(result['warnings'])} warning(s): " + "; ".join(result["warnings"][:5]))
    gap_lines = export.gaps(config, result["index_factions"])
    if gap_lines:
        report.append("Gaps: " + "; ".join(gap_lines))
    return report


def check():
    """Round trip: the catalog as board cells, built again, must give the same files."""
    config, lookup = export.load_config()
    result = export.build((obj for _, _, _, obj in catalog_cells(config)), config, lookup)
    same = True
    for rel, text in result["files"].items():
        if export.read_text(export.CATALOG / rel) != text:
            print("differs:", rel)
            same = False
    old = json.loads(export.read_text(export.CATALOG / "index.json"))
    old.pop("version", None)
    if old != {"factions": result["index_factions"]}:
        print("differs: index.json")
        same = False
    print("round trip OK: the catalog rebuilds unchanged" if same else "round trip FAILED")
    return same


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="round-trip the current catalog (no writes)")
    args = parser.parse_args()
    sys.exit(0 if check() else 1)
