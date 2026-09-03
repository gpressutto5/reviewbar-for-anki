# ReviewBar

A macOS menu-bar companion for [Anki](https://apps.ankiweb.net). Review your due
cards in small batches throughout the day, from a floating panel that grows out
of the notch — without opening Anki's reviewer window.

Anki itself stays the sole authority for scheduling. ReviewBar drives Anki's own
reviewer through the AnkiConnect add-on over localhost; it never builds a
competing queue, and your reviews are recorded exactly as if you had done them
in Anki.

[![CI](https://github.com/gpressutto5/reviewbar-for-anki/actions/workflows/ci.yml/badge.svg)](https://github.com/gpressutto5/reviewbar-for-anki/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/gpressutto5/reviewbar-for-anki?label=download)](https://github.com/gpressutto5/reviewbar-for-anki/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Install

**[⬇ Download the latest release](https://github.com/gpressutto5/reviewbar-for-anki/releases/latest)**

Unzip it and drag **ReviewBar.app** to your Applications folder. ReviewBar is a
menu-bar app — no Dock icon, no main window — so look for its status item in the
menu bar after launching.

### The first-launch warning

macOS will say ReviewBar "cannot be opened because Apple cannot check it for
malicious software." That is expected, and it is not a claim that anything is
wrong with the app: Apple's notarization requires a paid Developer Program
membership ($99/year), which this project doesn't have. The build is ad-hoc
signed and built in the open — you can read the
[workflow that produced it](.github/workflows/release.yml).

To open it the first time:

1. Try to open ReviewBar, and dismiss the warning.
2. Open **System Settings → Privacy & Security**, scroll to the Security
   section, and click **Open Anyway** next to the message about ReviewBar.
3. Confirm. macOS remembers the decision, so this is a one-time step.

> On macOS 15, Control-clicking the app and choosing *Open* no longer works —
> Apple removed that shortcut in Sequoia. The System Settings route above is the
> supported one.

### Or install without the warning

macOS only quarantines apps it sees arrive from a browser, so installing from
the command line skips the whole dance:

```bash
curl -fsSL https://raw.githubusercontent.com/gpressutto5/reviewbar-for-anki/main/scripts/install.sh | bash
```

That downloads the latest release, installs it to `/Applications`, and starts
it. It needs no root, touches nothing but `ReviewBar.app`, and is
[a readable 80-line script](scripts/install.sh) — worth skimming before you run
it, as with anything piped into a shell. To do the same by hand after dragging
the app across:

```bash
xattr -dr com.apple.quarantine /Applications/ReviewBar.app
```

Running the installer again updates an existing install.

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
- **Sequential decks** — "all decks" walks your top-level decks in order.
- **Update checks** — ReviewBar checks GitHub once a day and offers the new
  version in its menu. Turn it off in *Settings → General*.

## Requirements

- macOS 15 or later (universal — Apple silicon and Intel)
- [Anki Desktop](https://apps.ankiweb.net), running
- The [AnkiConnect add-on](https://ankiweb.net/shared/info/2055492159) (API v6).
  In Anki: *Tools → Add-ons → Get Add-ons…* and paste code `2055492159`, then
  restart Anki.

ReviewBar talks only to `http://127.0.0.1:8765` on your own machine. It makes no
network requests of any other kind, and collects no telemetry.

## Building from source

```sh
make build        # swift build
make test         # ReviewBarKit tests (no Anki required — uses a mock)
make run          # run the menu bar app (look for the status item)
make bundle       # .app via XcodeGen + xcodebuild (needs Xcode + XcodeGen)
make install-dev  # bundle + install to ~/Applications + register it
make release      # Release build + zip in dist/ (see docs/RELEASING.md)
```

You need a Swift 6 toolchain. Full Xcode is required for `make test` and for
building an `.app`; Command Line Tools alone can still `swift build`.

`ReviewBar.xcodeproj` and `Support/` are generated from `project.yml` and are not
checked in. The bundle is what you need for anything bundle-dependent —
`LSUIElement`, notifications, launch-at-login — and notifications additionally
require an installed, Launch-Services-registered app, which is what
`make install-dev` is for. `make bundle` builds Debug; a distributable build must
be Release, since Debug carries the `get-task-allow` entitlement that
notarization rejects.

The app icon is a placeholder. To replace it, drop any `.icns` at
`Resources/AppIcon.icns` — nothing else references the artwork. The current one
is drawn by `scripts/make-placeholder-icon.swift`, so it can be tweaked and
regenerated with `swift scripts/make-placeholder-icon.swift`.

Reminders act on hour timescales, so environment overrides make them observable:

```sh
REVIEWBAR_STARTUP_GRACE=2 REVIEWBAR_NUDGE_INTERVAL=20 make run
```

`REVIEWBAR_FORCE_NOTCH_HIDDEN=1` forces the notification rung,
`REVIEWBAR_AUTO_OPEN=1` the auto-open rung, and `REVIEWBAR_OPEN_REVIEW=1|idle`
opens the panel's review states without a notch click.

## Testing against a real Anki safely

Never point destructive experiments at your production collection. Create a
disposable profile: *Anki → File → Switch Profile → Add*, name it
`reviewbar-test`, and install AnkiConnect in it (add-ons are shared across
profiles, so it's usually already active).

Ad-hoc probing counts as an experiment: an AnkiConnect action whose name starts
with `get` can still write. `getLatestReviewID` creates a deck for any name it
doesn't recognise, and `getIntervals` mutates the cards table — see
[`docs/ankiconnect-queue-findings.md`](docs/ankiconnect-queue-findings.md).

On macOS, App Nap can freeze a backgrounded Anki and stop AnkiConnect from
responding. The workaround is
`defaults write net.ankiweb.dtop NSAppSleepDisabled -bool true`.

## Contributing

Issues and pull requests are welcome. Start with
[`CLAUDE.md`](CLAUDE.md) — despite the name it is the architecture guide, and it
documents the invariants that are easy to break (the GUI-driven review flow, the
single clock, the ease-vs-position rating buttons).

Please run `make test` before opening a pull request; CI runs the same suite plus
a bundle build on every push.

## Docs

- [`CLAUDE.md`](CLAUDE.md) — architecture and the invariants worth knowing
- [`docs/ankiconnect-queue-findings.md`](docs/ankiconnect-queue-findings.md) —
  why the app drives Anki's real reviewer instead of building its own queue
- [`docs/RELEASING.md`](docs/RELEASING.md) — how releases are built, signed and
  notarized

## Support

ReviewBar is free and open source. If it helps you keep your streak:

<a href="https://buymeacoffee.com/gpressutto5"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="36"></a>

## License

[MIT](LICENSE) © Guilherme Pressutto

## Trademark

Anki is a trademark of its respective owners. This project is an independent
companion app and is not affiliated with, endorsed by, or sponsored by
Anki/AnkiWeb.
