# /// script
# requires-python = ">=3.11"
# dependencies = ["telethon>=1.36"]
# ///
"""Deliver items shared from the macOS share sheet to pluggable destinations.

Destination types (declared in ~/.config/share-to-claw/config.json):
  webhook   HTTP POST with a JSON body template (e.g. an OpenClaw /hooks/wake)
  telegram  posted as your own Telegram account (Telethon/MTProto, not a bot)
  command   any CLI, with the shared items templated into its arguments

Subcommands:
  setup   Interactive wizard: asks only for what's missing, writes the config.
  login   One-time Telegram login + chat selection.
  dests   List configured destinations.
  sync    Publish destination metadata to the share extension.
  send    Deliver from the CLI: send --dest <id> [--message m] [--text t] [files]
  relay   Drain the share-extension job queue (run by the LaunchAgent).
  status  Check every destination's readiness.
"""

import argparse
import asyncio
import fcntl
import getpass
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

APP_ID = "app.sharetoclaw"
APP_NAME = "ShareToClaw"

CONFIG_DIR = Path.home() / ".config" / "share-to-claw"
CONFIG_PATH = CONFIG_DIR / "config.json"
SESSION_PATH = CONFIG_DIR / "telegram"  # telethon appends .session

# Sandbox container of the share extension (its NSHomeDirectory()).
CONTAINER_DATA = Path.home() / "Library" / "Containers" / f"{APP_ID}.share" / "Data"
QUEUE_DIR = CONTAINER_DATA / "queue"
FAILED_DIR = CONTAINER_DATA / "failed"
DESTS_FILE = CONTAINER_DATA / "destinations.json"

URL_RE = re.compile(r"https?://\S+")
USER_AGENT = "share-to-claw/0.2 (+https://github.com/Grynn/share-to-claw)"
ALL_KINDS = ("text", "url", "file", "image")


# --------------------------------------------------------------------------- config

def load_config() -> dict:
    if not CONFIG_PATH.exists():
        sys.exit(f"no config at {CONFIG_PATH} — run: share-to-claw login")
    return migrate(json.loads(CONFIG_PATH.read_text()))


def save_config(cfg: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2) + "\n")
    CONFIG_PATH.chmod(0o600)


def migrate(cfg: dict) -> dict:
    """Accept the flat pre-destinations config layout."""
    if "telegram" not in cfg and "api_id" in cfg:
        cfg["telegram"] = {k: cfg.pop(k) for k in
                           ("api_id", "api_hash", "chat_id", "chat_name") if k in cfg}
    cfg.setdefault("telegram", {})
    if not cfg.get("destinations"):
        cfg["destinations"] = [{
            "id": "telegram", "label": "Telegram", "type": "telegram", "default": True,
            "accepts": list(ALL_KINDS),
        }]
    return cfg


def destinations(cfg: dict) -> list[dict]:
    return [d for d in cfg.get("destinations", []) if d.get("enabled", True)]


def find_dest(cfg: dict, dest_id: str | None) -> dict:
    dests = destinations(cfg)
    if not dests:
        sys.exit("no destinations configured — see config.example.json")
    if dest_id:
        for d in dests:
            if d["id"] == dest_id:
                return d
        sys.exit(f"unknown destination '{dest_id}' (have: {', '.join(d['id'] for d in dests)})")
    for d in dests:
        if d.get("default"):
            return d
    return dests[0]


def notify(message: str, title: str = "Share to Claw") -> None:
    safe = message.replace("\\", " ").replace('"', "'")[:200]
    subprocess.run(["osascript", "-e",
                    f'display notification "{safe}" with title "{title}"'],
                   check=False, capture_output=True)


# --------------------------------------------------------------------------- templating

def kinds_of(text: str, files: list[str]) -> set[str]:
    kinds: set[str] = set()
    if text.strip():
        kinds.add("url" if URL_RE.search(text) else "text")
        if URL_RE.search(text) and URL_RE.sub("", text).strip():
            kinds.add("text")
    for f in files:
        mime = mimetypes.guess_type(f)[0] or ""
        kinds.add("image" if mime.startswith("image/") else "file")
    return kinds


def render(value, ctx: dict):
    """Substitute {message} {text} {all} in strings, recursing into JSON structures."""
    if isinstance(value, str):
        out = value
        for key in ("all", "message", "text"):
            out = out.replace("{" + key + "}", ctx[key])
        return out
    if isinstance(value, dict):
        return {k: render(v, ctx) for k, v in value.items()}
    if isinstance(value, list):
        return [render(v, ctx) for v in value]
    return value


def render_args(args: list[str], ctx: dict, urls: list[str], files: list[str]) -> list[str]:
    """Like render(), plus {urls}/{files} which expand into multiple arguments."""
    out: list[str] = []
    for arg in args:
        if arg == "{urls}":
            out.extend(urls)
        elif arg == "{files}":
            out.extend(files)
        else:
            out.append(render(arg, ctx))
    return out


# --------------------------------------------------------------------------- telegram

async def telegram_client(cfg: dict):
    from telethon import TelegramClient
    tg = cfg.get("telegram") or {}
    for key in ("api_id", "api_hash"):
        if key not in tg:
            sys.exit(f"telegram.{key} missing — run: share-to-claw login")
    client = TelegramClient(str(SESSION_PATH), tg["api_id"], tg["api_hash"])
    await client.connect()
    if not await client.is_user_authorized():
        sys.exit("Telegram session not authorized — run: share-to-claw login")
    return client


async def send_telegram(cfg: dict, dest: dict, body: str, files: list[str]) -> str:
    tg = cfg.get("telegram") or {}
    chat = dest.get("chat_id", tg.get("chat_id"))
    if chat is None:
        sys.exit("no telegram chat configured — run: share-to-claw login")
    client = await telegram_client(cfg)
    try:
        missing = [f for f in files if not Path(f).is_file()]
        if missing:
            sys.exit(f"missing files: {missing}")
        if files:
            images = [f for f in files
                      if (mimetypes.guess_type(f)[0] or "").startswith("image/")]
            others = [f for f in files if f not in images]
            caption = body
            if images:
                try:
                    await client.send_file(chat, images, caption=caption)
                except Exception:
                    # e.g. ImageProcessFailedError on an image Telegram won't
                    # transcode — it still deserves to arrive, as a document.
                    await client.send_file(chat, images, caption=caption,
                                           force_document=True)
                caption = ""
            for f in others:
                await client.send_file(chat, f, caption=caption, force_document=True)
                caption = ""
            what = f"{len(files)} file{'s' if len(files) > 1 else ''}"
        else:
            if not body:
                sys.exit("nothing to send")
            await client.send_message(chat, body, link_preview=True)
            what = "message"
    finally:
        await client.disconnect()
    return f"{what} sent to {dest.get('label', dest['id'])}"


async def cmd_login() -> None:
    from telethon import TelegramClient
    cfg = migrate(json.loads(CONFIG_PATH.read_text())) if CONFIG_PATH.exists() else migrate({})
    tg = cfg["telegram"]
    print("Telegram user-account login")
    print("api_id / api_hash come from https://my.telegram.org/apps\n")
    tg.setdefault("api_id", None) or None
    api_id = tg.get("api_id") or int(input("api_id: ").strip())
    api_hash = tg.get("api_hash") or input("api_hash: ").strip()
    tg.update(api_id=api_id, api_hash=api_hash)
    save_config(cfg)

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    client = TelegramClient(str(SESSION_PATH), api_id, api_hash)
    await client.start()  # interactive: phone, code, 2FA password if set
    me = await client.get_me()
    print(f"\nLogged in as {me.first_name} (@{me.username or me.id})\n")

    query = input("Search chats by name (blank = 25 most recent): ").strip().lower()
    matches = []
    if query:
        async for dialog in client.iter_dialogs():
            if query in (dialog.name or "").lower():
                matches.append(dialog)
    if not matches:
        if query:
            print(f"No dialog matching '{query}'; showing your 25 most recent chats:")
        async for dialog in client.iter_dialogs(limit=25):
            matches.append(dialog)
    for i, d in enumerate(matches):
        print(f"  [{i}] {d.name}  (id={d.id})")
    chosen = matches[int(input("\nTelegram shares go to which chat? [number]: ").strip())]
    tg["chat_id"] = chosen.id
    tg["chat_name"] = chosen.name
    save_config(cfg)
    await client.send_message(chosen.id, "Share to Claw connected ✅ (setup test)")
    print(f"\nSaved. Telegram destination → '{chosen.name}'. Test message sent.")
    await client.disconnect()
    sync_destinations(cfg)


# --------------------------------------------------------------------------- setup wizard

def ask(label: str, current=None, secret: bool = False, default: str | None = None):
    """Prompt once. Blank keeps what is already stored (or the offered default)."""
    if current not in (None, ""):
        hint = " [stored — ⏎ keeps it]" if secret else f" [{current}]"
    elif default:
        hint = f" [{default}]"
    else:
        hint = ""
    raw = (getpass.getpass if secret else input)(f"  {label}{hint}: ").strip()
    if raw:
        return raw
    return current if current not in (None, "") else default


def yes(question: str, default: bool = True) -> bool:
    suffix = "[Y/n]" if default else "[y/N]"
    raw = input(f"  {question} {suffix}: ").strip().lower()
    return default if not raw else raw.startswith("y")


def upsert(cfg: dict, dest: dict) -> None:
    for i, existing in enumerate(cfg["destinations"]):
        if existing["id"] == dest["id"]:
            cfg["destinations"][i] = {**existing, **dest}
            return
    cfg["destinations"].append(dest)


def which_cli(name: str) -> str | None:
    found = shutil.which(name)
    if found:
        return found
    for base in (Path.home() / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")):
        if os.access(base / name, os.X_OK):
            return str(base / name)
    return None


def get_dest(cfg: dict, dest_id: str) -> dict:
    return next((d for d in cfg.get("destinations", []) if d["id"] == dest_id), {})


def cmd_setup() -> None:
    """Idempotent: everything already stored is offered back as the default."""
    cfg = migrate(json.loads(CONFIG_PATH.read_text())) if CONFIG_PATH.exists() else migrate({})
    cfg.setdefault("destinations", [])
    print("\nShare to Claw setup — ⏎ keeps whatever is already stored.\n")

    # 1. webhook destination (an OpenClaw /hooks/wake, or anything that takes JSON)
    print("1) Webhook destination (e.g. OpenClaw /hooks/wake)")
    claw = get_dest(cfg, "claw")
    if yes("configure a webhook destination?", default=not claw or bool(claw.get("url"))):
        url = ask("URL", claw.get("url"))
        if url:
            token = ask("Bearer token", claw.get("token"), secret=True)
            upsert(cfg, {
                "id": "claw", "label": ask("label shown in the panel", claw.get("label"), default="claw"),
                "type": "webhook", "url": url,
                **({"token": token} if token else {}),
                "body": claw.get("body", {"text": "{all}", "mode": "now"}),
                "accepts": ["text", "url"],
                "files_via": "telegram",
            })
            print("   ✓ webhook saved")
    print()

    # 2. telegram
    print("2) Telegram (posted as you, not a bot)")
    tg = cfg["telegram"]
    session_ok = Path(str(SESSION_PATH) + ".session").exists()
    if session_ok and tg.get("chat_id"):
        print(f"   ✓ already logged in → {tg.get('chat_name', tg['chat_id'])}")
        if yes("re-run the Telegram login?", default=False):
            asyncio.run(cmd_login())
            cfg = migrate(json.loads(CONFIG_PATH.read_text()))
    elif yes("set up Telegram now? (needs a login code)", default=True):
        tg["api_id"] = int(ask("api_id (my.telegram.org/apps)", tg.get("api_id")) or 0)
        tg["api_hash"] = ask("api_hash", tg.get("api_hash"), secret=True)
        save_config(cfg)
        asyncio.run(cmd_login())
        cfg = migrate(json.loads(CONFIG_PATH.read_text()))
    upsert(cfg, {"id": "telegram", "label": "Telegram", "type": "telegram",
                 "accepts": list(ALL_KINDS)})
    print()

    # 3+. optional CLI destinations
    for dest_id, label, exe, hosts, template in (
        ("ytq", "ytq", "ytq",
         ["youtube.com", "m.youtube.com", "youtu.be", "x.com", "twitter.com", "mobile.twitter.com"],
         ["ytq", "add", "{urls}", "--by", "share sheet"]),
        ("whatsapp", "WhatsApp", "wacli", [], ["wacli", "send", "--to", "{recipient}", "--text", "{all}"]),
    ):
        print(f"{3 if dest_id == 'ytq' else 4}) {label} (via `{exe}`)")
        existing = get_dest(cfg, dest_id)
        found = which_cli(exe)
        if not found and not existing:
            print(f"   — {exe} not installed; skipping (re-run setup after installing it)")
            print()
            continue
        if not yes(f"enable the {label} destination?", default=bool(found)):
            if existing:
                upsert(cfg, {"id": dest_id, "enabled": False})
            print()
            continue
        command = existing.get("command", template)
        if dest_id == "whatsapp":
            current = next((a for a in command if a not in template or a == "{recipient}"), None)
            recipient = ask("recipient (phone/JID wacli expects)",
                            None if current == "{recipient}" else current)
            command = [a if a != "{recipient}" else (recipient or "{recipient}")
                       for a in (existing.get("command") or template)]
        existing.pop("enabled", None)
        upsert(cfg, {"id": dest_id, "label": label, "type": "command",
                     "command": command,
                     "accepts": ["url"] if dest_id == "ytq" else ["text", "url"],
                     **({"auto_for_hosts": hosts} if hosts else {})})
        print(f"   ✓ {label} enabled")
        print()

    # default destination
    dests = destinations(cfg)
    if dests:
        print("Default destination (used when nothing auto-matches):")
        for i, d in enumerate(dests):
            print(f"   [{i}] {d['id']}")
        current_default = next((i for i, d in enumerate(dests) if d.get("default")), 0)
        raw = input(f"  pick a number [{current_default}]: ").strip()
        chosen = int(raw) if raw.isdigit() and int(raw) < len(dests) else current_default
        for i, d in enumerate(dests):
            if i == chosen:
                d["default"] = True
            else:
                d.pop("default", None)

    save_config(cfg)
    where = sync_destinations(cfg)
    print(f"\nWrote {CONFIG_PATH} (0600)")
    print("Synced destinations to the share extension." if where else
          "Share once so the extension container exists, then: share-to-claw sync")
    print("Check anytime with: share-to-claw status\n")


# --------------------------------------------------------------------------- webhook

def resolve_secret(value) -> str:
    """A destination token may be inline, or {"env": "VAR"} / {"file": "path"}."""
    if isinstance(value, dict):
        if "env" in value:
            got = os.environ.get(value["env"])
            if not got:
                sys.exit(f"env var {value['env']} is not set")
            return got
        if "file" in value:
            return Path(value["file"]).expanduser().read_text().strip()
    return str(value)


def send_webhook(dest: dict, ctx: dict) -> str:
    url = dest.get("url")
    if not url:
        sys.exit(f"destination '{dest['id']}' has no url")
    body = render(dest.get("body", {"text": "{all}"}), ctx)
    data = json.dumps(body).encode()
    # Send a real User-Agent: bot rules (Cloudflare's 1010, say) reject the
    # default "Python-urllib/3.x" signature outright.
    headers = {"Content-Type": "application/json", "User-Agent": USER_AGENT}
    headers.update({k: resolve_secret(v) for k, v in (dest.get("headers") or {}).items()})
    if dest.get("token"):
        headers["Authorization"] = "Bearer " + resolve_secret(dest["token"])

    req = urllib.request.Request(url, data=data, headers=headers,
                                 method=dest.get("method", "POST"))
    try:
        with urllib.request.urlopen(req, timeout=dest.get("timeout", 30)) as resp:
            resp.read(2048)
            code = resp.status
    except urllib.error.HTTPError as e:
        detail = e.read(300).decode(errors="replace").strip()
        sys.exit(f"{dest['id']}: HTTP {e.code} {detail}")
    except urllib.error.URLError as e:
        sys.exit(f"{dest['id']}: {e.reason}")
    return f"sent to {dest.get('label', dest['id'])} (HTTP {code})"


# --------------------------------------------------------------------------- command

def send_command(dest: dict, ctx: dict, urls: list[str], files: list[str]) -> str:
    argv = dest.get("command")
    if not argv:
        sys.exit(f"destination '{dest['id']}' has no command")
    argv = render_args(list(argv), ctx, urls, files)
    exe = shutil.which(argv[0]) or argv[0]
    if not os.access(exe, os.X_OK):
        for base in (Path.home() / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")):
            if os.access(base / argv[0], os.X_OK):
                exe = str(base / argv[0])
                break
        else:
            sys.exit(f"{argv[0]} not found — install it or fix the command in config.json")
    env = dict(os.environ)
    env["PATH"] = (f"{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
                   + env.get("PATH", "/usr/bin:/bin"))
    proc = subprocess.run([exe, *argv[1:]], capture_output=True, text=True,
                          env=env, timeout=dest.get("timeout", 120))
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        sys.exit(f"{dest['id']}: {detail[-1] if detail else 'exit ' + str(proc.returncode)}")
    return f"sent to {dest.get('label', dest['id'])}"


# --------------------------------------------------------------------------- delivery

async def deliver(cfg: dict, dest: dict, message: str, text: str, files: list[str]) -> str:
    message, text = message.strip(), text.strip()
    ctx = {"message": message, "text": text,
           "all": "\n".join(p for p in (message, text) if p)}
    urls = URL_RE.findall(text)
    accepts = dest.get("accepts", list(ALL_KINDS))
    notes = []

    # Items this destination can't take (files on a text-only webhook, say) go to
    # the destination named by files_via, if it declares one.
    file_kinds = {k for k in kinds_of(text, files) if k in ("file", "image")}
    if files and not file_kinds <= set(accepts):
        via = dest.get("files_via")
        if not via:
            sys.exit(f"{dest['id']} does not accept files")
        alt = find_dest(cfg, via)
        # The note rides along as the caption so the file is self-contained there.
        notes.append(await deliver(cfg, alt, message, "", files))
        files = []
        if not ctx["all"]:
            return "; ".join(notes)

    if "url" not in accepts and urls and not ctx["all"].replace("".join(urls), "").strip():
        pass  # a URL is still text for most destinations

    if dest["type"] == "telegram":
        main = await send_telegram(cfg, dest, ctx["all"], files)
    elif dest["type"] == "webhook":
        main = send_webhook(dest, ctx)
    elif dest["type"] == "command":
        if "url" in accepts and not urls and not files:
            sys.exit(f"{dest['id']} needs a URL")
        main = send_command(dest, ctx, urls, files)
    else:
        sys.exit(f"unknown destination type '{dest['type']}'")
    return "; ".join([main, *notes])


# --------------------------------------------------------------------------- sync / status

def sync_destinations(cfg: dict) -> Path | None:
    """Publish the UI-facing metadata (never secrets) into the extension container."""
    if not CONTAINER_DATA.is_dir():
        return None
    payload = {"destinations": [{
        "id": d["id"],
        "label": d.get("label", d["id"]),
        "accepts": d.get("accepts", list(ALL_KINDS)),
        "auto_for_hosts": d.get("auto_for_hosts", []),
        "handles_files": bool(d.get("files_via")) or
                         bool({"file", "image"} & set(d.get("accepts", ALL_KINDS))),
        "default": bool(d.get("default")),
    } for d in destinations(cfg)]}
    DESTS_FILE.write_text(json.dumps(payload, indent=2) + "\n")
    return DESTS_FILE


async def cmd_status(cfg: dict) -> None:
    for d in destinations(cfg):
        label = f"{d['id']:10s} {d['type']:8s}"
        if d["type"] == "telegram":
            try:
                client = await telegram_client(cfg)
                me = await client.get_me()
                await client.disconnect()
                chat = d.get("chat_id", (cfg.get("telegram") or {}).get("chat_name"))
                print(f"ok   {label} @{me.username or me.id} -> {chat}")
            except SystemExit as e:
                print(f"FAIL {label} {e}")
        elif d["type"] == "webhook":
            host = urlparse(d.get("url", "")).netloc or "?"
            print(f"ok   {label} {host}"
                  + ("" if d.get("token") or d.get("headers") else "  (no auth configured)"))
        elif d["type"] == "command":
            exe = (d.get("command") or ["?"])[0]
            found = shutil.which(exe) or next(
                (str(b / exe) for b in (Path.home() / ".local/bin", Path("/opt/homebrew/bin"),
                                        Path("/usr/local/bin")) if os.access(b / exe, os.X_OK)), None)
            print(f"{'ok  ' if found else 'FAIL'} {label} {found or exe + ' not found'}")
    where = sync_destinations(cfg)
    print(f"\n{len(destinations(cfg))} destination(s); extension metadata: "
          + (str(where) if where else "container not created yet (share once)"))


# --------------------------------------------------------------------------- relay

async def cmd_relay(quiet: bool = False) -> None:
    """Process queued share-extension jobs. Single instance via flock."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    lock_file = open(CONFIG_DIR / "relay.lock", "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return  # another relay run is already draining the queue

    if not QUEUE_DIR.is_dir():
        return
    sweep_staging()
    cfg = load_config()
    sync_destinations(cfg)  # keep the extension's picker in step with config.json

    processed = True
    while processed:
        processed = False
        for job_dir in sorted(p for p in QUEUE_DIR.iterdir() if p.is_dir()):
            job_file = job_dir / "job.json"
            if not job_file.is_file():
                continue  # extension still writing this job
            processed = True
            try:
                job = json.loads(job_file.read_text())
                dest = find_dest(cfg, job.get("dest"))
                note = await deliver(cfg, dest, job.get("message") or "",
                                     job.get("text") or "", job.get("files") or [])
                shutil.rmtree(job_dir)
                print(f"relay: {job_dir.name}: {note}")
                if not quiet:
                    notify(note)
            except SystemExit as e:
                fail(job_dir, str(e))
            except Exception as e:
                fail(job_dir, f"{type(e).__name__}: {e}")


def sweep_staging(max_age_s: int = 3600) -> None:
    """Drop staging dirs left behind by a share panel that died before sending."""
    staging = QUEUE_DIR / ".staging"
    if not staging.is_dir():
        return
    now = time.time()
    for d in staging.iterdir():
        try:
            if now - d.stat().st_mtime > max_age_s:
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass


def fail(job_dir: Path, message: str) -> None:
    print(f"relay: {job_dir.name} failed: {message}", file=sys.stderr)
    FAILED_DIR.mkdir(parents=True, exist_ok=True)
    dest = FAILED_DIR / job_dir.name
    shutil.rmtree(dest, ignore_errors=True)
    shutil.move(str(job_dir), str(dest))
    (dest / "error.txt").write_text(message + "\n")
    notify(message, title="Share to Claw — failed")


# --------------------------------------------------------------------------- cli

def main() -> None:
    parser = argparse.ArgumentParser(prog="share-to-claw")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("setup")
    sub.add_parser("login")
    sub.add_parser("status")
    sub.add_parser("dests")
    sub.add_parser("sync")
    p_relay = sub.add_parser("relay")
    p_relay.add_argument("--quiet", action="store_true", help="no success notifications")
    p_send = sub.add_parser("send")
    p_send.add_argument("--dest", default=None, help="destination id (default: the marked one)")
    p_send.add_argument("--message", default="", help="note that rides along")
    p_send.add_argument("--text", default="", help="shared text / URLs")
    p_send.add_argument("files", nargs="*")
    args = parser.parse_args()

    if args.cmd == "setup":
        cmd_setup()
        return
    if args.cmd == "login":
        asyncio.run(cmd_login())
        return
    cfg = load_config()
    if args.cmd == "status":
        asyncio.run(cmd_status(cfg))
    elif args.cmd == "dests":
        for d in destinations(cfg):
            mark = "*" if d.get("default") else " "
            print(f"{mark} {d['id']:10s} {d['type']:8s} {d.get('label', '')}"
                  f"   accepts={','.join(d.get('accepts', ALL_KINDS))}")
    elif args.cmd == "sync":
        where = sync_destinations(cfg)
        print(f"wrote {where}" if where else "extension container not created yet — share once")
    elif args.cmd == "relay":
        asyncio.run(cmd_relay(quiet=args.quiet))
    else:
        dest = find_dest(cfg, args.dest)
        print(asyncio.run(deliver(cfg, dest, args.message, args.text, args.files)))


if __name__ == "__main__":
    main()
