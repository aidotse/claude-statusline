@README.md

# Notes for agents

## Hard constraints

- **Single file**: everything lives in `statusline.sh`. Don't add helper scripts, config files, or dependencies beyond
  `bash` and `jq` (plus POSIX `awk`, `date`, `cksum`, `tr`).
- **Portability**: it must run on bash 3.2 (stock macOS), so no `mapfile`, `${var,,}`, associative arrays, or
  `printf '%(...)T'`. It must also work with mawk, gawk, BSD awk, and busybox awk, so no gawk-only functions like
  `strftime`. And it must work under Git Bash on Windows, where `jq.exe` emits `\r\n`, so always go through `jqr`.
- **Dates**: only through `fmt_epoch`, because GNU and busybox take `date -d @N` while BSD/macOS takes `date -r N`.
- **Speed**: the script runs on every status refresh, every 5s per terminal with `refreshInterval`, and process spawns
  are slow on Windows. Keep it to one `jq` call over the payload and one over the config file, and don't add more
  subprocesses lightly.
- **Output**: print with `printf '%s\n'`, not `echo -e`, because org and model names are untrusted text. Always exit 0.
  Line 2 is omitted when there's nothing to show.

## Data sources

- **stdin payload**: the [status line JSON](https://code.claude.com/docs/en/statusline). `rate_limits` (and each window
  inside it) can be absent: it's subscriber-only, it appears after the first API response, and a window is dropped once
  its `resets_at` passes. `context_window.used_percentage` can be `null`. Percentages can be floats, and `resets_at` is
  in epoch seconds.
- **Global config**: the login identity comes from `.oauthAccount` in the global config, resolved the way Claude Code
  does it (see the comment in the script). `claude-swap` resolves it the same way. Its `cswap run` sessions live under
  `.../claude-swap/sessions/<n>-<email>/` on Linux and `~/.claude-swap-backup/sessions/...` on macOS/Windows, which is
  why the `*claude-swap*` match works.

## Forecast state

The forecast keeps one history file per seat, at `${TMPDIR:-/tmp}/claude_statusline_5h_<accountUuid>_<orgUuid>`, shared
by every terminal on that seat. Each line is `<epoch> <resets_at> <pct>`. The rules:

- A point is appended only when the percentage rises within the current window. Usage is monotonic within a window, so
  this filters out stale payloads from idle terminals.
- Points from another window (a different `resets_at`) are dropped.
- The file is pruned to the last 10 minutes, plus the newest older point, which serves as the 10-minutes-ago baseline.

Writes go through a per-PID temp file and `mv`. Losing a point to a race is harmless.

## Testing

There's no test suite. Pipe in sample payloads with `HOME` and `TMPDIR` pointed at a scratch directory, so the real
login and history files stay untouched. Seed the history file directly to exercise the forecast. For bash 3.2 and
busybox, run it in `docker run --rm -i bash:3.2` after `apk add jq`. macOS `date -r` and Windows Git Bash haven't been
tested on real machines.
