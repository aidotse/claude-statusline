# claude-statusline

A [Claude Code status line](https://code.claude.com/docs/en/statusline), with support for people working across several
accounts, orgs, or teams.

```
🏢 Acme Corp (cswap)  |  🟡 Context: 63%  |  🧠 Opus 5.5
🕒 5h: 40% (resets @ 01:58PM)  |  📅 7d: 13% (resets @ Mon 12:58PM)  |  💸 Overage @ 01:11PM
```

Displayed:

- **Billing target**: who your tokens get billed to. This is the claude.ai organization of the active login, or *AWS
  Bedrock* / *Google Vertex AI* / *Microsoft Foundry* / *API key …abcd* when one of those is in use. Each org gets a
  stable color, and the dim suffix shows the config profile: `default` (`~/.claude`), `cswap` (a
  [claude-swap](https://github.com/realiti4/claude-swap) `cswap run` session), or `custom` (any other
  `CLAUDE_CONFIG_DIR`).
- **Context**: how full the context window is, colored green below 60%, yellow below 80%, red above that.
- **Model**: the model in use.

Line 2 appears only for claude.ai Pro/Max/Team/Enterprise logins, after the session's first response:

- **5h / 7d**: how much of the rolling usage limits you've used, and when each resets.
- **Forecast**: when you'll hit the 5h limit at your current burn rate, measured over the last 10 minutes across every
  terminal on the same seat. It says `💸 Overage @ <time>` if extra usage is enabled on your account and
  `⛔ Limit @ <time>` otherwise. It says `💸 Safe` if the window resets before you'd run out.

## Requirements

- **bash**: 3.2 or newer, so the stock macOS bash works. On Windows that means *Git Bash* (Git for Windows), which
  Claude Code uses to run status line commands.
- **jq**: `apt install jq`, `brew install jq`, or `winget install jqlang.jq`.

## Install

Copy `statusline.sh` to `~/.claude/statusline.sh` and add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "refreshInterval": 5
  }
}
```

On Windows, keep forward slashes in `command`. `refreshInterval` is optional, but it keeps the reset times and forecast
current while a session is idle.

To use it for one project only, put the `statusLine` block in that project's `.claude/settings.json` instead, pointing
`command` at wherever the script lives.

## Multiple accounts

No setup is needed. The script reads the login from the same place Claude Code does: `$CLAUDE_CONFIG_DIR/.claude.json`
when `CLAUDE_CONFIG_DIR` is set, otherwise `~/.claude.json`. Each terminal therefore shows its own account. Account
management tools like `claude-swap` are optional. Its `cswap run` sessions set `CLAUDE_CONFIG_DIR` (and share your
`settings.json`, so the status line follows along), and the script only uses that path to print the `cswap` label.

## Customizing

To pin org colors, uncomment the `case "$ORG_NAME"` block in the script. To test a change without Claude Code, pipe in a
sample payload:

```sh
echo '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42},
       "rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'$(($(date +%s)+3600))'}}}' \
  | bash statusline.sh
```
