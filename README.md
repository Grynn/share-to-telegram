# Share to Claw

A macOS share-sheet extension that sends whatever you're looking at — a URL,
selected text, an image, a PDF — to **destinations you define**: a webhook (an
[OpenClaw](https://github.com/openclaw/openclaw) `/hooks/wake`, say), your own
Telegram chat *posted as you* (a real user account over MTProto, not a bot
token), or any CLI on your machine.

```
⌘ any app  →  Share  →  Share to Claw
        ┌──────────────────────────────────────────┐
        │ youtube.com/watch?v=…                    │
        │ ┌──────────────────────────────────────┐ │
        │ │ Message (optional)                   │ │
        │ └──────────────────────────────────────┘ │
        │ [ claw | Telegram | ytq ]  Cancel  Send  │
        │ ⏎ send · ⎋ cancel · ⌘1–⌘3 destination    │
        └──────────────────────────────────────────┘
```

The message field is focused the moment the panel opens, so the whole
interaction is: share → type a note (or not) → ⏎. The panel closes instantly;
delivery happens out of process.

- **⏎** send · **⎋** cancel · **⌘1…⌘9** pick a destination
- A destination can claim hosts (`auto_for_hosts`), so a YouTube or X link
  auto-selects your video queue while everything else goes to the default.
- A destination that can't take files (a JSON webhook) can name a `files_via`
  fallback — share an image to `claw` and the note goes to the webhook while
  the image lands in the Telegram chat claw reads.
- Send is greyed out, with a reason, when the payload doesn't suit the
  destination (a URL-only queue with no URL in the share).

## Destinations

Configured in `~/.config/share-to-claw/config.json` — write it by hand from
[`config.example.json`](config.example.json), or just run `share-to-claw setup`.

| type | what it does | key fields |
|---|---|---|
| `webhook` | HTTP POST with a JSON body template | `url`, `token`, `body`, `headers` |
| `telegram` | posts as your own account | `chat_id` (defaults to the one from `login`) |
| `command` | runs any CLI | `command` (argv, with placeholders) |

Placeholders inside `body` and `command`: `{message}` (your note), `{text}`
(what you shared), `{all}` (both), plus `{urls}` and `{files}` in a `command`,
which expand into one argument each.

Secrets can be inline, or pulled from elsewhere at send time:
`"token": {"env": "MY_TOKEN"}` or `{"file": "~/.config/secret"}`.

Every destination declares `accepts` (`text`, `url`, `file`, `image`), which
drives both the routing and what the panel lets you do.

## How it works

macOS only loads a share extension if it is **sandboxed**, and a sandboxed
extension can neither reach the network nor exec a CLI. So the extension does
the smallest possible job — write the share to a queue inside its own container
— and an unsandboxed LaunchAgent does the delivery:

```
Share sheet
  └─ ShareToClawExt.appex        sandboxed; writes a job, dismisses instantly
       ~/Library/Containers/app.sharetoclaw.share/Data/queue/<uuid>/job.json
       (reads destinations.json from the same container to build the picker)
  └─ LaunchAgent app.sharetoclaw.relay
       WatchPaths on the queue (fires in ~1s) + 5-minute timer as a backstop
       runs: uv run share_to_claw.py relay
  └─ share_to_claw.py
       resolves the destination, delivers, re-publishes destinations.json
       success → job deleted + notification
       failure → job moved to .../Data/failed/<uuid>/ with error.txt + notification
```

## Install

Requirements: macOS 13+, Xcode (for `swiftc` — the CLT alone can't build an app
extension), [uv](https://astral.sh/uv). Telegram and any CLI destinations are
optional; a webhook alone is a complete setup.

### Homebrew

```sh
brew install grynn/tap/share-to-claw
share-to-claw register   # register the extension, load the relay agent
share-to-claw setup      # wizard: asks only for what's missing
```

### From source

```sh
git clone https://github.com/Grynn/share-to-claw.git
cd share-to-claw
./install.sh             # build, sign, install to ~/Applications, register
share-to-claw setup
```

`setup` is idempotent — re-run it any time to add a destination or rotate a
secret; ⏎ keeps whatever is already stored, and nothing already configured is
asked for again. It walks through a webhook, Telegram (api_id/api_hash from
<https://my.telegram.org/apps>, phone, login code), and any CLI destinations it
finds installed. Credentials live in `~/.config/share-to-claw/` (mode 600) —
never in this repo.

If "Share to Claw" doesn't show up in a share menu, check
System Settings → General → Login Items & Extensions → Sharing.

### Uninstall

```sh
share-to-claw unregister && brew uninstall share-to-claw   # Homebrew
./uninstall.sh                                             # from source
./uninstall.sh --purge                                     # …and the config/session
```

## CLI

The same script works standalone:

```sh
share-to-claw status                        # readiness of every destination
share-to-claw dests                         # list them (* marks the default)
share-to-claw send --dest claw --text "https://example.com" --message "look"
share-to-claw send --dest telegram report.pdf --message "monthly"
share-to-claw sync                          # re-publish the picker metadata
share-to-claw relay --quiet                 # drain the queue by hand
```

Logs: `~/Library/Logs/ShareToClaw.log`.

## Notes for anyone hacking on this

Hand-assembled bundles — there is no `.xcodeproj`, and none is needed:

- `swiftc -parse-as-library -application-extension -Xlinker -e -Xlinker _NSExtensionMain`
  produces a working `.appex` binary.
- **pkd silently ignores an `.appex` that isn't signed with
  `com.apple.security.app-sandbox`** — no error, it just never appears in
  `pluginkit -m`. This costs an afternoon if you don't know it.
- **macOS 26+ only hands the extension to pkd after the host app has been
  launched once.** A major OS upgrade drops the registration, so re-run
  `./install.sh` (or `share-to-claw register`) after upgrading.
- The sandboxed extension can't read `~/.config`, so the relay republishes a
  secret-free `destinations.json` into the extension's container on every run.
- Bot rules reject Python's default `User-Agent` (Cloudflare error 1010 for
  `Python-urllib/3.x`), so webhook posts send a real one.
- Only Command Line Tools selected? `install.sh` finds Xcode and sets
  `DEVELOPER_DIR` itself.
- `zsh` has a `log` builtin — use `/usr/bin/log` when tracing pkd.

## License

MIT — see [LICENSE](LICENSE).
