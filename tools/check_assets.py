"""Broken model check: are the catalog's mesh, texture and asset-bundle files still online?

Models point at their authors' Steam Cloud files. When an author deletes one, the model
spawns as a grey block or not at all. This asks the server for every distinct asset URL in
catalog/ (the first 16 bytes of each, nothing more is downloaded) and lists the models whose
files are gone, by faction, unit and line, so they can be put on Discard on the intake board
(or replaced).

    python tools/check_assets.py              check all factions
    python tools/check_assets.py mercenaries  check one faction

Exit code 1 if anything is broken. Takes about a minute for ~1,300 URLs.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "catalog"
WORKERS = 8
TIMEOUT = 20
RECHECK_PAUSE = 0.3   # seconds between rechecks


def urls_of(data, out):
    """Every asset URL in an object's data (fields ending in URL, attached parts included)."""
    if isinstance(data, dict):
        for k, v in data.items():
            if isinstance(v, str):
                if k.endswith("URL") and v.startswith("http"):
                    out.add(v)
            else:
                urls_of(v, out)
    elif isinstance(data, list):
        for x in data:
            urls_of(x, out)
    return out


def catalog_models(faction=None):
    """(faction, unit, line number, nickname, set of urls) per catalog model."""
    index = json.loads((CATALOG / "index.json").read_text(encoding="utf-8"))
    for fe in index["factions"]:
        if faction and fe["id"] != faction:
            continue
        for unit in fe["units"]:
            text = (CATALOG / unit["file"]).read_text(encoding="utf-8")
            for n, line in enumerate(text.split("\n"), 1):
                if "\t" not in line:
                    continue
                info_text, data_text = line.split("\t", 1)
                info = json.loads(info_text)
                yield fe["id"], unit["id"], n, info.get("n", unit["name"]), urls_of(json.loads(data_text), set())


def status(url):
    """HTTP status of a URL (0 = no answer). One retry, since the CDN sometimes drops a request."""
    for attempt in range(2):
        # A GET of the first bytes, not HEAD: Steam's CDN answers HEAD with 404 for some files
        # it serves fine (tested), and a ranged GET is what a download would see.
        req = urllib.request.Request(url, headers={"User-Agent": "tc-miniatures-asset-check", "Range": "bytes=0-15"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                r.read(16)
                return 200 if r.status in (200, 206) else r.status
        except urllib.error.HTTPError as e:
            if e.code in (404, 410) or attempt == 1:
                return e.code
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
            if attempt == 1:
                return 0
    return 0


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("faction", nargs="?", help="only this faction id")
    args = parser.parse_args()

    models = list(catalog_models(args.faction))
    users = defaultdict(list)          # url -> models using it
    for m in models:
        for u in m[4]:
            users[u].append(m)
    print(f"Checking {len(users)} asset URL(s) of {len(models)} model(s)...")
    with ThreadPoolExecutor(WORKERS) as pool:
        codes = dict(zip(users, pool.map(status, users)))
    # Steam's CDN answers 404 (not 429) to valid files when asked too much at once (tested:
    # 16 parallel requests flagged 661 of 712 models, all fine one by one). So every failure is
    # asked again, one at a time with a pause, before it counts.
    retry = [u for u, c in codes.items() if c != 200]
    if retry:
        print(f"Rechecking {len(retry)} failed URL(s) one at a time...")
        for u in retry:
            time.sleep(RECHECK_PAUSE)
            codes[u] = status(u)

    gone = {u for u, c in codes.items() if c in (404, 410)}
    unsure = {u: c for u, c in codes.items() if c != 200 and u not in gone}
    broken = defaultdict(set)           # (f, u, line, name) -> broken urls
    for u in gone:
        for f, unit, n, name, _ in users[u]:
            broken[(f, unit, n, name)].add(u)
    if broken:
        print(f"\n{len(broken)} model(s) with missing files ({len(gone)} URL(s) gone):")
        for (f, unit, n, name), us in sorted(broken.items()):
            print(f"  {f}/{unit} line {n} ({name}): {len(us)} file(s) gone, e.g. {sorted(us)[0]}")
    if unsure:
        print(f"\n{len(unsure)} URL(s) gave no clear answer (try again later):")
        for u, c in sorted(unsure.items())[:20]:
            print(f"  {c or 'no answer'}: {u} (used by {len(users[u])} model(s))")
    if not broken and not unsure:
        print("All asset files are online.")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
