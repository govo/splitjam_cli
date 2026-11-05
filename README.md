# splitjam-cli

Release home for the `splitjam` command-line client — **binaries only**. The CLI source lives
with the app (in the SplitJam repo, under `cli/`); this repo builds, signs, notarizes and
publishes it, and keeps the one script that does so.

`splitjam` drives **SplitJam** (StemsPlayer) on macOS over **loopback HTTP**: the app listens on
`127.0.0.1` (48321, probing upward when taken), the CLI sends an authenticated request, and the
app — the only writer — executes it on its main thread and returns the result. No daemon, no
ports open to the LAN, and no system permission to grant.

Four rules follow from that, and none of them are negotiable:

- **The app must be running.** Otherwise commands fail immediately with `E_APP_NOT_RUNNING`.
  Nothing is queued, nothing is replayed later.
- **The token is the only secret.** It lives inside the app's sandbox and is copied once by the
  user into `~/.config/splitjam/config.json` (0600) via `splitjam auth`. Deleting it in the app
  revokes every paired CLI at once.
- **Entitlements are decided inside the app.** The CLI copies no thresholds and caches no
  purchase state. A paywall returns a structured "Pro required" error and raises the app's
  own upgrade prompt.
- **One writer.** The CLI never touches SQLite or audio files directly. It also never reads the
  app's container — that is why macOS never asks the user for Full Disk Access.

## Install

### Homebrew (recommended)

```bash
brew tap govo/tap
brew trust govo/tap        # Homebrew 6+ requires explicit trust for third-party taps
brew install splitjam
splitjam --version
```

### Direct download

Grab the tarball for your architecture from
[Releases](https://github.com/govo/splitjam_cli/releases):

```bash
tar -xzf splitjam-0.3.0-darwin-arm64.tar.gz     # use -x64 on Intel
sudo mv splitjam /usr/local/bin/
```

Artifacts are **Developer ID signed and notarized**, so Gatekeeper lets them through and no
`xattr -d` is needed. Only a fully offline machine whose binary could not be stapled will
complain; there, add `xattr -d com.apple.quarantine /usr/local/bin/splitjam`.

## Prerequisites

1. macOS 13 or later, with SplitJam running (the window may be minimized; do not quit the app).
2. SplitJam → Settings → **Command Line Access** turned on (off by default). Turning it on
   starts the loopback server and shows the token in the same card; turning it off stops the
   server and deletes the token, which revokes every CLI at once.
3. Copy the token into the CLI once:

   ```bash
   splitjam auth --token <token>          # stored in ~/.config/splitjam/config.json (0600)
   splitjam doctor                        # endpoint, token, presence, entitlement, permission
   ```

The CLI never launches the app and never reads or writes the app's container.

### Permission tier

The same settings card has a **Permission** menu that caps what a paired CLI may do:

| Tier | Allowed | Refused |
| --- | --- | --- |
| `read` | every read command (projects, tracks, audio peaks/slices, lyrics, capabilities) | every write → `E_FORBIDDEN` (exit 10) |
| `edit` (default) | the above + mixing, beats, sections, chords, lyrics writes | deletes → `E_FORBIDDEN` (exit 10) |
| `own` | everything, including deleting sections and chord notes | — |

`E_FORBIDDEN` means "raise the tier in Settings", **not** "buy Pro" — it is deliberately a
different code from `E_PRO_REQUIRED`. The tier is re-read on every request, so a change takes
effect immediately. `splitjam doctor` prints the current tier, and `capabilities --json` marks
each operation with `permission` / `destructive` / `allowed`.

## What it can do

```
splitjam doctor        # is the app running, is the token valid, what is the entitlement
splitjam project list  # every project with id, name, duration and revision
splitjam capabilities  # the whole command surface, machine-readable
```

| Area | Commands |
| --- | --- |
| Diagnostics | `doctor`, `ping`, `version`, `capabilities`, `schema`, `docs`, `auth`, `--version` |
| Entitlement | `entitlement get\|refresh\|restore` |
| Projects | `project list\|get\|rename\|note\|star` |
| Tracks | `track list\|get\|gain\|pan\|mute\|solo\|fold\|unfold\|move\|extension` |
| Audio | `track audio file\|peaks\|slice` |
| Mixer | `mixer master-volume\|master-pan\|speed\|pitch` |
| Beat | `beat get\|mode\|bpm\|meter\|multiplier\|density\|anchor\|lines\|accent\|snap\|reset` |
| Metronome | `metronome set\|first-beat` |
| Sections | `section list\|create\|update\|delete\|lock\|activate\|deactivate` |
| Chords | `chord get\|note set\|note delete\|key\|display` |
| Lyrics | `lyrics get` (read-only) |

Planned but **not** implemented: separation jobs (`import`, `job`), lyrics search/import/offset,
stem export, user tracks and asset replacement, `chord recognize`, and the score pipeline
(`bundle` / `transcribe` / `score`). Those return `E_UNSUPPORTED` rather than pretending to run.

`splitjam capabilities --json` is the authority — every entry carries `implemented`, `requires`
and `mutates`. `splitjam docs --json` dumps the local command table, which the
[skill repo](https://github.com/govo/splitjam_skill) uses to generate its command reference.

## Flags and exit codes

| Flag | Effect |
| --- | --- |
| `--json` | machine-readable output (agents should always pass it) |
| `--project <id\|name>` | target project; optional when only one exists |
| `--expect-revision <r>` | fail if the project changed since revision `r` |
| `--dry-run` | validate and report without writing (the entitlement gate still runs) |
| `--yes` | confirm a destructive operation |
| `--strict` | reject instead of clamping at the free-tier limit |
| `--no-app-prompt` | do not raise the in-app upsell prompt for this request |
| `--timeout <s>` | request timeout, default 15 |
| `--port <n>` | pin the automation port — connect only there, no probing. Omit to auto-discover 48321–48330 |
| `--token <t>` | one-off token override (prefer `splitjam auth`) |

Flags may appear before or after the command.

`0` ok · `2` argument · `3` app not running / not ready · `4` not found · `5` revision
conflict · `6` entitlement · `7` timeout · `8` protocol version · `9` auth/internal ·
`10` permission.

`E_PRO_REQUIRED` (no entitlement, or quota exhausted) and `E_ENTITLEMENT_UNKNOWN` (purchase
state unreadable) are both `6` but mean opposite things: the first needs an upgrade or a wait,
the second **does not mean the user has to pay** — retry after `entitlement refresh`.

## Repository layout

```
splitjam_cli/
├── VERSION              # single source of truth for the release number
├── scripts/
│   ├── release.sh       # build + sign + notarize + package + emit the formula
│   └── smoke.sh         # read-only end-to-end check against a running app
├── splitjam             # local build artifact (git-ignored); the tarballs are the deliverable
└── dist/                # tarballs + checksums, never committed
```

No source, no package manifest: `release.sh` builds from the app repo
(`SPLITJAM_CLI_PACKAGE`, default `../demucs/cli`).

## Releasing

```bash
# 1. bump the version, build both architectures, sign, notarize, package, regenerate the formula
./scripts/release.sh --version 0.3.0 --formula ../homebrew-tap/Formula/splitjam.rb

# 2. publish the artifacts
git tag v0.3.0 && git push origin v0.3.0
gh release create v0.3.0 dist/splitjam-0.3.0-darwin-arm64.tar.gz \
  dist/splitjam-0.3.0-darwin-x64.tar.gz dist/checksums.txt --title v0.3.0

# 3. commit the formula in the tap
git -C ../homebrew-tap commit -am "splitjam 0.3.0" && git -C ../homebrew-tap push
```

`VERSION` is the only place the number lives. `release.sh` rewrites `Catalog.version` in the
CLI source to match before building, then asserts the built binary reports it — a stale
constant makes `brew test` fail immediately after install.

```bash
./scripts/release.sh --skip-sign    # no certificate on this machine: compile only
./scripts/release.sh --no-build     # reuse /tmp binaries, re-sign and repackage
```

## Smoke test

```bash
./scripts/smoke.sh              # read-only walk through every read command
./scripts/smoke.sh --verbose    # print the JSON each step received
```

Requires the app to be running. It never writes, so it is safe against a real project.

## Related

- Skill for AI agents: [`govo/splitjam_skill`](https://github.com/govo/splitjam_skill)
- Homebrew tap: [`govo/homebrew-tap`](https://github.com/govo/homebrew-tap)
