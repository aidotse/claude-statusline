#!/usr/bin/env bash
# Claude Code status line: billing org, context %, model, 5h/7d limits, overage forecast.
# Install: see README.md. Needs bash (3.2+ is fine, for stock macOS) and jq.

PAYLOAD=$(cat)

ESC=$'\033'
RESET="${ESC}[0m"
DIM="${ESC}[2m"
SEP=$'\x1f'   # jq field separator: unlike tabs/spaces it can't appear in a name, so fields never shift
STATE_DIR=${TMPDIR:-/tmp}
STATE_DIR=${STATE_DIR%/}
NOW=$(date +%s)

# --- PORTABILITY HELPERS (Linux, macOS, Windows/Git Bash) ---
# jq -r, minus the carriage returns a native Windows jq.exe adds under Git Bash
# (a stray \r would make every numeric [ -lt ] test fail)
jqr() { jq -r "$@" | tr -d '\r'; }

# Format a UNIX epoch: GNU/busybox date (Linux, Git Bash) uses -d @N, BSD date (macOS) uses -r N.
# Detected up front because older macOS date has an unrelated -d (set kernel DST) option.
# Prints nothing on failure, so callers can fall back cleanly.
[ "$(date -d @0 +%s 2>/dev/null)" = "0" ] && DATE_GNU=1
fmt_epoch() {
    local t=${1%%.*}
    [ -n "$t" ] || return 1
    if [ -n "$DATE_GNU" ]; then
        date -d "@$t" "$2" 2>/dev/null
    else
        date -r "$t" "$2" 2>/dev/null
    fi
}

# Env-var flags like CLAUDE_CODE_USE_BEDROCK=1
is_on() { case "$1" in ''|0|false|FALSE|no|NO) return 1 ;; esac; }

# --- SESSION DATA ---
# One jq call for everything (process spawns are slow on Windows, and this runs every refresh).
# rate_limits is absent for API-key/cloud-provider sessions and before the first API response,
# so those fields come back empty rather than 0.
IFS=$SEP read -r MODEL CONTEXT_PCT FIVE_PCT_RAW FIVE_PCT FIVE_RESET SEVEN_PCT SEVEN_RESET < <(
    printf '%s' "$PAYLOAD" | jqr '
        def pct: if . == null then "" else (. + 0.5 | floor) end;
        [
            (.model.display_name // "Unknown Model"),
            (.context_window.used_percentage // 0 | floor),
            (.rate_limits.five_hour.used_percentage // ""),
            (.rate_limits.five_hour.used_percentage | pct),
            (.rate_limits.five_hour.resets_at // ""),
            (.rate_limits.seven_day.used_percentage | pct),
            (.rate_limits.seven_day.resets_at // "")
        ] | map(tostring) | join("\u001f")' 2>/dev/null
)
MODEL=${MODEL:-Unknown Model}
CONTEXT_PCT=${CONTEXT_PCT:-0}

# --- BILLING IDENTITY (org / account) ---
# Mirrors Claude Code's own lookup: config home is $CLAUDE_CONFIG_DIR or ~/.claude; the global
# config is a non-empty legacy <config home>/.config.json if present, else
# ($CLAUDE_CONFIG_DIR or $HOME)/.claude.json. `cswap run` sets CLAUDE_CONFIG_DIR per account.
CONFIG_HOME=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
if [ -s "$CONFIG_HOME/.config.json" ]; then
    CLAUDE_JSON="$CONFIG_HOME/.config.json"
else
    CLAUDE_JSON="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
fi

# Claude Code keys an approved ANTHROPIC_API_KEY by its last 20 characters
API_KEY_TAIL=""
[ -n "$ANTHROPIC_API_KEY" ] && API_KEY_TAIL=${ANTHROPIC_API_KEY: -20}

IFS=$SEP read -r ORG_NAME ORG_UUID ACCOUNT_UUID EXTRA_USAGE API_KEY_APPROVED < <(
    jqr --arg tail "$API_KEY_TAIL" '
        (.oauthAccount // {}) as $a
        | [
            ($a.organizationName // ""),
            ($a.organizationUuid // ""),
            ($a.accountUuid // ""),
            ($a.hasExtraUsageEnabled // false),
            ($tail != "" and any((.customApiKeyResponses.approved // [])[]; . == $tail))
        ] | map(tostring) | join("\u001f")' "$CLAUDE_JSON" 2>/dev/null
)

# Who gets billed, most specific first: a cloud provider or an approved API key beats the login
if is_on "$CLAUDE_CODE_USE_BEDROCK"; then
    ORG_NAME="AWS Bedrock"; ORG_UUID=""
elif is_on "$CLAUDE_CODE_USE_VERTEX"; then
    ORG_NAME="Google Vertex AI"; ORG_UUID=""
elif is_on "$CLAUDE_CODE_USE_FOUNDRY"; then
    ORG_NAME="Microsoft Foundry"; ORG_UUID=""
elif [ -n "$ANTHROPIC_API_KEY" ] && { [ -z "$ORG_NAME" ] || [ "$API_KEY_APPROVED" = "true" ]; }; then
    ORG_NAME="API key …${ANTHROPIC_API_KEY: -4}"; ORG_UUID=""
elif [ -z "$ORG_NAME" ]; then
    # No login info: fall back to the config dir's last path component (splits on / and \)
    ORG_NAME=${CLAUDE_CONFIG_DIR:-unknown-org}
    ORG_NAME=${ORG_NAME%[/\\]}
    ORG_NAME=${ORG_NAME##*[/\\]}
fi

# Which config profile is this terminal using?
if [[ "$CLAUDE_CONFIG_DIR" == *claude-swap* ]]; then
    ORG_SOURCE="cswap"     # ~/.local/share/claude-swap/... (Linux) or ~/.claude-swap-backup/... (macOS/Windows)
elif [ -n "$CLAUDE_CONFIG_DIR" ]; then
    ORG_SOURCE="custom"
else
    ORG_SOURCE="default"
fi

# Stable per-org color, so two terminals on different teams look different at a glance.
# (Avoids green/yellow/red, which the context meter uses.)
ORG_PALETTE=(36 35 34 96 95 94)
read -r ORG_HASH _ < <(printf '%s' "${ORG_UUID:-$ORG_NAME}" | cksum)
ORG_COLOR="${ESC}[1;${ORG_PALETTE[$(( ${ORG_HASH:-0} % ${#ORG_PALETTE[@]} ))]}m"
# To pin colors yourself instead, uncomment and edit:
# case "$ORG_NAME" in
#     "Acme Corp")   ORG_COLOR="${ESC}[1;36m" ;;  # cyan
#     "Globex Inc")  ORG_COLOR="${ESC}[1;35m" ;;  # magenta
# esac

# --- 5H BUDGET FORECAST (10-minute rolling burn rate) ---
# Limits are per seat (account + org), so terminals sharing a seat share one history file.
# Each line is "<epoch> <window resets_at> <used %>".
BUDGET_STR=""
if [ -n "$FIVE_PCT_RAW" ] && [ -n "$FIVE_RESET" ]; then
    LIMIT_KEY=$(printf '%s' "${ACCOUNT_UUID}_${ORG_UUID:-$ORG_NAME}" | tr -c 'A-Za-z0-9_-' '_')
    HISTORY_FILE="$STATE_DIR/claude_statusline_5h_${LIMIT_KEY}"
    TMP_FILE="$HISTORY_FILE.$$.tmp"
    [ -f "$HISTORY_FILE" ] || : > "$HISTORY_FILE" 2>/dev/null

    FORECAST=$(awk -v now="$NOW" -v r="$FIVE_RESET" -v p="$FIVE_PCT_RAW" -v out="$TMP_FILE" '
        function abs(x) { return x < 0 ? -x : x }
        BEGIN { n = 0; max = 0 }
        # Only points from the current window (a reset gives a new resets_at)
        NF == 3 && abs($2 - r) < 300 { t[n] = $1; v[n] = $3; n++; if ($3 + 0 > max) max = $3 + 0 }
        END {
            # Usage only grows within a window, so only record a point when it rises.
            # This also drops stale, lower values from idle terminals on the same seat.
            if (n == 0 || p + 0 > max) { t[n] = now; v[n] = p; n++; max = p + 0 }

            # Prune to the last 10 min, plus the newest older point: it is the value 10 min ago
            cutoff = now - 600
            first = 0
            for (i = 0; i < n; i++) if (t[i] <= cutoff) first = i
            for (i = first; i < n; i++) print t[i], r, v[i] > out
            close(out)

            if (max >= 100) { print "OVER"; exit }
            dt = (now - (t[first] > cutoff ? t[first] : cutoff)) / 60
            if (dt < 2) { print "SAFE"; exit }               # not enough history yet
            rate = (max - v[first]) / dt                      # % per minute
            if (rate <= 0.01) { print "SAFE"; exit }
            left = (100 - max) / rate
            if (now + left * 60 >= r) { print "SAFE"; exit } # window resets first
            printf "%.0f\n", left
        }' "$HISTORY_FILE" 2>/dev/null) && mv -f "$TMP_FILE" "$HISTORY_FILE" 2>/dev/null
    rm -f "$TMP_FILE" 2>/dev/null

    # Hitting 100% means overage billing with extra usage enabled, otherwise a hard stop
    if [ "$EXTRA_USAGE" = "true" ]; then
        HIT_ICON="💸"; HIT_AT="Overage @"; HIT_NOW="In overage"
    else
        HIT_ICON="⛔"; HIT_AT="Limit @"; HIT_NOW="Limit reached"
    fi
    case "$FORECAST" in
        OVER)    BUDGET_STR="${HIT_ICON} ${HIT_NOW}" ;;
        ''|SAFE) BUDGET_STR="💸 Safe" ;;
        *)
            EXHAUSTION_TIME=$(fmt_epoch $(( NOW + FORECAST * 60 )) +%I:%M%p)
            if [ -n "$EXHAUSTION_TIME" ]; then
                BUDGET_STR="${HIT_ICON} ${HIT_AT} ${EXHAUSTION_TIME}"
            else
                BUDGET_STR="${HIT_ICON} ${HIT_AT/@/in} ${FORECAST}m"
            fi
            ;;
    esac
fi

# --- RATE LIMIT WINDOWS ---
LIMITS_STR=""
if [ -n "$FIVE_PCT" ]; then
    FIVE_HR_TIME=$(fmt_epoch "$FIVE_RESET" +%I:%M%p)
    LIMITS_STR="🕒 5h: ${FIVE_PCT}%${FIVE_HR_TIME:+ (resets @ ${FIVE_HR_TIME})}"
fi
if [ -n "$SEVEN_PCT" ]; then
    SEVEN_DAY_TIME=$(fmt_epoch "$SEVEN_RESET" "+%a %I:%M%p")
    LIMITS_STR="${LIMITS_STR:+${LIMITS_STR}  |  }📅 7d: ${SEVEN_PCT}%${SEVEN_DAY_TIME:+ (resets @ ${SEVEN_DAY_TIME})}"
fi
[ -n "$BUDGET_STR" ] && LIMITS_STR="${LIMITS_STR:+${LIMITS_STR}  |  }${BUDGET_STR}"

# --- CONTEXT METER (traffic light) ---
if [ "$CONTEXT_PCT" -lt 60 ] 2>/dev/null; then
    COLOR="${ESC}[32m"; ICON="🟢"
elif [ "$CONTEXT_PCT" -lt 80 ] 2>/dev/null; then
    COLOR="${ESC}[33m"; ICON="🟡"
else
    COLOR="${ESC}[31m"; ICON="🔴"
fi

# --- OUTPUT ---
# printf '%s', not echo -e: names containing backslashes or % must print literally
ORG_STR="${ORG_COLOR}🏢 ${ORG_NAME}${RESET}${DIM} (${ORG_SOURCE})${RESET}"
printf '%s\n' "${ORG_STR}  |  ${ICON} ${COLOR}Context: ${CONTEXT_PCT}%${RESET}  |  🧠 ${MODEL}"
[ -n "$LIMITS_STR" ] && printf '%s\n' "$LIMITS_STR"
exit 0
