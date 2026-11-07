"""Talk to a running Tabletop Simulator through its External Editor API (localhost only).

    python tools/tts_bridge.py listen [--log tts.log]
        Receives everything TTS sends to an "external editor" on port 39998 (print output,
        Lua errors, return values of `run`, game saved, ...) and appends it to the log file
        as one JSON object per line. Keep it running in the background. It also
          - serves this repo folder on http://127.0.0.1:8765, so the intake's sorting board
            reads the local catalog (TTS can download from a local http address), and
          - publishes boards: the intake sends a board in parts (sendExternalMessage,
            {"tcm": "publish", ...}); once all parts are in, tools/publish.py writes catalog/
            and the report is shown in the intake (publishDone).

    python tools/tts_bridge.py run "<lua code>" [--guid -1] [--log tts.log] [--wait 5]
        Sends Lua code to TTS (port 39999) to run inside the game, then prints whatever the
        listener logged in the next few seconds (the result, prints, errors). Needs the
        listener running. --guid picks the object whose script runs the code ("-1" = Global);
        that object must already have a script. Use `return ...` to get a value back; tables
        come back as JSON. (TTS doesn't actually send return values back as the docs say, so
        the code is wrapped to print its result as "RESULT: ...".)

    python tools/tts_bridge.py push <script file> --guid <object guid>
        Puts a local script file into an object in the game and reloads the object, e.g. to
        try tts/spawner.lua before pushing it to GitHub. (Code on the command line is limited
        to ~32 KB on Windows; this reads the file instead.) The object keeps its GUID.

Caveat: while the listener runs, TTS treats it as an external editor. Opening the script
editor on an object WITHOUT a script then sends it here instead of opening the in-game
editor, so stop the listener before pasting a script into a fresh object.

Protocol: https://api.tabletopsimulator.com/externaleditorapi/ - one JSON message per TCP
connection, replies arrive on a new connection to port 39998.
"""

import argparse
import functools
import http.server
import json
import threading
import socket
import sys
import time
from datetime import datetime
from pathlib import Path

TTS_PORT = 39999      # TTS listens here
EDITOR_PORT = 39998   # TTS sends to the "editor" here
ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOG = ROOT / "tts.log"
HTTP_PORT = 8765      # the repo folder, for the intake


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve_repo():
    """Serves the repo folder in the background; False if the port is taken (e.g. a test)."""
    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", HTTP_PORT),
                                                 functools.partial(QuietHandler, directory=str(ROOT)))
    except OSError:
        return False
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return True


def send_lua(guid, code):
    """Runs Lua inside an object in the game (no result is awaited)."""
    with socket.create_connection(("127.0.0.1", TTS_PORT), timeout=5) as s:
        s.sendall(json.dumps({"messageID": 3, "guid": guid, "script": code}).encode("utf-8"))


publishes = {}   # publish id -> {"parts": {n: models}, "of": total}


def handle_publish(msg):
    """One part of a board sent by the intake. When all parts are in, publish in a thread
    (writing the catalog takes a few seconds) and send the report back to the intake."""
    pid = msg.get("id")
    entry = publishes.setdefault(pid, {"parts": {}, "of": msg.get("parts", 1)})
    # The models arrive as JSON text: sendExternalMessage drops messages with nested tables.
    try:
        part = json.loads(msg.get("models") or "[]")
    except ValueError as err:
        # Never publish without it: the board's models in this part would be deleted.
        print(f"publish part {msg.get('part')} unreadable: {err}", flush=True)
        entry["bad"] = f"part {msg.get('part')} of {entry['of']} arrived unreadable ({err})"
        part = []
    entry["parts"][msg.get("part", 1)] = part
    if len(entry["parts"]) < entry["of"]:
        return
    publishes.pop(pid, None)
    models = [m for k in sorted(entry["parts"]) for m in entry["parts"][k]]

    def run_publish():
        try:
            if entry.get("bad"):
                raise ValueError(entry["bad"])
            import publish   # tools/publish.py (this folder is on sys.path)
            report = publish.publish(msg["board"], models)
        except Exception as err:   # noqa: BLE001 - any failure goes back to the intake
            report = [f"Publish FAILED: {err!r}. Nothing or only part was written; the board is unchanged, "
                      "press Publish again."]
        print("\n".join(report), flush=True)
        try:
            send_lua(msg["guid"], "publishDone(" + json.dumps(json.dumps(report)) + ")")
        except OSError as err:
            print(f"could not send the report to TTS: {err}", flush=True)

    threading.Thread(target=run_publish, daemon=True).start()


def summarize(msg):
    """The 'game loaded' message carries every script in the save; keep the log readable."""
    if msg.get("messageID") in (0, 1) and "scriptStates" in msg:
        names = [f"{s.get('name')} ({s.get('guid')})" for s in msg["scriptStates"]]
        return {"messageID": msg["messageID"], "scripts": names}
    return msg


def listen(log_path):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", EDITOR_PORT))
    server.listen(5)
    print(f"Listening on 127.0.0.1:{EDITOR_PORT}, logging to {log_path}", flush=True)
    if serve_repo():
        print(f"Serving {ROOT} on http://127.0.0.1:{HTTP_PORT}", flush=True)
    while True:
        conn, _ = server.accept()
        chunks = []
        with conn:
            while True:
                data = conn.recv(65536)
                if not data:
                    break
                chunks.append(data)
        text = b"".join(chunks).decode("utf-8", errors="replace").strip()
        if not text:
            continue
        try:
            msg = json.loads(text)
        except ValueError:
            msg = None
        custom = msg.get("customMessage") if isinstance(msg, dict) else None
        if isinstance(custom, dict) and custom.get("tcm") == "publish":
            # Board parts are big; log a summary only.
            handle_publish(custom)
            entry = {"messageID": 4, "publish": custom.get("board"), "part": custom.get("part"),
                     "of": custom.get("parts"), "bytes": len(custom.get("models") or "")}
        elif msg is not None:
            entry = summarize(msg)
        else:
            entry = {"raw": text}
        entry["time"] = datetime.now().isoformat(timespec="seconds")
        line = json.dumps(entry, ensure_ascii=False)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        print(line, flush=True)


RESULT_PREFIX = "RESULT: "


def run(code, guid, log_path, wait):
    start = log_path.stat().st_size if log_path.exists() else 0
    wrapped = (
        "local __ok, __r = pcall(function()\n" + code + "\nend)\n"
        "if not __ok then print('" + RESULT_PREFIX + "ERROR ' .. tostring(__r))\n"
        "else print('" + RESULT_PREFIX + "' .. (type(__r) == 'table' and JSON.encode(__r) or tostring(__r))) end"
    )
    message = json.dumps({"messageID": 3, "guid": guid, "script": wrapped})
    with socket.create_connection(("127.0.0.1", TTS_PORT), timeout=5) as s:
        s.sendall(message.encode("utf-8"))
    deadline = time.time() + wait
    shown = 0
    while time.time() < deadline:
        time.sleep(0.3)
        if not log_path.exists():
            continue
        with open(log_path, encoding="utf-8") as f:
            f.seek(start)
            new = f.read().splitlines()
        for line in new[shown:]:
            print(line)
        shown = len(new)
        if any(RESULT_PREFIX in l or '"messageID": 3' in l for l in new):
            break   # got the result or a Lua error
    if shown == 0:
        print("(nothing logged - is `listen` running and TTS open?)")


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_listen = sub.add_parser("listen")
    p_listen.add_argument("--log", type=Path, default=DEFAULT_LOG)
    p_run = sub.add_parser("run")
    p_run.add_argument("code")
    p_run.add_argument("--guid", default="-1")
    p_run.add_argument("--log", type=Path, default=DEFAULT_LOG)
    p_run.add_argument("--wait", type=float, default=5)
    p_push = sub.add_parser("push")
    p_push.add_argument("file", type=Path)
    p_push.add_argument("--guid", required=True)
    p_push.add_argument("--log", type=Path, default=DEFAULT_LOG)
    p_push.add_argument("--wait", type=float, default=5)
    args = parser.parse_args()
    if args.cmd == "listen":
        listen(args.log)
    elif args.cmd == "push":
        script = args.file.read_text(encoding="utf-8")
        # Long brackets need a level that doesn't occur in the script.
        level = 1
        while ("]" + "=" * level + "]") in script:
            level += 1
        eq = "=" * level
        code = ('local o = getObjectFromGUID("%s") if not o then return "no object %s" end '
                'o.setLuaScript([%s[%s]%s]) o.reload() return "reloaded %s"'
                % (args.guid, args.guid, eq, script, eq, args.guid))
        run(code, "-1", args.log, args.wait)
    else:
        run(args.code, args.guid, args.log, args.wait)


if __name__ == "__main__":
    main()
