# TC Miniatures Spawner (Tabletop Simulator)

Project handoff for Claude Code. Maintainer: Niklas. Programming is AI-assisted; keep code readable and comment non-obvious TTS quirks.

## What this is

A Tabletop Simulator (TTS) mod for **Trench Crusade** that aggregates miniatures from many other workshop mods so players can find models for their TC warbands.

**Current state (legacy):** One save with 7 per-faction "memory bags" (New Antioch, Trench Pilgrims, Iron Sultanate, Mercenaries, Heretic Legion, Black Grail, Court). Each bag stores GUID + position of models laid out by hand, with hand-made 3D text labels per unit. Place pulls models out of the bag, and Recall puts them back. Some factions have ~400 models. Legacy scripts are in `legacy/`.

**Goal:** A single spawnable object that pulls the catalog from GitHub, spawns only what the player asks for in an auto-generated labelled layout, and updates itself.

## Priorities (in order)

1. **Find models for your TC army.** Load only what is requested, never everything at once.
2. **Organized.** Models are grouped by faction, then unit, with labels.
3. **Low maintainer effort.** No manual positioning or per-model clicking. Adding new models must be easy.

Out of scope: per-model author credits (too much manual work). A static credits list maintained by hand is fine.

## Architecture

```
TTS dev save (maintainer only)          Repo (GitHub, public)                 Player's TTS
┌──────────────────────┐   save   ┌──────────────────────────┐  WebRequest ┌──────────────┐
│ Intake station:      │ ───────► │ tools/export.py reads    │ ──────────► │ Spawner obj: │
│ zone + dropdowns     │  (.json) │ save → writes catalog/   │             │ menu, spawn, │
│ writes tags to       │          │ git push                 │             │ recall,      │
│ GM Notes             │          └──────────────────────────┘             │ self-update  │
└──────────────────────┘                                                   └──────────────┘
```

- The **spawner object contains no models.** It fetches a small index on load and fetches one unit file on demand.
- TTS cannot write files to disk, but **TTS saves are plain JSON on disk**. So tagging happens in TTS, and publishing happens through a Python script that reads the save.

## Repo layout (proposed)

```
CLAUDE.md
legacy/                     original scripts (memory bag, UI extender, KT box reference)
tts/
  intake.lua                intake station object script (dev save only)
  spawner.lua               the published spawner object script
config/
  units.json                factions → units → subfactions (maintained by hand)
  equipment.json            battlekit item → range/keywords (from Trench Companion), used by warband import
  credits.json              static credits list (optional)
tools/
  export.py                 save → catalog
  tts_bridge.py             live link to a running TTS (External Editor API): log prints/errors, run Lua in-game
docs/index.html             warband converter page (GitHub Pages): Trench Companion export -> import code
catalog/                    GENERATED, do not edit by hand
  version.json
  index.json
  units/<faction>/<unit>.json
```

## Data formats

### Model tag (written by intake into the object's GM Notes)

```json
{"tc":1,"f":"heretic-legion","u":"death-commando","s":["knights-of-avarice"],"w":1.2,"d":1.2}
```

- `f` is the faction id, `u` the unit id, and `s` the **theme**: the subfactions the model was made for. Empty = the faction's vanilla look. A mercenary's `s` may name another faction's subfaction (a Goetic Warlock made for Knights of Avarice).
- `i` (optional) = import priority: contexts whose warband imports should prefer this model. `_` = vanilla, else a subfaction id; on a hired mercenary a faction id means that faction's vanilla imports (`_` on a mercenary = the Mercenaries board's own pick).
- `k: "i"` marks an import copy: its `s` is meaningless (the model's theme lives on its General copy). A model with no General copy at all counts as General for its import contexts too (see Export), so moving a model into an Import row is enough; copy it only to also keep it under another theme.
- The sorting board writes exactly one membership per object: `{"s":[]}`, `{"s":[C]}` or `{"s":[],"i":[X],"k":"i"}`. A model in several cells is several copies. Older tags with several entries are split into copies when their board opens.
- `w`/`d` are the footprint (bounds x/z) captured at intake. Bounds are not stored in save JSON, and the spawner needs them to lay out the grid before models finish loading.
- GM Notes is used because it survives in the save JSON and players don't see it.

### config/units.json

```json
{
  "factions": [
    {
      "id": "heretic-legion",
      "name": "Heretic Legion",
      "mercenaries": ["goetic-warlock", "sin-eater", "golem", "dogs"],
      "subfactions": [{"id": "knights-of-avarice", "name": "Knights of Avarice"}],
      "units": [
        {"id": "heretic-trooper", "name": "Heretic Trooper"},
        {"id": "death-commando", "name": "Death Commando"}
      ]
    }
  ]
}
```

- Faction ids: `new-antioch`, `trench-pilgrims`, `iron-sultanate`, `heretic-legion`, `cult-of-the-black-grail`, `court-of-the-seven-headed-serpent`, `mercenaries`.
- Unit and subfaction lists should match official TC / Trench Companion naming. Seed them from the official rules and do not invent units. Add a per-faction `misc` unit for models that fit nothing.
- `intake.lua` fetches this file from the repo with WebRequest (or uses `LOCAL_UNITS_JSON`).
- `mercenaries` = Mercenaries unit ids the faction can hire: extra columns on its sorting board and extra unit chips in its spawner menu. A subfaction can override it with its own list (Trench Ghosts: `[]`, no cells in its rows / no merc chips under its filter). Lists from Niklas (Oct 2026): Scripture Guardian for all; Court and Heretic Legion: Sin Eater, Goetic Warlock, Hellhound; Black Grail: Sin Eater, Hellhound; New Antioch: Anti-Tank Communicant, Ammo Monk, Mamluk Faris, Observer, Combat Biologist, Witchburner, Dogs; Iron Sultanate: Mamluk Faris, Combat Biologist, Dogs; Pilgrims: Anti-Tank Communicant, Sister of Saint Cosmas, Ammo Monk, Observer, Witchburner, Dogs. Golem is no mercenary: it has `"everyone": true` on its Mercenaries unit and shows on every faction board and menu, also for Trench Ghosts (subfaction lists don't remove it). Merc models made for a subfaction exist practically only for Knights of Avarice.

### catalog/index.json (generated)

```json
{
  "version": 12,
  "factions": [
    {"id": "heretic-legion", "name": "Heretic Legion",
     "subfactions": [{"id": "knights-of-avarice", "name": "Knights of Avarice"}],
     "mercenaries": ["goetic-warlock", "sin-eater", "golem", "dogs"],
     "units": [{"id": "death-commando", "name": "Death Commando", "count": 14,
                "any": 10, "subs": {"knights-of-avarice": 4},
                "file": "units/heretic-legion/death-commando.json"}]}
  ]
}
```

Keep it small. It is decoded on every load. `any` is the number of vanilla models (empty `s`, or `_` in a merged `s`), `subs` maps subfaction id to the number of models made for it (on a mercenary unit also other factions' subfactions). Spawner filters: All = `count`, Vanilla = `any`, subfaction C = `subs[C]`, or `any` with the chip marked "(vanilla)" when `subs[C]` is 0. `mercenaries` is copied from `config/units.json`.

### catalog/units/<faction>/<unit>.json (generated)

This is an array of entries:

```json
[{"s": ["knights-of-avarice"], "w": 1.2, "d": 1.2, "data": { ...TTS ObjectData... }}]
```

`data` is the object's entry from the save's `ObjectStates`. `export.py` cleans it as follows:

- Remove `LuaScript`, `LuaScriptState`, `XmlUI`, `GUID`, `ContainedObjects`, and the `GMNotes` tag (it is moved to `s`/`w`/`d`).
- Zero `Transform.posX/posY/posZ` and keep rotation and scale.
- Keep `CustomMesh`, `ColorDiffuse`, `Nickname`, `Description`, `Tags`, and physics/material fields.

### catalog/version.json

```json
{"catalog": 12, "spawner": 3, "spawnerUrl": "tts/spawner.lua"}
```

## Components

### 1. Intake station (`tts/intake.lua`)

This exists in the maintainer's dev save only. It is a **sorting board** (rebuilt Oct 2026; the old single zone with unit/subfaction/import toggles is gone). UI (object XML UI): faction dropdown, **Open board** / **Pull from catalog** / **Close board**, Check unsorted, Reload config, status.

- **Open board** lays out a grid right of the station (the bags lie on its left), read left to right from the faction's first unit (its leader) to its mercenaries: one column per unit of the faction, then one per mercenary it hires (`mercenaries` in units.json, labelled "(merc)"); two rows per context, Vanilla first, then each subfaction, each with **General** (theme) and **Import** (priority). A hired mercenary has no Vanilla General cell (untagged mercs live on the Mercenaries board, which has only the Vanilla rows). A red **Discard** strip lies beyond the last row. Every catalogued model of those units is taken out of its unit bag into its cell (cells sized to their contents plus `SPARE_D` room). Tiles and labels carry tag `TCM_Board`.
- The maintainer then works by moving models: drop a new one into a cell, move one to retag it, copy (Ctrl+C/V) to put it in several cells, drop it on Discard to destroy it.
- **Drop feedback:** the dropped model's cell and that cell's count go to the status. The same model (asset URLs + scale + attached parts, like export's `dedupe_key`) already in this cell: red "DUPLICATE"; in other cells: yellow "Also in: ..." (often an intended copy); else green.
- **Close board** refuses while models lie on the board outside any cell (highlighted red). Otherwise it tags each model by its cell (`w`/`d` from `getBounds().size`), strips scripts/UI (source mods ship heavy per-model scripts), puts it into its unit bag, destroys Discard models and the board.
- The board geometry and the station's position/yaw at opening are saved in `script_state`, so a save/reload with the board open continues, and moving the station doesn't shift the cells. One board at a time.
- Orientation (fixed Oct 2026): the player stands on the station's local **+z** side (the panel's rotation `0 0 180` reads upright from there, as on the spawner), so board x (their right) is local -x and board z (away) is local -z (`frameToWorld`). The first version assumed -z and came out mirrored (mercs left, leader right, header far away). `MODEL_YAW` 0 / `LABEL_YAW` 180 copy the spawner's tested values.
- **Pull from catalog** (button, per faction in the dropdown, only with no board open) syncs the bags with the published catalog: every catalog model of the faction's board columns that no bag holds (compared by model identity, scale to 2 decimals since the catalog rounds transforms) is spawned with a tag rebuilt from its entry and put into its unit bag. It only adds; models in the bags and their tags win, so new local models are safe. Not automatic on load: a model discarded locally but not yet exported would come back, so export before pulling. Rebuilt tags carry the merged `s`, which can hold `_` (vanilla) next to themes; the board splits them into one copy per cell on opening, and export reads `_` in `s` as a vanilla General copy.

### 2. Export (`tools/export.py`)

- Input: the path to the TTS save (`Documents/My Games/Tabletop Simulator/Saves/*.json`).
- Walk `ObjectStates` **recursively**, including `ContainedObjects` (models in bags).
- Collect objects whose GM Notes parse as a `{"tc":1,...}` tag.
- Validate against `config/units.json` and print unknown faction/unit/subfaction ids. Do not write invalid entries.
- Identify models by `dedupe_key` (mesh/texture/scale of the object and all attached parts). Copies of one model within a unit in **different** board cells are merged (below); the same cell twice is reported as a duplicate and dropped.
- **Merge (built Oct 2026, `merge_copies`; catalog 10):** the sorting board makes copies on purpose, so identical models within one unit are **merged** into one entry: `s` = union of the General copies' themes (a vanilla copy adds `_` when themed copies exist too; `k:"i"` copies add no theme), `i` = union of all copies' `i`. **Exception (Niklas, Oct 2026):** a model with no General copy at all (only `k:"i"` copies) counts as General for each of its import contexts too, so `s` = its subfaction import contexts (`_` for vanilla; a mercenary's faction-id key counts as vanilla). Reason: moving a model into an Import row (instead of copying it) is the natural workflow; the Oct 2026 audit of the dev save found 71 such models (Holy Warrior, Feldkaplan, Swiss Lieutenant, Lazarist Prophet, ...) that would otherwise lose their theme. Validation accepts subfaction ids of any faction in a mercenary's `s`/`i`, faction ids in a mercenary's `i`, and `k: "i"`. `any`/`subs` count merged entries as above, and `index.json` gets each faction's `mercenaries` list, the subfactions whole (with their own `mercenaries` lists) and units' `everyone` flag.
- Clean the data as described above, then write the unit files and `index.json`. Sort the output deterministically so git diffs stay readable.
- Bump `catalog` in `version.json` only if the output changed.
- Print a summary of counts per faction and unit, plus warnings.

### 3. Spawner (`tts/spawner.lua`)

This is the published object. It must work when spawned anywhere and at any rotation.

- **On load:** fetch `version.json`, then `index.json`, and build the menu (object XML UI). Show a "loading" state until the callback arrives.
- **Menu:** Faction, then a unit list with counts. A subfaction filter limits the unit list and the models to those tagged for that subfaction or untagged. Buttons: "Spawn unit" and "Spawn whole faction".
- **Spawn:** fetch the unit file and spawn with `spawnObjectData` in **batches** (e.g. 10–20 per tick, using `Wait.frames`/`Wait.time`).
- **Layout:** one row per unit, laid out using the stored `w`/`d` plus padding, with wrapping after a maximum row width. Put a 3D text label above each row, spawned as a `3DText` object. Positions are relative to the spawner and rotated with it, so reuse the maths in the KT box's `compare_coords`.
- **Tracking:** tag every spawned object `TCM_Spawned` and record the spawner's GUID in its memo/GM Notes.
- **Recall / Clear:** destroy everything this spawner spawned. Nothing goes back anywhere because the data is always remote.
- **Self-update:** if `version.json.spawner` is greater than the local `SPAWNER_VERSION`, fetch `spawnerUrl`, then `self.setLuaScript(code)` and `self.reload()`. Note that `reload()` returns a new object reference.

### 4. Later

- **UI Extender features** on spawned models: range rings via number typing, activation, blood/blessed/infection counters, and tokens. Avoid injecting ~10 KB scripts per model as the legacy extender does. First check whether object scripts receive `onObjectNumberTyped` / `onObjectPickUp` / collision events for other objects. If they do, the spawner handles everything centrally. If not, use a minimal stub script per model that forwards events to the spawner via `getObjectFromGUID(spawnerGuid).call(...)`.
- **Warband import (built, Oct 2026):** the only import path is a **code**: players paste Trench Companion's TTS export into the converter page `docs/index.html` (GitHub Pages, `https://priestofmork.github.io/TTS-TC-Model-Collection/`), which packs it in the browser into `TCM1` + JSON `{n, i, s, m}` (every distinct text once in `s`, models as arrays of 0-based indexes; format comment in the page, `decodeWarband` in spawner.lua must match). Nothing is uploaded or stored. 14 models: 27,177 → ~2,900 characters, so any warband fits. Why: TTS text boxes cut at ~15,800 characters (Unity UI limit) even single-line, the TTS Scriber mod hits the same limit (its workaround is a Cloud Manager link), and a multi-line paste box crashed TTS. The code box is single-line + `onEndEdit`; the page address is shown in a read-only box (scripts can't open a browser). Niklas chose one import way only (no raw-export paste) to keep it simple for players. Trench Companion's public API (`synod.trench-companion.com/wp-json/synod/v1/warband/<id>`) only has internal ids, no names/stats, so it can't replace the export. Samples: `legacy/Example trench companion tts export json.txt` (Iron Sultanate) and `legacy/example-export-new-antioch.json` (New Antioch: named models, variants, mercenaries, a dog). Format: `warband-name`, `warband-id`, `models[]` with `model-id`, `model-name`, `name`, `stat-move/melee/ranged/armour`, `cost`, and lists `equipment` (with `equipment-abilities`), `abilities`, `upgrades`, `advancements`, `injuries`, `keywords` (each `<kind>-name`/`<kind>-id`). No faction field. **Matching** (`matchModel` in spawner.lua): full id in a unit's `companion` list, else the id's base (`md_<base>_...`) in a `companion` list, else base == unit name without spaces/punctuation. `companion` lists live in `config/units.json` (exceptions like `mechanisedheavyinfantry`, `janissaries`, `md_takwincreation_golem`, `md_wretched_court`) and are copied into `index.json`. All 25 models of both samples match. The whole warband spawns on one platform labelled with its name; copies of a unit get different catalog models. The import does **not** depend on the faction open in the console (Niklas, Oct 2026): units come from the model ids, models from the vanilla picks (the export doesn't name the subfaction); mercenaries get the warband's majority faction for their activation icon and its vanilla import pick. The import status and box tell players where the export is: Trench Companion, Export Warband, style "TTS JSON", Copy to Clipboard. Name and description follow Niklas's stat-block format (see `nameBlock`/`describe` in spawner.lua): `Nickname` = `[b]☩☩ <name> ☩☩[/b]`, `(<model-name>)`, the bold coloured stat line (`Mel. +2D`, `Ran. +3D`, `Arm. -1`) and the keywords. `Description` = equipment grouped by type with symbol/colour (melee ✞ fa8231, ranged ⊕ C966E5, equipment ✜ f7b731, shield ☩ fa8231, armour ☩ b2b7be (guess), grenade ✢ fa8231, special ✜ fa8231), each followed by a line with range (melee/ranged only) and upper-case keywords; then abilities ✧ 0fb9b1 + upgrades ✹ 618DF4; then advancements △ 20bf6b; then injuries ✖ eb3b5a (guess). Ranges/keywords aren't in the export: they come from `config/equipment.json` (216 items read from Trench Companion's battlekit pages, keyed by item name; faction-only items like Engineer Body Armour are missing and show without a detail line), fetched by the spawner on import. Unmatched or not-yet-catalogued models are listed in the status line.
- A static in-game credits panel built from `config/credits.json`.

## TTS / MoonSharp gotchas

- `WebRequest.get(url, callback)` is async. Check `req.is_error` and use `req.text`.
- raw.githubusercontent.com caches for a few minutes, so append `?v=<timestamp or version>` to every URL.
- **Never run Lua patterns on large strings** (MoonSharp throws "pattern too complex"). Use plain `string.find(s, x, 1, true)`. `JSON.decode` on large strings is slow, which is why the data is split into per-unit files. `spawnObjectJSON`/`spawnObjectData` parse natively and fast.
- GUIDs are not stable. TTS reassigns them on collision, which is common in aggregated mods, so never use a GUID as an identity for catalog data.
- `self.reload()` replaces the object, so don't use the old reference afterwards.
- Some `Physics.cast` hits (parts of the table) have no GUID. Don't use `getGUID()` as a table key without checking it.
- MoonSharp's `table.remove(t, 1)` **throws** ("position out of bounds") on an empty table, where standard Lua returns nil. Check `#t == 0` first. An error inside a `Wait` callback silently kills that loop, so batch loops run each job in `pcall` to avoid getting stuck in a busy state.
- A deck reduced to one card collapses into a Card. This isn't relevant for models but is noted in the KT script.
- Object XML UI is drawn in element order, not depth-sorted, and both sides of a panel render. Closed 3D shapes (cubes) show back faces in front; only stacks of parallel layers look right. `Button`s have a rounded sprite; use `Image`/`Panel` for square shapes.
- Returning true from `onObjectNumberTyped` in an object script does not stop TTS's default number handling on another object. The object's own `onNumberTyped` returning true does.
- External Editor API: TTS does not send messageID 5 return values for executed code; `tools/tts_bridge.py run` wraps code to `print` its result instead.
- Object XML UI `tooltip`s render on the ground below the object and can stay stuck after the element is removed. Don't use them on model panels.
- XML UI text elements cut off around 16,000 characters (Unity's vertex limit), and long multi-line `InputField` pastes can crash TTS. For big pastes use `lineType="SingleLine"` + `onEndEdit`.
- `getBoundsNormalized()` counts the object's `createButton` buttons (a 1" block with a 7" status button measured 11 x 14"), and the value can lag behind `clearButtons()`. Measure an object before giving it buttons; the spawner measures itself once in `onLoad` (`hubBounds`). `getBounds()` doesn't include them but is rotation-dependent.
- `createButton` labels are only as opaque as the button's `color`: alpha 0 hides the label, 0.3 shows it faint. Invisible click areas get no label; labelled buttons need an opaque background (plain chips use their own colour as the button face).
- Button text reads upright from the object's local +z side with button rotation `{0, 0, 0}`; 500 button units ≈ 1 world inch (both measured, Oct 2026).
- XML UI `setCustomAssets` with a `nil` URL fails. Guard against it, and never retry in an unbounded loop.
- Model meshes and textures point at original authors' Steam Cloud URLs. If an author deletes them, the model breaks. Rehosting is a possible future step.

## Known bugs in legacy code (for reference, not to port)

- Memory bag `Recall` is not batched, so all objects go in on one frame.
- UI extender: `initializeTCUI()` without params leaves `imgReady = nil`, and `executeCreateUI` then retries `createUI()` forever on failure.
- UI extender has no Mercenaries entry in `FACTIONS`/`factions_img`.
- UI extender token names are concatenated raw into XML `onClick`, which breaks on special characters.

## Build order

1. `config/units.json` skeleton for one small test faction.
2. `tts/intake.lua`, tested in the dev save.
3. `tools/export.py`, tested against that save, producing `catalog/`.
4. `tts/spawner.lua` with menu, spawn, layout and recall, tested against the pushed catalog.
5. Migrate all factions through intake.
6. Self-update, then UI extender features, then warband import (once a sample exists).

## Debugging in the live game

`tools/tts_bridge.py` talks to a running TTS on this PC. `python tools/tts_bridge.py listen` (keep running in the background) logs everything TTS sends (print output, Lua errors, saves) to `tts.log`. `python tools/tts_bridge.py push tts/spawner.lua --guid <guid>` loads a local script file into an object and reloads it (to try changes before pushing to GitHub). `python tools/tts_bridge.py run "<lua>" --guid <object guid>` runs code inside that object's script environment (it must have a script; `-1` = Global) and prints the result, e.g. to read positions, lock state, memos or `script_state`, or to call an object's global functions to simulate events. While the listener runs, opening the script editor on an object without a script goes to the listener instead of the in-game editor.

## Open decisions

(none)

## Decided

- Repo: https://github.com/PriestofMork/TTS-TC-Model-Collection (must be public: the spawner fetches raw files without auth). Raw base URL: `https://raw.githubusercontent.com/PriestofMork/TTS-TC-Model-Collection/main/`.
- Test faction: Mercenaries. UI extender features are skipped for the test, but Mercenaries must be covered later.
- Unit names come from Trench Companion (trench-companion.com/compendium). Mercenaries: Combat Biologist, Communicant Anti-Tank Hunter, Goetic Warlock, Mamluk Faris, Mendelist Ammo Monk, Observer, Scripture Guardian, Sin Eater, Sister of Saint Cosmas (formerly Combat Medic), Witchburner. Goetic Warlock and Sin Eater are the heretic-side mercs.
- All factions' units come from Trench Companion's compendium (Oct 2026): each faction's base list, then the extra units each variant adds. Variant warbands are subfactions. Rules for mapping:
  - Heretic Naval Raiders and Procession of the Sacred Affliction are "semi-factions" since the Carcass Front update: still subfactions of Heretic Legion / Trench Pilgrims, but with their own variants (The Drowned Choir, Leviathan Shoal / The Knights of Saint Lazarus, Procession of the Blessed Flock). Models exist for Naval Raiders / Sacred Affliction, not for their sub-variants, and the spawner filter only matches exact subfaction ids. So their sub-variants are **not** subfactions here (players pick the parent semi-faction), but units unique to them (Leper Knight, Choir Wretched, …) are in the unit lists.
  - **Variant versions of a base unit are not separate units.** A Highland Lieutenant is a Lieutenant tagged with subfaction Kingdom of Alba; a Holy Warrior is a Trench Cleric tagged Abyssinia. Source of truth: Trench Companion model ids have the form `md_<base>_<variant>` (e.g. `md_janissaries_mv_dervish`, `md_plagueknight_executor`), visible in the site's `/model-image/<id>` requests and an old→new id table in its JS bundle. Merged (Niklas + model ids, Oct 2026):
    - New Antioch: Eire/Highland Lieutenant → Lieutenant; Lector, Eire Warrior Priest, Holy Warrior → Trench Cleric; Highland/Abyssinian Mechanized Infantry → Mechanized Heavy Infantry; Highland Shocktrooper → Shocktrooper. Crimson Communicant stays (Red Brigade only).
    - Trench Pilgrims: Lazarist Prophet → War Prophet; Lazarist Castigator, Leper Knight → Castigator; Lazarist Communicant (of the Flock) → Communicant; Leper-Pilgrims → Trench Pilgrim.
    - Iron Sultanate: Master Assassin → Sultanate Assassin; Assassin Acolyte → Azeb; Fāris, Dervish, Janissary Officer → Janissary; Silahdar → Yüzbaşı Captain.
    - Heretic Legion: Heretic Priest of Mammon, Heretic Captain → Heretic Priest; Abyssal Commando → Death Commando; Anointed Heretic Raiders → Anointed Heavy Infantry; Artillery Witches of Mammon, Sea Hag → Artillery Witch; Heretic Raider → Heretic Trooper; Drowned / Leviathal Chorus Chorister, Barbed Wire Banshee (Trench Ghosts) → Heretic Chorister; Choir / Raider's Wretched → Wretched. Naval Raiders models are tagged as these base units with subfaction Heretic Naval Raiders.
    - Black Grail: Executor, Butcher Knight → Plague Knight; Dessicated Husk → Corpse Guard; Great Maw → Lord of Tumors; Bereaved, Ravenous, Cradle Ravenous → Grail Thrall; Fly Bereaved → Fly Thrall.
    - Dogs (Attack/Guard/Mercy/Trench Dog; ids `md_trenchdog_*`) → one "Dogs" unit under Mercenaries (faithful factions); **Hellhound** is its own Mercenaries unit (heretic factions; companion id `md_trenchdog_hellhound` is a guess, check against a real export). Hounds of the Black Grail stay a Black Grail unit.
    - Kept separate although the id names another base, because the models look different: Fly Thrall (`md_grailthrall_flythrall`), Sipahi Automaton Cavalry (`md_mamlukfaris_mv_sipahi`).
    For warband import, renamed model ids need an alias to their base unit; the `md_<base>_` prefix gets most of the way.
  - Subfaction semantics (revised Oct 2026; players want to find models, both with the most choice and themed): `s` is the theme and **Vanilla is a theme of its own** (empty `s`). Spawner filters: **All models** (everything of the unit, any theme), **Vanilla**, and each subfaction (models made for it; units without any fall back to vanilla, marked "(vanilla)", because subfactions often just use vanilla models). To get rid of a mis-input entirely, use the board's Discard strip (or delete the object: export reads every tagged object in the save, also loose ones outside bags).
  - Court's subfactions are the Seven Deadly Sins as Trench Companion names them (Wrath, Envy, Lust, Pride, Sloth, Gluttony, Greed). Sin-specific models get that sin; general Court models (e.g. most Wretched) stay untagged.
  - Golem (Book of Golems, an exploration reward any warband can get, also Trench Ghosts; originally from Iron Sultanate's House of Wisdom: a homunculus with the GOLEM keyword) is a unit under Mercenaries, the catalog's "usable by any warband" section, flagged `"everyone": true`. The only exploration unit so far.
  - **One model, several units:** a tag holds one unit. When a model fits several units (a Takwin Homunculus that's also a Golem), copy it in TTS and tag the copy for the other unit. Export keeps the same model under different units (listed as info "Models used by several units") and only drops duplicates within one unit.
  - Goetic Warlock is a Mercenaries unit. Knights of Avarice (and other heretic subfactions) get Goetic Warlocks made for them through the theme: on the Heretic Legion board's Goetic Warlock column, Knights of Avarice General gives `f: mercenaries, s: ["knights-of-avarice"]`. New Antioch's "Combat Medic" and the mercenary "Sister of Saint Cosmas" are separate units.
  - Spellings follow the site, including its typos ("Dessicated Husk", "Leviathal Chorus Chorister", "Detatchment").
- Legacy scripts are a source of ideas only, not the reference implementation.
- Intake stores models in one bag per unit (not a grid), found by a `{"tcbag":1,"f":..,"u":..}` marker in the bag's GM Notes.
- Model structure in practice: the tagged top-level object is usually the **base**, with the sculpt attached as a `ChildObject` (occasionally the base is part of the sculpt mesh). Many models share the same base, so duplicate detection keys on the whole assembly: the object's own mesh/texture/scale plus all attached parts, recursively.
- Export details beyond the spec above: `ChildObjects` (the attached sculpts/parts) are kept and stripped recursively, as are `States`. `Nickname` is replaced by the unit name (source nicknames are often stat blocks). `TypeIndex` is set to 1 (Figurine) on the top-level `CustomMesh`/`CustomAssetbundle`, since other table scripts look for figurines. `rotY` is reset to 0 (w/d swapped if the model was turned sideways) so all models face their mesh forward. `Locked` is set to false. Empty `s` may arrive as `[]` or `{}`.
- Object XML UI z is height in UI units (100 per local unit). Both scripts compute it from `getBoundsNormalized()` so the panel sits on top of whatever object they're on.
- Spawner menu: clicking a unit toggles it (spawn / remove), instead of select + "Spawn unit". Spawned objects get tag `TCM_Spawned` and memo `<token>|<faction>/<unit>`, where the token is a random id in the spawner's saved state (survives GUID changes). Each unit (and an imported warband) is a block on its own platform: its models wrap at `MAX_ROW_WIDTH` (12"), and blocks are packed (top row first, then leftmost; the label on each block's player-facing edge) into an area `AREA_WIDTH` (27") wide to the right of the console, so a removed unit's space is reused (`findSpot`; places saved as `blocks` in the state). "Clear all" removes every `TCM_Spawned` object (any spawner), so models orphaned by a script reload are cleaned up too. State is written to `script_state` immediately (not only in `onSave`) so reloads keep the token.
- **Extend UI area (spawner v11):** a fourth console icon (Wolf art) shows / hides a gold-framed area right of the console, `EXT_GAP` (2", platforms are 2" high and hide what's just behind them) beyond the spawn area's top edge, `EXT_W` x `EXT_D` (14 x 6"), with a row of faction icons to pick from. The spawner's `onObjectDrop` gives any figure (`Custom_Model`, `Custom_Assetbundle`, `Figurine_Custom`) dropped in it the model script with that faction (`script_state` first, then `setLuaScript` + `reload`, `taken` true); a model already running it only gets `setFaction`. The area's fill, frame and texts have `raycastTarget="false"` so models on it can be picked up. Replaces the legacy "UI extender". State `extendOn` / `extendF` is saved.
- **Spawner object:** a `Custom_Tile` with Mike Franchina's Sword Saint art (`https://cdnb.artstation.com/p/assets/images/images/022/892/925/large/mike-franchina-sword-saint-female.jpg?1577126961`), published at scale 1.5, 1, 1.5. Its size at scale 1 is the constant `HUB_SIZE` (2.5686 x 0.2 x 2, measured) instead of a measurement. The hub is not a button (players drag it around freely); the console is always open.
- **Side console (spawner v9, Oct 2026)**, chosen by Niklas over a cascade layout: one object XML panel drawn by the hub, nothing spawned, so it opens instantly. Status box beside the hub; three art icons below it (Import, Settings, Clear all; TC art hotlinked from ArtStation); a column of faction icons (the activation-token icons, the open one bright, the others dimmed); next to them the list column: faction name, filter tabs (All models, Vanilla, subfactions), unit rows with counts (dark red while on the table; hired mercenaries marked "(merc)", vanilla fallback "(vanilla)"), "Spawn whole faction". Import and Settings (Model scripts on/off, Reload catalog) replace the list column while open. Coordinates are world inches relative to the hub (the root panel's scale undoes the hub's, rotation `0 0 180`: UI +x = player's right, +y = away); clicks go to `ui_click` with the element id as the action. Without a loaded catalog only the status and a "Reload catalog" row show. Tested in TTS. History: v8 spawned the menu as physical tokens (`Custom_Token`/`Custom_Tile`/`BlockSquare` with `createButton`s, hop-and-drop press for a click sound); Niklas dropped physical objects as buttons (spawn delay) but kept the spread-out, separate-pieces look. Leftover `TCM_UI` tokens are destroyed on load.
- Spawn area: always relative to the spawner (no absolute board coordinates; players put the cube where there's room). Each unit gets its own plain, dark, locked platform with its top 2" above the spawner's base, so models never land in terrain or on the board. It's spawned before its models and removed with its unit (same tag/memo). The area lies right of the console, its top edge level with the hub's far edge, rows growing toward the player.
- **Model script (`tts/model.lua`)** replaces the legacy UI extender. The spawner fetches it on load and writes it into each model's `LuaScript` before spawning (plus `LuaScriptState` `{"f":faction}`), so there's no "extend" step and fixes reach players with the next spawn. Spawner toggle "Model scripts: on/off" for plain models. Features Niklas chose to keep: range rings (number keys, no chat announcement), stabilisation, save/load position (per model), image tokens (tags `TCUITokenSimple`/`TCUITokenEquipment`, icon buttons use index ids). Dropped: snap point, UI counters.
- **Activation token is object UI built in 3D:** the faction icon on top of darker copies stacked below at small z steps (element `position`), forming a real edge from any angle. The root panel is scaled by 1/model scale so 100 UI units = 1 inch on every model, and sits 0.4" above the model's top. The model's height comes from its base width, no measuring (Niklas, Oct 2026): `BASE_HEIGHTS` in model.lua (25 mm 1.5", 32 mm 1.75", 40 mm 2.0", 50 mm 2.5", 60 mm 3.0", bigger 3.6", plus `HEADROOM` 1" so unusually tall models stay clear). Objects whose own collider is at least 0.5" tall (sculpt in the mesh) use that height. Why: attached sculpts have no collider, so `getBounds` only sees the base, and `getVisualBoundsNormalized` was wrong both ways (tested: ~1.4" Lieutenants measured 0.25", asset-bundle sculpts about their scale; a later visual+estimate mix still put 9 of 34 Lieutenants' tokens wrong). Dice sit on a half circle above the token (away from the player as spawned), image tokens on a half circle below it (`arcPoint`: 40° apart, spreading over 180° with a bigger radius when there are many).
- **Dice are real dice, always locked** (researched Oct 2026, after the attempts below): drop any object of type `Dice` onto a model and it stays the real die, gets **locked** (no physics at all: can't drift, fall or be pushed; keeps its hitbox), and sits on the half circle above the activation token. While the model is held, falling or moved by Load position, the dice are placed above it every frame (`setPosition`; confirmed smooth in TTS). Number keys: a linked die without its own script gets a small script (`DIE_SCRIPT` in model.lua, installed with `setLuaScript` + `reload()`; the GUID stays) whose `onNumberTyped` returns true. 1–6 turn the die with `setRotationSmooth` (works on locked dice, verified) to the rotation from `getRotationValues()` (NOT `setValue`/`setRotationValue`, which lift the die and let physics drop it); **0 takes the die off** via the model's `releaseDie` (unlocked, placed beside the model). The die's `memo` holds its model's GUID; with an empty memo the script leaves keys to TTS. Catching the key in the model's `onObjectNumberTyped` and returning true did NOT stop TTS's default (die was unlocked and dropped). Verified via the bridge in the live game: link, 5, 0 all work. Pressing L and dragging it off also unlinks it. Locked dice can't be rolled.
- **Activation:** faction icon (legacy `factions_img` URLs; Mercenaries use the default one), shown once the model has left the spawner's platform. Click toggles ready / activated (greyed). "Ready all" in every model's right-click menu (next to Save/Load position, Clear tokens; start of a round) readies every `TCM_Model` and saves each one's position (`readyAll`); the spawner has no Ready all or Save/Load positions any more.
- Tried and dropped (Oct 2026), physical markers floating over models: (1) real multi-state activation token objects (tagged via intake into `catalog/tokens.json`); attaching floating objects with `addAttachment` while carrying made the held model rise endlessly, and switching state replaces the object. (2) Physical dice with `use_gravity` off: teleporting every 3 frames stuttered/flickered; TTS puts dice down on number keys and `onObjectNumberTyped` never reached the model script. (3) Flat UI icon with offset dark copies for depth: only convincing from one angle. (4) UI dice as cubes of six rotated faces: object UI isn't depth-sorted (back faces drawn over front ones), and Button faces have rounded corners. (5) Flat layered UI tiles with die-face images: rejected by Niklas before testing (wouldn't look like dice). Also ruled out: `jointTo` Fixed joints (jointed objects flop/drift, picking up the die drags the model).
- **Import sets (maintainer):** the board's Import rows; the tag gets `"i": [X]` (see Model tag), written into unit-file entries. "Spawn models" picks per member from the first non-empty of (`importPicks` in spawner.lua): `i` contains C (chosen subfaction), `s` contains C, `i` contains a vanilla key (`_`; for hired mercenaries the warband's faction id, then `_`), vanilla models, any model. Warband import passes no subfaction (see Warband import), so in practice it uses the vanilla keys. Purpose: an imported warband looks consistent; players can still swap anything.
- **Two import modes** (spawner v7): "Spawn models" (catalog models dressed as the members) and "Spawn slots" (one flat locked tile per member, small name label; `SLOT_SCRIPT` holds the member's name/description in its script state and gives them to any model dropped onto it, calling `becomeMember` on models with the model script). Slots also serve to update models a player already has.
- **Swap (drag and drop), revised Oct 2026:** models know their unit (`state.u`) and whether they are a warband member (`state.member`). Dropping a non-member model onto a member swaps it in, but only while the member still stands on its import platform (setting up the warband; nothing swaps during a game). Allowed: a catalog model of the same unit, or a model without a unit (one from the Extend UI area: the player's own models). The dropped model calls `adoptMember` (name, description, activation, tokens, dice, position) with `taken` false, so its token appears (and is measured) once it's taken off the platform; the member is destroyed. Members never swap with each other. The warband platform carries a small note line explaining the swap, and the import status says it too.
- Clearing (unit toggle / Clear all) only deletes models still standing on a spawner platform. Models taken off are the player's: they lose the `TCM_Spawned` tag instead.
- Rejected on purpose: hitbox-free 3D dice (needs disabling Unity colliders: fragile, unclickable), dice next to the base (blocked by piles/terrain), scripted hotkeys (players must bind them every session), scripting-button (numpad) shortcuts (dropping is enough).
- Tested in TTS: an object XML panel with rotation `0 0 180` reads upright from the object's local **+z** side, so the spawner lays rows out toward local -z (behind the panel for the reader). The panel is much larger than a 1×1 object, so the layout starts beyond the panel's edge. A `VerticalScrollView` with a `VerticalLayout` inside rendered empty; the menu uses rows of buttons and grows instead.
- Object XML UI: calling `self.UI.setValue` before the panel exists (e.g. during `onLoad`) throws "Object reference not set to an instance of an object". Both scripts re-render the XML for status changes instead. Self-update is already in (with a guard: the fetched script must contain `SPAWNER_VERSION = <announced version>`, otherwise it would reload forever).
