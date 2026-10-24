"""Talk to a running Tabletop Simulator through its External Editor API (localhost only).

    python tools/tts_bridge.py listen [--log tts.log]
        Receives everything TTS sends to an "external editor" on port 39998 (print output,
        Lua errors, return values of `run`, game saved, ...) and appends it to the log file
        as one JSON object per line. Keep it running in the background.

    python tools/tts_bridge.py run "<lua code>" [--guid -1] [--log tts.log] [--wait 5]
        Sends Lua code to TTS (port 39999) to run inside the game, then prints whatever the
        listener logged in the next few seconds (the result, prints, errors). Needs the
        listener running. --guid picks the object whose script runs the code ("-1" = Global);
        that object must already have a script. Use `return ...` to get a value back; tables
        come back as JSON. (TTS doesn't actually send return values back as the docs say, so
        the code is wrapped to print its result as "RESULT: ...".)

Caveat: while the listener runs, TTS treats it as an external editor. Opening the script
editor on an object WITHOUT a script then sends it here instead of opening the in-game
editor, so stop the listener before pasting a script into a fresh object.

Protocol: https://api.tabletopsimulator.com/externaleditorapi/ - one JSON message per TCP
connection, replies arrive on a new connection to port 39998.
"""

import argparse
import json
import socket
import sys
import time
from datetime import datetime
from pathlib import Path

TTS_PORT = 39999      # TTS listens here
EDITOR_PORT = 39998   # TTS sends to the "editor" here
DEFAULT_LOG = Path(__file__).resolve().parent.parent / "tts.log"


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
            entry = summarize(json.loads(text))
        except ValueError:
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
    args = parser.parse_args()
    if args.cmd == "listen":
        listen(args.log)
    else:
        run(args.code, args.guid, args.log, args.wait)


if __name__ == "__main__":
    main()
