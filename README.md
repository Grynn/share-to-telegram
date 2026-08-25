# Send to My Bot

A macOS share-sheet extension that sends whatever you're looking at — a URL,
selected text, an image, a PDF — to **your own Telegram chat, posted as you**
(a real user account over MTProto, not a bot token), or into the
[`ytq`](https://pypi.org/project/yt-queue/) video queue.

```
⌘ any app  →  Share  →  Send to My Bot
        ┌──────────────────────────────────────────┐
        │ youtube.com/watch?v=…                    │
        │ ┌──────────────────────────────────────┐ │
        │ │ Message (optional)                   │ │
        │ └──────────────────────────────────────┘ │
        │ [ Telegram | ytq ]        Cancel   Send  │
        │ ⏎ send · ⎋ cancel                        │
        └──────────────────────────────────────────┘
```

The message field is focused the moment the panel opens, so the whole
interaction is: share → type a note (or not) → ⏎. The panel closes instantly;
delivery happens out of process.

- **⏎** send · **⎋** cancel · **⌘1** Telegram · **⌘2** ytq
- A YouTube / X video link auto-selects **ytq**; anything else goes to Telegram.
- A note typed in the message field is prepended to the Telegram message
  (ytq ignores it — the placeholder says so when ytq is selected).

## How it works

macOS only loads a share extension if it is **sandboxed**, and a sandboxed
extension can neither reach the network nor exec a CLI. So the extension does
the smallest possible job — write the share to a queue inside its own container
— and an unsandboxed LaunchAgent does the delivery:

```
Share sheet
  └─ SendToMyBotExt.appex        sandboxed; writes a job, dismisses instantly
       ~/Library/Containers/app.sendtomybot.share/Data/queue/<uuid>/job.json
  └─ LaunchAgent app.sendtomybot.relay
       WatchPaths on the queue (fires in ~1s) + 5-minute timer as a backstop
       runs: uv run bot_send.py relay
  └─ bot_send.py
       dest=telegram → Telethon, as your account
       dest=ytq      → ytq add <urls> --by "share sheet"
       success → job deleted + notification
       failure → job moved to .../Data/failed/<uuid>/ with error.txt + notification
```

## Install

Requirements: macOS 13+, Xcode (for `swiftc`), [uv](https://astral.sh/uv), and
a Telegram account. `ytq` is optional — only needed for that destination.

```sh
./install.sh          # build, sign, install, register, load the agent
send-to-my-bot login  # one-time: api_id/api_hash, phone, code, pick a chat
```

`login` wants an **api_id / api_hash** from <https://my.telegram.org/apps>, then
the phone number and the login code Telegram sends you, then it lists your chats
so you can pick a destination. Credentials and the session live in
`~/.config/send-to-my-bot/` (mode 600) — never in this repo.

If "Send to My Bot" doesn't show up in a share menu, check
System Settings → General → Login Items & Extensions → Sharing.

```sh
./uninstall.sh            # remove app, extension, agent, CLI
./uninstall.sh --purge    # …and the Telegram session/config
```

## CLI

The same script works standalone:

```sh
send-to-my-bot status                              # who am I, which chat
send-to-my-bot send --text "hello"                 # send to the chat
send-to-my-bot send --dest ytq --text "<video url>"
send-to-my-bot send --text "caption" report.pdf    # files, too
send-to-my-bot relay --quiet                       # drain the queue by hand
```

Logs: `~/Library/Logs/SendToMyBot.log`.

## Notes for anyone hacking on this

Hand-assembled bundles — there is no `.xcodeproj`, and none is needed:

- `swiftc -parse-as-library -application-extension -Xlinker -e -Xlinker _NSExtensionMain`
  produces a working `.appex` binary.
- **pkd silently ignores an `.appex` that isn't signed with
  `com.apple.security.app-sandbox`** — no error, it just never appears in
  `pluginkit -m`. This costs an afternoon if you don't know it.
- **macOS 26+ only hands the extension to pkd after the host app has been
  launched once.** A major OS upgrade drops the registration, so re-run
  `./install.sh` (which launches the app for you) after upgrading.
- Only Command Line Tools selected? `install.sh` finds Xcode and sets
  `DEVELOPER_DIR` itself.
- `zsh` has a `log` builtin — use `/usr/bin/log` when tracing pkd.

## License

MIT — see [LICENSE](LICENSE).
