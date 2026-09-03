# ReviewBar

A macOS menu-bar companion for [Anki](https://apps.ankiweb.net). Review your due
cards in small batches throughout the day, from a floating panel that grows out
of the notch — without opening Anki's reviewer window.

Anki itself stays the sole authority for scheduling. ReviewBar drives Anki's own
reviewer through the AnkiConnect add-on over localhost, so your reviews are
recorded exactly as if you had done them in Anki.

[![CI](https://github.com/gpressutto5/reviewbar-for-anki/actions/workflows/ci.yml/badge.svg)](https://github.com/gpressutto5/reviewbar-for-anki/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/gpressutto5/reviewbar-for-anki?label=download)](https://github.com/gpressutto5/reviewbar-for-anki/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Install

### Easy one-line install

```bash
curl -fsSL https://raw.githubusercontent.com/gpressutto5/reviewbar-for-anki/main/scripts/install.sh | bash
```

That downloads the latest release, installs it to `/Applications`, and starts it.
It needs no root and is [a readable 80-line script](scripts/install.sh) — worth
skimming, as with anything piped into a shell. Run it again to update.

### Manual install

Or **[download the release](https://github.com/gpressutto5/reviewbar-for-anki/releases/latest)**
and drag **ReviewBar.app** to Applications. Going that route, macOS will say
ReviewBar "cannot be opened because Apple cannot check it for malicious
software". This happens because this project doesn't have notarization, which requires a paid Developer Program membership. To open it anyway: dismiss the warning, then in **System
Settings >> Privacy & Security** click **Open Anyway** next to the message about
ReviewBar. That's a one-time step.

Look for ReviewBar's icon in the menu bar after launching.

## What it does

- **Due count in the menu bar**, scoped to the decks you choose.
- **A chromeless review panel** anchored to the notch (or top-center on displays
  without one). Click the notch to open it, Escape to dismiss.
- **Real card rendering** — your note-type CSS and JavaScript, images, and audio,
  reproducing Anki's reviewer DOM so themes behave the way they do in Anki.
- **Rating with interval previews**, taken from Anki's own scheduler, with
  keyboard shortcuts (space to reveal, `1`–`4` to rate).
- **Soft sessions** — after a batch of N cards, ReviewBar offers to stop rather
  than marching you through the whole backlog.
- **Inactivity reminders** — a quiet notch peek when you haven't reviewed in a
  while and something is waiting, escalating to a notification only when the
  notch can't be seen.
- **Update checks** — once a day, offered in the menu. Turn it off in
  *Settings → General*.

## Requirements

- macOS 15 or later (universal — Apple silicon and Intel)
- [Anki Desktop](https://apps.ankiweb.net), running
- The [AnkiConnect add-on](https://ankiweb.net/shared/info/2055492159) (API v6).
  In Anki: *Tools → Add-ons → Get Add-ons…*, paste code `2055492159`, restart.

ReviewBar talks only to `http://127.0.0.1:8765` on your own machine. It makes no
other network requests, and collects no telemetry.

## Building from source

Needs a Swift 6 toolchain; full Xcode for `make test` and for building an `.app`.

```sh
make build        # swift build
make test         # ReviewBarKit tests (no Anki required — uses a mock)
make run          # run the menu bar app (look for the status item)
make bundle       # .app via XcodeGen + xcodebuild
make install-dev  # bundle + install to ~/Applications + register it
make release      # Release build + zip in dist/ (see docs/RELEASING.md)
```

Anything bundle-dependent — notifications, launch-at-login, `LSUIElement` —
has to be tested through `make install-dev`, not `swift run`.
[`CLAUDE.md`](CLAUDE.md) covers the rest: architecture, environment overrides
for the reminder timescales, and how to probe a real Anki safely.

## Contributing

Issues and pull requests are welcome. Start with [`CLAUDE.md`](CLAUDE.md) —
despite the name it is the architecture guide, and it documents the invariants
that are easy to break. Please run `make test` before opening a pull request.

Other docs:
[`docs/ankiconnect-queue-findings.md`](docs/ankiconnect-queue-findings.md)
(why the app drives Anki's real reviewer instead of building its own queue) and
[`docs/RELEASING.md`](docs/RELEASING.md).

## Support

ReviewBar is free and open source. If it helps you keep your streak:

<a href="https://buymeacoffee.com/gpressutto5"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="36"></a>

## License

[MIT](LICENSE) © Guilherme Pressutto

Anki is a trademark of its respective owners. This project is an independent
companion app and is not affiliated with, endorsed by, or sponsored by
Anki/AnkiWeb.
