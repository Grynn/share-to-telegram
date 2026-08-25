# /// script
# requires-python = ">=3.11"
# dependencies = ["telethon>=1.36"]
# ///
"""Deliver items shared from the macOS share sheet.

Destinations:
  telegram  send as the user's own Telegram account (Telethon/MTProto)
  ytq       queue video URLs with the `ytq` CLI

Subcommands:
  login   One-time interactive login + target-chat selection.
  send    Direct send from the CLI: send [--dest ...] [--text ...] [files]
  relay   Drain the share-extension job queue (run by the LaunchAgent).
  status  Exit 0 with "ok" if config + authorized session exist.
"""

import argparse
import asyncio
import fcntl
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from telethon import TelegramClient

APP_ID = "app.sendtomybot"

CONFIG_DIR = Path.home() / ".config" / "send-to-my-bot"
CONFIG_PATH = CONFIG_DIR / "config.json"
SESSION_PATH = CONFIG_DIR / "telegram"  # telethon appends .session

# Sandbox container of the share extension (its NSHomeDirectory()).
CONTAINER_DATA = Path.home() / "Library" / "Containers" / f"{APP_ID}.share" / "Data"
QUEUE_DIR = CONTAINER_DATA / "queue"
FAILED_DIR = CONTAINER_DATA / "failed"

URL_RE = re.compile(r"https?://\S+")


# --------------------------------------------------------------------------- config

def load_config() -> dict:
    if not CONFIG_PATH.exists():
        sys.exit(f"no config at {CONFIG_PATH} — run: bot_send.py login")
    cfg = json.loads(CONFIG_PATH.read_text())
    for key in ("api_id", "api_hash", "chat_id"):
        if key not in cfg:
            sys.exit(f"config missing '{key}' — re-run: bot_send.py login")
    return cfg


def save_config(cfg: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2) + "\n")
    CONFIG_PATH.chmod(0o600)


def notify(message: str, title: str = "Send to My Bot") -> None:
    safe = message.replace('\\', ' ').replace('"', "'")[:200]
    subprocess.run(
        ["osascript", "-e", f'display notification "{safe}" with title "{title}"'],
        check=False, capture_output=True,
    )


# --------------------------------------------------------------------------- login

async def cmd_login() -> None:
    cfg = json.loads(CONFIG_PATH.read_text()) if CONFIG_PATH.exists() else {}
    print("Telegram user-account login")
    print("api_id / api_hash come from https://my.telegram.org/apps\n")
    api_id = cfg.get("api_id") or int(input("api_id: ").strip())
    api_hash = cfg.get("api_hash") or input("api_hash: ").strip()
    cfg.update(api_id=api_id, api_hash=api_hash)
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
    chosen = matches[int(input("\nSend shares to which chat? [number]: ").strip())]
    cfg["chat_id"] = chosen.id
    cfg["chat_name"] = chosen.name
    save_config(cfg)

    await client.send_message(chosen.id, "Send to My Bot connected ✅ (setup test)")
    print(f"\nSaved. Shares go to '{chosen.name}' as you. Test message sent.")
    await client.disconnect()


# --------------------------------------------------------------------------- telegram

async def connected_client(cfg: dict) -> TelegramClient:
    client = TelegramClient(str(SESSION_PATH), cfg["api_id"], cfg["api_hash"])
    await client.connect()
    if not await client.is_user_authorized():
        sys.exit("session not authorized — run: bot_send.py login")
    return client


async def cmd_status() -> None:
    cfg = load_config()
    client = await connected_client(cfg)
    me = await client.get_me()
    print(f"ok: @{me.username or me.id} -> {cfg.get('chat_name', cfg['chat_id'])}")
    await client.disconnect()


async def send_telegram(text: str | None, files: list[str]) -> None:
    if not text and not files:
        sys.exit("nothing to send")
    cfg = load_config()
    client = await connected_client(cfg)
    chat = cfg["chat_id"]

    missing = [f for f in files if not Path(f).is_file()]
    if missing:
        sys.exit(f"missing files: {missing}")

    if files:
        # Images go as photos (with any text as caption); other files as documents.
        images = [f for f in files if (mimetypes.guess_type(f)[0] or "").startswith("image/")]
        others = [f for f in files if f not in images]
        caption = text or ""
        if images:
            await client.send_file(chat, images, caption=caption)
            caption = ""
        for f in others:
            await client.send_file(chat, f, caption=caption, force_document=True)
            caption = ""
    else:
        await client.send_message(chat, text, link_preview=True)

    await client.disconnect()


# --------------------------------------------------------------------------- ytq

def find_ytq(cfg: dict) -> str:
    configured = cfg.get("ytq_cmd")
    candidates = [configured] if configured else []
    candidates += [
        str(Path.home() / ".local" / "bin" / "ytq"),
        "/opt/homebrew/bin/ytq",
        "/usr/local/bin/ytq",
    ]
    for c in candidates:
        if c and os.access(c, os.X_OK):
            return c
    found = shutil.which("ytq")
    if found:
        return found
    sys.exit("ytq CLI not found — install it or set 'ytq_cmd' in config.json")


def send_ytq(text: str) -> str:
    urls = URL_RE.findall(text or "")
    if not urls:
        sys.exit("no URL found to queue in ytq")
    cfg = json.loads(CONFIG_PATH.read_text()) if CONFIG_PATH.exists() else {}
    ytq = find_ytq(cfg)
    env = dict(os.environ)
    env["PATH"] = f"{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "/usr/bin:/bin")
    proc = subprocess.run(
        [ytq, "add", *urls, "--by", "share sheet"],
        capture_output=True, text=True, env=env, timeout=120,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        sys.exit(f"ytq add failed: {detail[-1] if detail else proc.returncode}")
    return f"{len(urls)} URL{'s' if len(urls) > 1 else ''} queued in ytq"


# --------------------------------------------------------------------------- relay

async def deliver(job: dict) -> str:
    """Run one job. Returns a short success description."""
    dest = job.get("dest", "telegram")
    message = (job.get("message") or "").strip()
    text = (job.get("text") or "").strip()
    files = job.get("files") or []

    if dest == "ytq":
        return send_ytq(text)

    body = "\n".join(p for p in (message, text) if p)
    await send_telegram(body or None, files)
    cfg = json.loads(CONFIG_PATH.read_text())
    where = cfg.get("chat_name") or cfg.get("chat_id")
    what = f"{len(files)} file{'s' if len(files) > 1 else ''}" if files else "message"
    return f"{what} sent to {where}"


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
    processed = True
    while processed:  # keep draining until a full scan finds nothing ready
        processed = False
        for job_dir in sorted(p for p in QUEUE_DIR.iterdir() if p.is_dir()):
            job_file = job_dir / "job.json"
            if not job_file.is_file():
                continue  # extension still writing this job
            processed = True
            try:
                note = await deliver(json.loads(job_file.read_text()))
                shutil.rmtree(job_dir)
                print(f"relay: {job_dir.name}: {note}")
                if not quiet:
                    notify(note)
            except SystemExit as e:  # fail-fast paths above
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
    notify(message, title="Send to My Bot — failed")


# --------------------------------------------------------------------------- cli

def main() -> None:
    parser = argparse.ArgumentParser(prog="bot_send")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("login")
    sub.add_parser("status")
    p_relay = sub.add_parser("relay")
    p_relay.add_argument("--quiet", action="store_true", help="no success notifications")
    p_send = sub.add_parser("send")
    p_send.add_argument("--text", default=None)
    p_send.add_argument("--message", default=None, help="note prepended to the text")
    p_send.add_argument("--dest", default="telegram", choices=["telegram", "ytq"])
    p_send.add_argument("files", nargs="*")
    args = parser.parse_args()

    if args.cmd == "login":
        asyncio.run(cmd_login())
    elif args.cmd == "status":
        asyncio.run(cmd_status())
    elif args.cmd == "relay":
        asyncio.run(cmd_relay(quiet=args.quiet))
    else:
        job = {"dest": args.dest, "message": args.message, "text": args.text, "files": args.files}
        print(asyncio.run(deliver(job)))


if __name__ == "__main__":
    main()
