"""Offline test of tools/publish.py and export.py against the current catalog (no TTS, no writes).

    python tools/test_publish.py

Checks:
- the catalog rebuilds unchanged (publish.check);
- every faction's board, published exactly as the catalog shows it, changes nothing (the board
  ownership rules of publish.py match what the intake shows: a cell owned by no board would be
  lost, one owned by two would be doubled);
- a move, a copy into an Import row and a removal on the Mercenaries board change exactly the
  counts they should.
Run it after changing export.py, publish.py or the catalog format.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import export    # noqa: E402
import publish   # noqa: E402

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  ({detail})"))


def board_models(board_f, config, lookup):
    """The models the intake would show on board_f's board, as it sends them on Publish."""
    cols = publish.board_columns(board_f, config)
    subs = lookup[board_f]["subs"]
    out = []
    for f, u, m, obj in publish.catalog_cells(config):
        if (f, u) in cols and publish.on_board(board_f, f, m, subs):
            tag = json.loads(obj["GMNotes"])
            out.append({"f": f, "u": u, "kind": m[0], "ctx": m[1], "w": tag["w"], "d": tag["d"], "data": obj})
    return out


def build_with(board_f, models, config, lookup):
    """Index units ({f/u: (count, any, subs)}) after publishing models as board_f's board."""
    cols = publish.board_columns(board_f, config)
    subs = lookup[board_f]["subs"]
    objects = [obj for f, u, m, obj in publish.catalog_cells(config)
               if not ((f, u) in cols and publish.on_board(board_f, f, m, subs))]
    for mdl in models:
        objects.append(publish.tagged(mdl["f"], mdl["u"], (mdl["kind"], mdl["ctx"]), mdl["w"], mdl["d"], mdl["data"]))
    result = export.build(objects, config, lookup)
    return result, {f"{fe['id']}/{u['id']}": (u["count"], u.get("any"), u.get("subs") or {})
                    for fe in result["index_factions"] for u in fe["units"]}


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    config, lookup = export.load_config()
    check("round trip: the catalog rebuilds unchanged", publish.check())

    current = {}
    for rel, text in export.build((o for *_, o in publish.catalog_cells(config)), config, lookup)["files"].items():
        current[rel] = text
    for fe in config["factions"]:
        models = board_models(fe["id"], config, lookup)
        result, _ = build_with(fe["id"], models, config, lookup)
        changed = [rel for rel, text in result["files"].items() if current.get(rel) != text]
        changed += [rel for rel in current if rel not in result["files"]]
        check(f"unchanged board: {fe['id']} ({len(models)} cells)", not changed, changed[:3])

    # Edits on the Mercenaries board.
    merc = publish.MERC
    models = board_models(merc, config, lookup)
    _, before = build_with(merc, models, config, lookup)
    obs = [m for m in models if m["u"] == "observer" and m["kind"] == "g"]
    dogs = [m for m in models if m["u"] == "dogs"]
    if obs and dogs:
        # Move one Observer to Witchburner, copy one Dogs model into the Import row, remove another.
        moved = dict(obs[0], u="witchburner")
        copy = dict(dogs[0], kind="i", ctx="_")
        edited = [m for m in models if m is not obs[0] and m is not dogs[-1]] + [moved, copy]
        _, after = build_with(merc, edited, config, lookup)
        k = lambda u: f"{merc}/{u}"   # noqa: E731
        check("move: Observer -1", after[k("observer")][0] == before[k("observer")][0] - 1,
              (before[k("observer")], after[k("observer")]))
        check("move: Witchburner +1", after[k("witchburner")][0] == before[k("witchburner")][0] + 1,
              (before[k("witchburner")], after.get(k("witchburner"))))
        # The copy merges into its model (no new entry); the removal takes one away, unless the
        # removed model has other cells left.
        removed_key = json.dumps(export.dedupe_key(dogs[-1]["data"]))
        others = [m for m in edited if m["u"] == "dogs" and json.dumps(export.dedupe_key(m["data"])) == removed_key]
        want = before[k("dogs")][0] - (0 if others else 1)
        check("copy + remove: Dogs count", after[k("dogs")][0] == want, (before[k("dogs")], after[k("dogs")], want))
        untouched = [u for u in before if u not in (k("observer"), k("witchburner"), k("dogs")) and before[u] != after.get(u)]
        check("edits touch no other unit", not untouched, untouched[:3])

    failed = results.count(False)
    print(f"\n{len(results) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
