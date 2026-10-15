#!/usr/bin/env bash

# ==============================================================================
# fabric-menu — Rofi/Wofi launcher for Fabric AI patterns
# ==============================================================================

# Strict mode: exit on unset vars, propagate pipe failures.
# We do NOT use 'set -e' globally; exit codes are captured explicitly
# so handle_result() always runs.
set -uo pipefail

# Expand PATH for non-interactive sessions (KRunner, shortcuts, etc.)
export PATH="$HOME/go/bin:$HOME/.local/bin:/usr/local/go/bin:/usr/bin:/bin:$PATH"

# ==============================================================================
# 1. PATHS & BOOTSTRAPPING
# ==============================================================================
readonly APP_NAME="Fabric Menu"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fabric-menu"
readonly CONFIG_FILE="$CONFIG_DIR/config.conf"
readonly BOOKMARKS_FILE="$CONFIG_DIR/bookmarks.txt"   # legacy; merged into favorites.txt
readonly FAVORITES_FILE="$CONFIG_DIR/favorites.txt"
readonly LEGACY_CONFIG_FILE="$CONFIG_DIR/config.sh"   # old shell-script style config
readonly DESKTOP_DIR="$HOME/.local/share/applications"
readonly DESKTOP_FILE="$DESKTOP_DIR/fabric-menu.desktop"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH

# ------------------------------------------------------------------------------
# Settings table. config.conf is a plain KEY=value file (it is read line by line,
# never executed as a script). Every setting is described here once; the file and
# the in-app Settings menu are both generated from this table.
#   type: bool | enum:a,b,c | text | lang | model | strategy
# ------------------------------------------------------------------------------
SETTING_KEYS=(
    MENU_TOOL CLIPBOARD_TOOL CAPTURE_MODE CUSTOM_COMMANDS FABRIC_CMD
    DEFAULT_LANG DEFAULT_MODEL DEFAULT_STRATEGY
    QUICK_RUN SHOW_PREVIEW STRIP_CODE_FENCE NOTIFICATIONS
    OUTPUT_DIR ROFI_THEME
)
declare -A SETTING_DEFAULT=(
    [MENU_TOOL]="auto" [CLIPBOARD_TOOL]="auto" [CAPTURE_MODE]="highlight" [CUSTOM_COMMANDS]="false" [FABRIC_CMD]="auto"
    [DEFAULT_LANG]="" [DEFAULT_MODEL]="" [DEFAULT_STRATEGY]=""
    [QUICK_RUN]="false" [SHOW_PREVIEW]="false"
    [STRIP_CODE_FENCE]="true" [NOTIFICATIONS]="true"
    [OUTPUT_DIR]='$HOME/fabric-outputs' [ROFI_THEME]=""
)
declare -A SETTING_TYPE=(
    [MENU_TOOL]="enum:auto,rofi,wofi"
    [CLIPBOARD_TOOL]="enum:auto,wl-clipboard,xclip"
    [CAPTURE_MODE]="enum:highlight,clipboard,copy-keystroke" [CUSTOM_COMMANDS]="bool"
    [FABRIC_CMD]="text" [DEFAULT_LANG]="lang" [DEFAULT_MODEL]="model" [DEFAULT_STRATEGY]="strategy"
    [QUICK_RUN]="bool" [SHOW_PREVIEW]="bool"
    [STRIP_CODE_FENCE]="bool" [NOTIFICATIONS]="bool"
    [OUTPUT_DIR]="text" [ROFI_THEME]="text"
)
declare -A SETTING_LABEL=(
    [MENU_TOOL]="Menu program" [CLIPBOARD_TOOL]="Clipboard program" [CAPTURE_MODE]="Input capture" [CUSTOM_COMMANDS]="Custom commands"
    [FABRIC_CMD]="Fabric command" [DEFAULT_LANG]="Default language" [DEFAULT_MODEL]="Default model"
    [DEFAULT_STRATEGY]="Default strategy" [QUICK_RUN]="Quick run" [SHOW_PREVIEW]="Result preview"
    [STRIP_CODE_FENCE]="Strip code fence" [NOTIFICATIONS]="Notifications"
    [OUTPUT_DIR]="Output folder" [ROFI_THEME]="Rofi theme file"
)
declare -A SETTING_DESC=(
    [MENU_TOOL]="Menu program: auto, rofi or wofi."
    [CLIPBOARD_TOOL]="Clipboard program: auto, wl-clipboard (Wayland) or xclip (X11)."
    [CAPTURE_MODE]="How the input text is captured: highlight (the text you highlighted, else the clipboard), clipboard (only what is already copied), or copy-keystroke (presses Ctrl+C for you; needs wtype or ydotool)."
    [CUSTOM_COMMANDS]="WARNING: shows the 'Custom Command' menu item, which runs any shell command you type, with your own permissions. A wrong command (for example rm) can damage your system. true or false."
    [FABRIC_CMD]="Fabric program: auto, fabric or fabric-ai."
    [DEFAULT_LANG]="Default output language, e.g. nl-x-dutch or en. Empty = Fabric's default."
    [DEFAULT_MODEL]="Default AI model. Empty = Fabric's configured default."
    [DEFAULT_STRATEGY]="Default prompt strategy, e.g. cot. Empty = none."
    [QUICK_RUN]="Run a pattern immediately after choosing it, skipping the options menu."
    [SHOW_PREVIEW]="Show the result in a preview window after each run (rofi only)."
    [STRIP_CODE_FENCE]="Remove a wrapping markdown code fence the AI sometimes adds around the whole answer."
    [NOTIFICATIONS]="Show desktop notifications."
    [OUTPUT_DIR]="Folder where results are saved when you choose 'Save output to file'."
    [ROFI_THEME]="Optional path to a custom rofi theme (.rasi). Empty = rofi's default."
)

# Load defaults into variables named after the keys.
_load_defaults() {
    local k
    for k in "${SETTING_KEYS[@]}"; do printf -v "$k" '%s' "${SETTING_DEFAULT[$k]}"; done
    OUTPUT_DIR=$(_expand_home "$OUTPUT_DIR")
}

# Expand a leading ~ or $HOME in a path-like value.
_expand_home() {
    local v="$1"
    # shellcheck disable=SC2088
    [[ "$v" == "~" || "$v" == "~/"* ]] && v="$HOME${v#\~}"
    v="${v//\$HOME/$HOME}"
    v="${v//\$\{HOME\}/$HOME}"
    printf '%s' "$v"
}

# Read a KEY=value file (also reads the old shell-style config.sh safely:
# only known keys are accepted and nothing is executed).
_read_config_file() {
    local file="$1" line key val k known
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# || "$line" != *=* ]] && continue
        key="${line%%=*}"; val="${line#*=}"
        key="${key//[[:space:]]/}"
        known=false
        for k in "${SETTING_KEYS[@]}"; do [[ "$k" == "$key" ]] && known=true; done
        [[ "$known" == true ]] || continue
        if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ || "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        [[ "$key" == OUTPUT_DIR || "$key" == ROFI_THEME ]] && val=$(_expand_home "$val")
        printf -v "$key" '%s' "$val"
    done < "$file"
}

# Write all settings, one commented block each, so the file always looks the same.
save_config() {
    local k v
    {
        printf '# %s configuration\n' "$APP_NAME"
        printf '# Plain KEY=value lines. Edit here or use the Settings entry in the menu.\n'
        for k in "${SETTING_KEYS[@]}"; do
            v="${!k}"
            # Store paths as ~/... so the file holds no machine-specific home folder.
            if [[ "$k" == OUTPUT_DIR || "$k" == ROFI_THEME ]] && [[ "$v" == "$HOME/"* ]]; then
                # shellcheck disable=SC2088  # literal ~ is intended
                v="~/${v#"$HOME"/}"
            fi
            printf '\n# %s\n%s=%s\n' "${SETTING_DESC[$k]}" "$k" "$v"
        done
    } > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

# Change one setting, keep the variable and the file in sync.
set_setting() {   # key value
    printf -v "$1" '%s' "$2"
    save_config
}

mkdir -p "$CONFIG_DIR"

# One-time conversion of the old config.sh (a shell script) to config.conf (plain
# settings). The old file is kept as config.sh.migrated.
if [[ ! -f "$CONFIG_FILE" && -f "$LEGACY_CONFIG_FILE" ]]; then
    _load_defaults
    _read_config_file "$LEGACY_CONFIG_FILE"
    save_config
    mv "$LEGACY_CONFIG_FILE" "$LEGACY_CONFIG_FILE.migrated"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    _load_defaults
    save_config
fi

if [[ ! -f "$FAVORITES_FILE" ]]; then
    cat > "$FAVORITES_FILE" << 'EOF'
# Saved Fabric command favorites
# Format: display name | command template  (use {{INPUT}} for the captured text/URL)
#
# A favorite can also be a pattern chain that gets the normal URL/YouTube/text
# handling and the options menu:  name | @chain pattern1 pattern2
#
# Examples:
# YouTube + Wisdom | fabric -y "{{INPUT}}" | fabric -p youtube_summary | fabric -p extract_wisdom
# Summarize Dutch  | echo "{{INPUT}}" | fabric -p summarize -g nl-x-dutch
Summarize | @chain summarize
Extract wisdom | @chain extract_wisdom
EOF
    chmod 644 "$FAVORITES_FILE"
fi

# One-time migration: pinned patterns (bookmarks.txt) become favorites.
if [[ -f "$BOOKMARKS_FILE" ]]; then
    while IFS= read -r _bm; do
        [[ -z "$_bm" ]] && continue
        grep -q "^${_bm} | " "$FAVORITES_FILE" 2>/dev/null || printf '%s | @chain %s\n' "$_bm" "$_bm" >> "$FAVORITES_FILE"
    done < "$BOOKMARKS_FILE"
    unset _bm
    mv "$BOOKMARKS_FILE" "$BOOKMARKS_FILE.migrated"
fi

if [[ ! -f "$DESKTOP_FILE" ]]; then
    mkdir -p "$DESKTOP_DIR"
    cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=Fabric Menu
Comment=Launch Fabric AI patterns on active text selections, URLs, and YouTube links
Exec=$SCRIPT_PATH
Icon=utilities-terminal
Type=Application
Terminal=false
Categories=Utility;System;AI;
StartupNotify=false
Keywords=fabric;ai;prompt;pattern;
EOF
    chmod 644 "$DESKTOP_FILE"
fi

# ==============================================================================
# 2. LOAD CONFIGURATION
# ==============================================================================
_load_defaults
_read_config_file "$CONFIG_FILE"
# Older versions used 'auto' and 'primary'; both mean "highlight" now.
case "$CAPTURE_MODE" in auto|primary|"") CAPTURE_MODE="highlight" ;; esac

# Parse --dry-run / -d flag.
DRY_RUN=false
for _arg in "$@"; do
    [[ "$_arg" == "--dry-run" || "$_arg" == "-d" ]] && DRY_RUN=true && break
done
unset _arg

[[ "$DRY_RUN" == false ]] && mkdir -p "$OUTPUT_DIR"

# ==============================================================================
# 3. RESOLVE SYSTEM DEPENDENCIES
# ==============================================================================

# -- Fabric binary --
if [[ "$FABRIC_CMD" == "auto" || -z "$FABRIC_CMD" ]]; then
    if   command -v fabric-ai &>/dev/null; then FABRIC_CMD_RESOLVED="fabric-ai"
    elif command -v fabric    &>/dev/null; then FABRIC_CMD_RESOLVED="fabric"
    else
        echo "Error: fabric CLI not found. Install 'fabric-ai' or 'fabric'." >&2
        if [[ "$NOTIFICATIONS" == "true" ]] && command -v notify-send &>/dev/null; then
            notify-send "Fabric Menu" "Error: fabric CLI not found." -i dialog-error
        fi
        exit 1
    fi
else
    FABRIC_CMD_RESOLVED="$FABRIC_CMD"
fi

# -- Menu tool --
if [[ "$MENU_TOOL" == "auto" || -z "$MENU_TOOL" ]]; then
    if   command -v rofi &>/dev/null; then MENU_TOOL_RESOLVED="rofi"
    elif command -v wofi &>/dev/null; then MENU_TOOL_RESOLVED="wofi"
    else
        echo "Error: neither 'rofi' nor 'wofi' found." >&2
        exit 1
    fi
else
    MENU_TOOL_RESOLVED="$MENU_TOOL"
fi

# -- Clipboard tool --
CLIPBOARD_TOOL_RESOLVED=""
if [[ "$CLIPBOARD_TOOL" == "auto" || -z "$CLIPBOARD_TOOL" ]]; then
    if   [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-paste &>/dev/null; then
        CLIPBOARD_TOOL_RESOLVED="wl-clipboard"
    elif command -v xclip    &>/dev/null; then CLIPBOARD_TOOL_RESOLVED="xclip"
    elif command -v wl-paste &>/dev/null; then CLIPBOARD_TOOL_RESOLVED="wl-clipboard"
    else
        echo "Warning: no clipboard tool found; results won't be auto-copied." >&2
    fi
else
    CLIPBOARD_TOOL_RESOLVED="$CLIPBOARD_TOOL"
fi

# ==============================================================================
# 4. HELPER FUNCTIONS
# ==============================================================================

send_notification() {
    [[ "$NOTIFICATIONS" != "true" ]] && return
    command -v notify-send &>/dev/null || return
    local title="$1" body="$2" icon="${3:-dialog-information}" timeout="${4:-3000}"
    notify-send "$title" "$body" -i "$icon" -t "$timeout"
}

copy_to_clipboard() {
    local text="$1"
    [[ -z "$text" ]] && return
    case "$CLIPBOARD_TOOL_RESOLVED" in
        wl-clipboard) printf '%s' "$text" | wl-copy ;;
        xclip)        printf '%s' "$text" | xclip -selection clipboard ;;
    esac
}

run_menu() {
    local prompt="$1" items="$2" mesg="$3" prefill="${4:-}"
    if [[ "$MENU_TOOL_RESOLVED" == "rofi" ]]; then
        local -a theme_args=() extra=()
        [[ -n "$ROFI_THEME" ]] && theme_args=(-theme "$ROFI_THEME")
        [[ -n "$prefill" ]] && extra=(-filter "$prefill")
        printf '%s' "$items" | rofi -dmenu -i -p "$prompt" -mesg "$mesg" \
            "${extra[@]}" "${theme_args[@]}" -theme-str 'window {width: 80%;} listview {lines: 12; fixed: false;} element-text {wrap: true; ellipsize: none;}'
    else
        local -a extra=()
        [[ -n "$prefill" ]] && extra=(--search "$prefill")
        printf '%s' "$items" | wofi --dmenu --prompt "$prompt ($mesg)" --width 40% --lines 12 "${extra[@]}"
    fi
}

# Settings menu: every setting from the table, edited in place.
_settings_menu() {
    local -a ui_keys
    while true; do
        local items="" k val lines=() i
        ui_keys=()
        for k in "${SETTING_KEYS[@]}"; do
            val="${!k}"; [[ -z "$val" ]] && val="(default)"
            lines+=( "${SETTING_LABEL[$k]}: $val" )
            ui_keys+=( "$k" )
        done
        items=$(printf '%s\n' "${lines[@]}")$'\n'"↩️  Back"
        local choice
        choice=$(run_menu "Settings" "$items" "Select a setting to change. Menu/clipboard program changes apply next time you start.")
        [[ -z "$choice" || "$choice" == "↩️  Back" ]] && return 0

        k=""
        for i in "${!lines[@]}"; do [[ "${lines[$i]}" == "$choice" ]] && k="${ui_keys[$i]}"; done
        [[ -z "$k" ]] && continue

        local type="${SETTING_TYPE[$k]}" cur="${!k}" new="" opts=""
        case "$type" in
            bool)
                [[ "$cur" == "true" ]] && new="false" || new="true"
                if [[ "$k" == CUSTOM_COMMANDS && "$new" == "true" ]]; then
                    local ok
                    ok=$(run_menu "Enable custom commands?" $'✅ Yes, I understand the risk\n❌ Cancel' "⚠️ Custom commands run any shell command you type, with your own permissions. A wrong command (for example rm) can damage your system or delete files. Only enable this if you are comfortable with that.")
                    [[ "$ok" == "✅ Yes, I understand the risk" ]] || continue
                fi
                ;;
            enum:*)
                opts="${type#enum:}"; opts="${opts//,/$'\n'}"
                new=$(run_menu "${SETTING_LABEL[$k]}" "$opts" "${SETTING_DESC[$k]} Current: $cur")
                ;;
            lang)
                new=$(run_menu "${SETTING_LABEL[$k]}" $'🚫 None (Fabric default)\nnl-x-dutch\nen\nfr\nde\nes\n✏️  Other...' "${SETTING_DESC[$k]}")
                case "$new" in
                    "🚫 None (Fabric default)") new="__NONE__" ;;
                    "✏️  Other...") new=$(run_menu "Language code:" "" "e.g. it, pt, ja" "$cur") ;;
                esac
                ;;
            model)
                send_notification "$APP_NAME" "Loading available models..." "view-refresh"
                opts=$("$FABRIC_CMD_RESOLVED" --listmodels 2>/dev/null | grep -v '^$' || true)
                new=$(run_menu "${SETTING_LABEL[$k]}" $'🚫 None (Fabric default)\n'"$opts" "${SETTING_DESC[$k]}")
                [[ "$new" == "🚫 None (Fabric default)" ]] && new="__NONE__"
                ;;
            strategy)
                opts=$("$FABRIC_CMD_RESOLVED" --liststrategies 2>/dev/null \
                       | grep -E '^[[:space:]]+-[[:space:]][a-zA-Z0-9_-]+' | sed 's/^[[:space:]]*-[[:space:]]*//' || true)
                [[ -z "$opts" ]] && opts=$'cot\ncod\ntot\naot\nreflexion\nstandard'
                new=$(run_menu "${SETTING_LABEL[$k]}" $'🚫 None\n'"$opts" "${SETTING_DESC[$k]}")
                [[ "$new" == "🚫 None" ]] && new="__NONE__"
                ;;
            *)  # text
                new=$(run_menu "${SETTING_LABEL[$k]}:" "" "${SETTING_DESC[$k]} Enter - to reset to the default." "$cur")
                [[ "$k" == OUTPUT_DIR || "$k" == ROFI_THEME ]] && new=$(_expand_home "$new")
                ;;
        esac
        # An empty answer means "cancelled": keep the old value.
        [[ -z "$new" ]] && continue
        if [[ "$new" == "__NONE__" ]]; then new=""; fi
        if [[ "$type" == text && "$new" == "-" ]]; then
            new="${SETTING_DEFAULT[$k]}"; [[ "$k" == OUTPUT_DIR ]] && new=$(_expand_home "$new")
        fi
        set_setting "$k" "$new"
    done
}

# Copy a locally-bundled pattern into ~/.config/fabric/custom_patterns if missing.
_ensure_pattern_installed() {
    local pat="$1"
    [[ -z "$pat" ]] && return
    local repo_pat_dir="${SCRIPT_PATH%/*}/patterns/$pat"
    local custom_base="$HOME/.config/fabric/custom_patterns"
    local custom_pat_dir="$custom_base/$pat"
    if [[ -d "$repo_pat_dir" && ! -d "$custom_pat_dir" ]]; then
        mkdir -p "$custom_base"
        cp -r "$repo_pat_dir" "$custom_pat_dir"
        send_notification "Fabric Menu" "Installed bundled pattern '$pat'." "dialog-information"
    fi
}

# Render a Markmap-compatible Markdown result into a standalone HTML file and
# open it in the default browser. No Node.js/npm required (CDN libs).
# Uses markmap-lib/view directly (instead of the autoloader) so we control the
# initial zoom: fit the tree but never shrink below a readable minimum scale.
# The HTML/CSS/JS view itself lives in templates/email-flow.html (edit it there).
open_markmap_browser() {
    local markdown="$1"
    [[ -z "$markdown" ]] && return 1

    local template_file="${SCRIPT_PATH%/*}/templates/email-flow.html"
    [[ -f "$template_file" ]] || { echo "Missing template: $template_file" >&2; return 1; }

    local html_file md_tmp
    html_file=$(mktemp /tmp/fabric-email-flow-XXXXXX.html 2>/dev/null)
    md_tmp=$(mktemp /tmp/fabric-email-flow-XXXXXX.md 2>/dev/null)
    [[ -z "$html_file" || -z "$md_tmp" ]] && return 1

    # Guard against a '</script>' sequence inside the markdown breaking the page.
    printf '%s\n' "${markdown//<\/script/<\\/script}" > "$md_tmp"

    # Splice the markdown into the template at the __FABRIC_MARKDOWN__ placeholder.
    # awk reads the markdown via getline so $, /, &, and quotes never get mangled.
    awk -v md="$md_tmp" '
        $0 == "__FABRIC_MARKDOWN__" { while ((getline line < md) > 0) print line; close(md); next }
        { print }
    ' "$template_file" > "$html_file"
    rm -f "$md_tmp"

    if command -v xdg-open &>/dev/null; then
        xdg-open "$html_file" >/dev/null 2>&1 &
    elif command -v firefox &>/dev/null; then
        firefox "$html_file" >/dev/null 2>&1 &
    elif command -v chromium &>/dev/null; then
        chromium "$html_file" >/dev/null 2>&1 &
    elif command -v brave &>/dev/null; then
        brave "$html_file" >/dev/null 2>&1 &
    else
        echo "Warning: no browser found to open $html_file" >&2
        return 1
    fi
    send_notification "Fabric Menu" "Opened Markmap view in browser." "applications-internet"
}

# Favorites helpers. A favorite line is "name | template".
# A template starting with "@chain " lists patterns to run through the normal flow.
_fav_template() {   # name -> prints template, returns 1 if not found
    local name="$1" line lname
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# || -z "${line// /}" || "$line" != *"|"* ]] && continue
        lname="${line%% | *}"
        lname="${lname#"${lname%%[![:space:]]*}"}"
        lname="${lname%"${lname##*[![:space:]]}"}"
        if [[ "$lname" == "$name" ]]; then printf '%s' "${line#* | }"; return 0; fi
    done < "$FAVORITES_FILE"
    return 1
}

_remove_favorite() {   # name
    local name="$1" line tmp="$CONFIG_DIR/favorites.tmp"
    while IFS= read -r line; do
        [[ "${line%% | *}" != "$name" ]] && printf '%s\n' "$line"
    done < "$FAVORITES_FILE" > "$tmp"
    mv "$tmp" "$FAVORITES_FILE"
}

_add_favorite() {   # name template (replaces a favorite with the same name)
    _fav_template "$1" >/dev/null && _remove_favorite "$1"
    printf '%s | %s\n' "$1" "$2" >> "$FAVORITES_FILE"
    {
        grep '^#' "$FAVORITES_FILE" 2>/dev/null
        grep -v -e '^#' -e '^$' "$FAVORITES_FILE" | sort -u
    } > "$CONFIG_DIR/favorites.tmp"
    mv "$CONFIG_DIR/favorites.tmp" "$FAVORITES_FILE"
}

# Turn a favorite into PIPE_CHAIN entries (appended to the array named $2).
_favorite_to_chain() {   # name arrayname
    local name="$1" tpl p
    local -n _out="$2"
    tpl=$(_fav_template "$name") || return 1
    if [[ "$tpl" == "@chain "* ]]; then
        for p in ${tpl#@chain }; do _out+=( "PAT:$p" ); done
    else
        _out+=( "FAV:${name}|${tpl}" )
    fi
}

# ==============================================================================
# 5. PATTERN DISCOVERY  (result cached in PATTERNS_ARRAY)
# ==============================================================================
declare -a PATTERNS_ARRAY=()

_discover_patterns() {
    [[ ${#PATTERNS_ARRAY[@]} -gt 0 ]] && return   # already loaded this session

    local patterns_dir="$HOME/.config/fabric/patterns"
    local custom_dir="$HOME/.config/fabric/custom_patterns"
    local repo_dir="${SCRIPT_PATH%/*}/patterns"
    local all=""

    if [[ -d "$patterns_dir" ]]; then
        all=$(find "$patterns_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
    else
        all=$("$FABRIC_CMD_RESOLVED" --listpatterns 2>/dev/null \
              | grep -E '^[[:space:]]+-[[:space:]][a-zA-Z0-9_-]+' \
              | sed 's/^[[:space:]]*-[[:space:]]*//')
    fi

    if [[ -d "$custom_dir" ]]; then
        local custom
        custom=$(find "$custom_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
        [[ -n "$custom" ]] && all="${all}${all:+$'\n'}${custom}"
    fi

    # Local repository patterns (bundled with this script)
    if [[ -d "$repo_dir" ]]; then
        local repo
        repo=$(find "$repo_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
        [[ -n "$repo" ]] && all="${all}${all:+$'\n'}${repo}"
    fi

    # Read directly into array, filtering empty lines
    mapfile -t PATTERNS_ARRAY < <(printf '%s\n' "$all" | sort -u | grep -v '^$')

    if [[ ${#PATTERNS_ARRAY[@]} -eq 0 ]]; then
        echo "Error: no Fabric patterns found. Run 'fabric --updatepatterns'." >&2
        send_notification "Fabric Menu" "No patterns found! Run fabric --updatepatterns." "dialog-error"
        exit 1
    fi
}

build_patterns_menu() {
    _discover_patterns

    local -a regular=() fav_section=()

    # Favorites section
    if [[ -f "$FAVORITES_FILE" ]]; then
        mapfile -t fav_lines < "$FAVORITES_FILE"
        for line in "${fav_lines[@]}"; do
            [[ "$line" =~ ^[[:space:]]*# || -z "${line// /}" || "$line" != *"|"* ]] && continue
            local fname="${line%% | *}"
            fname="${fname#"${fname%%[![:space:]]*}"}"   # ltrim
            fname="${fname%"${fname##*[![:space:]]}"}"   # rtrim
            [[ -n "$fname" ]] && fav_section+=("⭐ $fname")
        done
        if ((${#fav_section[@]} > 0)); then
            fav_section+=("────────────────────────────────────────────")
        fi
    fi

    # Process patterns
    for p in "${PATTERNS_ARRAY[@]}"; do
        [[ -z "$p" ]] && continue
        regular+=("$p")
    done

    # Combine and print
    local -a final_menu=("${fav_section[@]}" "${regular[@]}")
    printf '%s\n' "${final_menu[@]}"
}

# ==============================================================================
# 6. CAPTURE SELECTION / INPUT
# ==============================================================================
SELECTION=""

# Read one selection buffer ("primary" = highlighted text, "clipboard").
_read_buffer() {
    local buf="$1" out=""
    case "$CLIPBOARD_TOOL_RESOLVED" in
        wl-clipboard)
            if [[ "$buf" == primary ]]; then
                out=$(wl-paste --no-newline --primary 2>/dev/null || true)
            else
                out=$(wl-paste --no-newline 2>/dev/null || true)
            fi
            ;;
        xclip)
            out=$(xclip -selection "$buf" -o 2>/dev/null || true)
            ;;
    esac
    # wl-paste prints this when the buffer is empty on some versions.
    [[ "$out" == "Nothing is copied" ]] && out=""
    printf '%s' "$out"
}

# Ask the focused app to copy its selection (Wayland: wtype or ydotool).
_press_copy() {
    if command -v wtype &>/dev/null; then
        wtype -M ctrl -k c -m ctrl 2>/dev/null
    elif command -v ydotool &>/dev/null; then
        ydotool key 29:1 46:1 46:0 29:0 2>/dev/null   # Ctrl down, C down/up, Ctrl up
    else
        return 1
    fi
}

capture_selection() {
    case "$CAPTURE_MODE" in
        clipboard) SELECTION=$(_read_buffer clipboard) ;;
        copy-keystroke)
            local before i
            before=$(_read_buffer clipboard)
            # Let go of the shortcut keys first: if Super/Alt are still held, the app
            # would see Super+Ctrl+C instead of Ctrl+C.
            sleep 0.25
            if _press_copy; then
                # Wait (up to ~1 s) for the app to put the selection on the clipboard.
                SELECTION="$before"
                for i in 1 2 3 4 5 6 7 8 9 10; do
                    sleep 0.1
                    SELECTION=$(_read_buffer clipboard)
                    [[ "$SELECTION" != "$before" ]] && break
                done
                # Nothing new copied: fall back to a highlighted selection.
                if [[ "$SELECTION" == "$before" ]]; then
                    local prim
                    prim=$(_read_buffer primary)
                    [[ -n "$prim" ]] && SELECTION="$prim"
                fi
            else
                echo "Warning: CAPTURE_MODE=copy-keystroke needs 'wtype' or 'ydotool'." >&2
                SELECTION="$before"
            fi
            ;;
        *)  # highlight
            SELECTION=$(_read_buffer primary)
            [[ -z "$SELECTION" ]] && SELECTION=$(_read_buffer clipboard)
            ;;
    esac
}

capture_selection

if [[ -n "$SELECTION" ]]; then
    # Pure bash preview formatting (no forks)
    NOTIFY_PREVIEW="${SELECTION//$'\n'/}"
    NOTIFY_PREVIEW="${NOTIFY_PREVIEW//$'\r'/}"
    NOTIFY_PREVIEW="${NOTIFY_PREVIEW:0:100}"
    send_notification "Captured Input" "$NOTIFY_PREVIEW" "edit-select"
fi

if [[ -z "$SELECTION" ]]; then
    if [[ "$MENU_TOOL_RESOLVED" == "rofi" ]]; then
        theme_args=()
        [[ -n "$ROFI_THEME" ]] && theme_args=(-theme "$ROFI_THEME")
        SELECTION=$(rofi -dmenu -p "No selection — enter input:" \
                         "${theme_args[@]}" -theme-str 'window {width: 80%;} listview {fixed: false;} element-text {wrap: true; ellipsize: none;}')
    else
        SELECTION=$(wofi --dmenu --prompt "No selection — enter input:" --width 40%)
    fi
    [[ -z "$SELECTION" ]] && { echo "No input provided. Exiting."; exit 0; }
fi

# ==============================================================================
# 7. CLASSIFY INPUT  (YouTube / URL / plain text)
# ==============================================================================
IS_YOUTUBE=false
IS_URL=false

# Pure bash preview
INPUT_PREVIEW="${SELECTION//$'\n'/}"
INPUT_PREVIEW="${INPUT_PREVIEW//$'\r'/}"
INPUT_PREVIEW="${INPUT_PREVIEW:0:80}"

if [[ "$SELECTION" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/ ]]; then
    IS_YOUTUBE=true
    INPUT_DESC="📺 $INPUT_PREVIEW"
elif [[ "$SELECTION" =~ ^https?:// ]]; then
    IS_URL=true
    INPUT_DESC="🌐 $INPUT_PREVIEW"
else
    char_count=${#SELECTION}
    # Use bash substitution outside of $(()) to avoid ANSI-C quoting issues
    stripped="${SELECTION//$'\n'/}"
    newline_count=$(( char_count - ${#stripped} ))
    preview="${SELECTION:0:60}"
    preview="${preview//$'\n'/ }"
    if (( char_count > 60 )) || (( newline_count > 0 )); then
        preview="${preview}..."
    fi
    INPUT_DESC="📝 Plain Text: \"${preview}\" ($char_count chars)"
fi

# ==============================================================================
# 8. RESULT HANDLING
# ==============================================================================
CMD_LOG=""
OUTPUT_FILE=""

# Some models wrap the whole answer in a ```markdown ... ``` fence. If the very
# first and last non-empty lines are a plain/markdown fence pair, drop both.
# Fences that carry a real language (```bash ...) or sit mid-text are untouched.
strip_code_fence() {
    local text="$1"
    local -a lines
    mapfile -t lines <<< "$text"
    local first=0 last=$(( ${#lines[@]} - 1 ))
    while (( first <= last )) && [[ -z "${lines[first]//[[:space:]]/}" ]]; do ((first++)); done
    while (( last > first )) && [[ -z "${lines[last]//[[:space:]]/}" ]]; do ((last--)); done
    if (( last > first )) \
       && [[ "${lines[first]}" =~ ^[[:space:]]*\`\`\`[[:space:]]*(markdown|md|text|plaintext)?[[:space:]]*$ ]] \
       && [[ "${lines[last]}" =~ ^[[:space:]]*\`\`\`[[:space:]]*$ ]]; then
        local i
        for (( i = first + 1; i < last; i++ )); do printf '%s\n' "${lines[i]}"; done
    else
        printf '%s' "$text"
    fi
}

handle_result() {
    local exit_code="$1" result="$2"

    if (( exit_code != 0 )); then
        echo "Fabric failed (exit $exit_code)." >&2
        printf 'Command: %s\n' "$CMD_LOG" >&2
        printf '%s\n' "$result" >&2
        send_notification "Fabric Failure" "Exit code: $exit_code" "dialog-error"

        if [[ "$MENU_TOOL_RESOLVED" == "rofi" ]]; then
            local copy_cmd="📋 [Copy Command to Clipboard]"
            local copy_err="📋 [Copy Error Output to Clipboard]"
            local close_item="─── Close ───"
            while true; do
                local err_items="${copy_cmd}"$'\n'"${copy_err}"$'\n'"${close_item}"$'\n'"❌ Exit code: $exit_code"$'\n\n'"Command:"$'\n'"$CMD_LOG"$'\n\n'"Error:"$'\n'"$result"
                local err_choice
                local theme_args=()
                [[ -n "$ROFI_THEME" ]] && theme_args=(-theme "$ROFI_THEME")

                err_choice=$(printf '%s' "$err_items" | rofi -dmenu -i -p "Fabric Error" \
                    "${theme_args[@]}" -theme-str 'window {width: 90%;} listview {lines: 15; fixed: false;} element-text {wrap: true; ellipsize: none;}')
                [[ -z "$err_choice" || "$err_choice" == "$close_item" ]] && break
                case "$err_choice" in
                    "$copy_cmd") copy_to_clipboard "$CMD_LOG"; send_notification "Copied" "Command copied" "edit-copy" ;;
                    "$copy_err") copy_to_clipboard "$result";  send_notification "Copied" "Error output copied" "edit-copy" ;;
                esac
            done
        fi
        exit "$exit_code"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        printf '%s\n' "$result"
        send_notification "Fabric Dry Run" "Dry-run output printed to terminal." "dialog-information"
        exit 0
    fi

    if [[ -n "$result" && "$STRIP_CODE_FENCE" == "true" ]]; then
        result=$(strip_code_fence "$result")
    fi

    if [[ -n "$result" ]]; then
        copy_to_clipboard "$result"

        local msg="Result copied to clipboard!"
        [[ -n "$OUTPUT_FILE" ]] && msg="Saved to ${OUTPUT_FILE##*/} & copied to clipboard!"
        send_notification "Fabric Success" "$msg" "dialog-ok"

        # The mind map opens only for the dedicated "Email Flow" menu entry.
        if [[ "$EMAIL_FLOW_MODE" == true ]]; then
            open_markmap_browser "$result"
        fi

        # When the markmap view is used, skip the text preview window entirely.
        if [[ "$EMAIL_FLOW_MODE" != true && "$SHOW_PREVIEW" == "true" ]]; then
            local tmp_file
            tmp_file=$(mktemp /tmp/fabric-preview-XXXXXX.txt 2>/dev/null)
            if [[ -n "$tmp_file" ]]; then
                printf '%s\n' "$result" > "$tmp_file"

                local preview_err=""
                if [[ "$MENU_TOOL_RESOLVED" == "rofi" ]]; then
                    local theme_args=()
                    [[ -n "$ROFI_THEME" ]] && theme_args=(-theme "$ROFI_THEME")
                    preview_err=$(fold -s -w 100 < "$tmp_file" | rofi -dmenu -i -p "Result Preview" "${theme_args[@]}" -theme-str 'window {width: 80%;} listview {lines: 20; fixed: false;} element-text {wrap: true; ellipsize: none;}' 2>&1)
                elif [[ "$MENU_TOOL_RESOLVED" == "wofi" ]]; then
                    preview_err=$(fold -s -w 100 < "$tmp_file" | wofi --show dmenu -p "Result Preview" 2>&1)
                elif command -v kdialog >/dev/null 2>&1; then
                    preview_err=$(kdialog --title "Fabric Result Preview" --textbox "$tmp_file" 800 600 2>&1)
                elif command -v zenity >/dev/null 2>&1; then
                    preview_err=$(zenity --text-info --title="Fabric Result Preview" --filename="$tmp_file" --width=800 --height=600 2>&1)
                fi

                if [[ -n "$preview_err" ]]; then
                    echo "Preview Error: $preview_err" >&2
                    send_notification "Preview Failed" "$preview_err" "dialog-warning"
                fi
                rm -f "$tmp_file"
            fi
        fi
    else
        send_notification "Fabric Finished" "Ran successfully but returned empty output." "dialog-warning"
    fi
    exit 0
}

_run_and_handle() {
    local result exit_code=0
    set +o pipefail
    result=$(eval "$CMD_LOG" 2>&1) || exit_code=$?
    set -o pipefail
    handle_result "$exit_code" "$result"
}


# ==============================================================================
# 9. PATTERN SELECTION LOOP
# ==============================================================================
PIPE_CHAIN=()
EMAIL_FLOW_MODE=false

_pattern_menu_loop() {
    while true; do
        local patterns_menu
        patterns_menu=$(build_patterns_menu)

        local settings_item="⚙️  Settings..."
        local custom_cmd_item="✏️  Custom Command..."
        local delete_fav_item="🗑️  Delete Favorite..."
        local email_flow_item="📧  [Email Flow → Markmap View]"

        local menu_items="${email_flow_item}"
        [[ "$CUSTOM_COMMANDS" == "true" ]] && menu_items+=$'\n'"${custom_cmd_item}"

        if grep -v -e '^#' -e '^[[:space:]]*$' "$FAVORITES_FILE" 2>/dev/null | grep -q '|'; then
            menu_items+=$'\n'"${delete_fav_item}"
        fi
        menu_items+=$'\n'"${settings_item}"$'\n'"${patterns_menu}"

        local choice
        choice=$(run_menu "Select Pattern" "$menu_items" "$INPUT_DESC")
        [[ -z "$choice" ]] && { echo "Cancelled."; exit 0; }

        case "$choice" in
            "$email_flow_item")
                EMAIL_FLOW_MODE=true
                PIPE_CHAIN=( "PAT:email_flow" )
                return 0
                ;;
            "$settings_item")
                _settings_menu
                ;;
            "$custom_cmd_item")
                local tpl
                tpl=$(run_menu "Enter command ({{INPUT}} = captured text):" "" \
                               "⚠️ Runs as a shell command with YOUR permissions: a wrong command (e.g. rm) can damage your system. e.g. echo {{INPUT}} | fabric -p summarize")
                [[ -z "$tpl" ]] && continue

                local save_choice
                save_choice=$(run_menu "Save this command?" "🚀 Run Only"$'\n'"💾 Save as Favorite & Run" "Command: $tpl")
                if [[ "$save_choice" == "💾 Save as Favorite & Run" ]]; then
                    local fav_name
                    fav_name=$(run_menu "Name for this favorite:" "" "e.g. Custom API Request")
                    if [[ -n "$fav_name" ]]; then
                        _add_favorite "$fav_name" "$tpl"
                        send_notification "Fabric Menu" "Saved favorite: $fav_name" "bookmark-new"
                        PIPE_CHAIN=( "FAV:${fav_name}|${tpl}" )
                    else
                        PIPE_CHAIN=( "FAV:Custom Command|${tpl}" )
                    fi
                else
                    PIPE_CHAIN=( "FAV:Custom Command|${tpl}" )
                fi
                return 0
                ;;
            "$delete_fav_item")
                local fav_names
                fav_names=$(grep -v -e '^#' -e '^[[:space:]]*$' "$FAVORITES_FILE" | grep '|' \
                            | sed 's/ |.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')
                [[ -z "$fav_names" ]] && {
                    send_notification "Fabric Menu" "No favorites to delete." "dialog-information"
                    continue
                }
                local to_del
                to_del=$(run_menu "Select favorite to delete" "$fav_names" "Choose one to remove")
                if [[ -n "$to_del" ]]; then
                    _remove_favorite "$to_del"
                    send_notification "Fabric Menu" "Deleted: $to_del" "user-trash"
                fi
                ;;
            "⭐ "*)
                PIPE_CHAIN=()
                if ! _favorite_to_chain "${choice#⭐ }" PIPE_CHAIN; then
                    send_notification "Fabric Menu" "Favorite not found: ${choice#⭐ }" "dialog-error"
                    continue
                fi
                return 0
                ;;
            *)
                PIPE_CHAIN=( "PAT:$choice" )
                return 0
                ;;
        esac
    done
}

# ==============================================================================
# 10. OPTIONS SUBMENU
# ==============================================================================
SELECTED_LANG=""
SELECTED_MODEL=""
SELECTED_STRATEGY=""
SELECTED_CONTEXT=""
SELECTED_CUSTOM_ARGS=""

_chain_display() {
    local -a display_arr=()
    for item in "${PIPE_CHAIN[@]}"; do
        if [[ "$item" == PAT:* ]]; then
            display_arr+=( "${item#PAT:}" )
        elif [[ "$item" == FAV:* ]]; then
            local fav_data="${item#FAV:}"
            display_arr+=( "⭐ ${fav_data%%|*}" )
        else
            display_arr+=( "$item" )
        fi
    done
    local IFS=' | '
    printf '%s' "${display_arr[*]}"
}

_build_command_string() {
    local eff_lang="${SELECTED_LANG:-${DEFAULT_LANG:-}}"
    local eff_model="${SELECTED_MODEL:-${DEFAULT_MODEL:-}}"
    local eff_strat="${SELECTED_STRATEGY:-${DEFAULT_STRATEGY:-}}"

    # Escape inputs for safe eval injection
    local esc_lang="${eff_lang//\"/\\\"}"
    local esc_model="${eff_model//\"/\\\"}"
    local esc_strat="${eff_strat//\"/\\\"}"
    local esc_ctx="${SELECTED_CONTEXT//\"/\\\"}"
    local esc_custom="${SELECTED_CUSTOM_ARGS//\"/\\\"}"
    local esc_file="${OUTPUT_FILE//\"/\\\"}"

    local lang_arg="" other_args=""
    [[ -n "$eff_lang"  ]] && lang_arg=" -g \"$esc_lang\""
    [[ -n "$eff_model" ]] && other_args+=" -m \"$esc_model\""
    [[ -n "$eff_strat" ]] && other_args+=" --strategy \"$esc_strat\""
    [[ -n "$SELECTED_CONTEXT" ]] && other_args+=" -C \"$esc_ctx\""
    [[ -n "$SELECTED_CUSTOM_ARGS" ]] && other_args+=" $esc_custom"

    local output_arg=""
    [[ -n "$OUTPUT_FILE" ]] && output_arg=" -o \"$esc_file\""

    local dry_arg=""
    [[ "$DRY_RUN" == true ]] && dry_arg=" --dry-run"

    local pipe_cmd=""
    local last_idx=$(( ${#PIPE_CHAIN[@]} - 1 ))
    local i
    for i in "${!PIPE_CHAIN[@]}"; do
        local item="${PIPE_CHAIN[$i]}"
        local stage_extra="${other_args}${dry_arg}"
        (( i == last_idx )) && stage_extra+="$output_arg"

        if [[ "$item" == PAT:* ]]; then
            local pat="${item#PAT:}"
            _ensure_pattern_installed "$pat"
            if (( i == 0 )); then
                if   [[ "$IS_YOUTUBE" == true ]]; then
                    pipe_cmd="$FABRIC_CMD_RESOLVED${lang_arg} -y \"\$FABRIC_MENU_INPUT\" | $FABRIC_CMD_RESOLVED${lang_arg} -p \"$pat\"${stage_extra}"
                elif [[ "$IS_URL"     == true ]]; then
                    pipe_cmd="$FABRIC_CMD_RESOLVED${lang_arg} -u \"\$FABRIC_MENU_INPUT\" | $FABRIC_CMD_RESOLVED${lang_arg} -p \"$pat\"${stage_extra}"
                else
                    pipe_cmd="printf '%s' \"\$FABRIC_MENU_INPUT\" | $FABRIC_CMD_RESOLVED${lang_arg} -p \"$pat\"${stage_extra}"
                fi
            else
                pipe_cmd+=" | $FABRIC_CMD_RESOLVED${lang_arg} -p \"$pat\"${stage_extra}"
            fi
        elif [[ "$item" == FAV:* ]]; then
            local fav_data="${item#FAV:}"
            local fav_tpl="${fav_data#*|}"
            local fav_extra="${lang_arg}${stage_extra}"
            
            if (( i == 0 )); then
                local parsed_tpl="${fav_tpl//\{\{INPUT\}\}/\$FABRIC_MENU_INPUT}"
                pipe_cmd="${parsed_tpl}${fav_extra}"
            else
                local parsed_tpl="$fav_tpl"
                if [[ "$parsed_tpl" == *"{{INPUT}}"*"|"* ]]; then
                    local prefix="${parsed_tpl%%|*}"
                    if [[ "$prefix" == *"echo"* || "$prefix" == *"printf"* ]] && [[ "$prefix" == *"{{INPUT}}"* ]]; then
                        parsed_tpl="${parsed_tpl#*|}"
                        parsed_tpl="${parsed_tpl#"${parsed_tpl%%[![:space:]]*}"}"
                    else
                        parsed_tpl="${parsed_tpl//\{\{INPUT\}\}/\$(cat)}"
                    fi
                else
                    parsed_tpl="${parsed_tpl//\{\{INPUT\}\}/\$(cat)}"
                fi
                pipe_cmd+=" | ${parsed_tpl}${fav_extra}"
            fi
        fi
    done

    printf '%s' "$pipe_cmd"
}

_options_submenu() {
    while true; do
        local chain_str
        chain_str=$(_chain_display)

        local lang_d="${SELECTED_LANG:-None}"
        local model_d="${SELECTED_MODEL:-Default}"
        local strat_d="${SELECTED_STRATEGY:-Default}"
        local ctx_d="${SELECTED_CONTEXT:-None}"
        local file_d="Clipboard Only"
        [[ -n "$OUTPUT_FILE" ]] && file_d=$(basename "$OUTPUT_FILE")

        local active="[Lang: $lang_d | Ctx: $ctx_d | File: $file_d | Model: $model_d | Strategy: $strat_d]"
        [[ -n "$SELECTED_CUSTOM_ARGS" ]] && active+=" [Params: $SELECTED_CUSTOM_ARGS]"

        local live_cmd
        live_cmd=$(_build_command_string)

        # Array-based menu generation (faster than cat << 'EOF')
        local -a submenu_items=(
            "🚀 [RUN NOW]"
            "📋 Copy Command to Clipboard"
            "🧩 Pipe to Another Pattern"
            "🌐 Select Language..."
            "📂 Choose Context..."
            "⚙️  Add Custom Parameters..."
            "💾 Save output to Markdown file..."
            "🤖 Choose Custom Model..."
            "🧠 Choose Prompt Strategy..."
            "⭐ Save as Favorite"
            "↩️  Back to Patterns Menu"
        )
        local submenu_str
        printf -v submenu_str '%s\n' "${submenu_items[@]}"

        local sub_choice
        sub_choice=$(run_menu "Chain: $chain_str" "$submenu_str" "$active"$'\n'"Cmd: $live_cmd")

        case "$sub_choice" in
            "🚀 [RUN NOW]") return 0 ;;
            "📋 Copy Command to Clipboard")
                copy_to_clipboard "$live_cmd"
                send_notification "Fabric Menu" "Command copied to clipboard!" "edit-copy"
                ;;
            "") echo "Cancelled."; exit 0 ;;
            "🧩 Pipe to Another Pattern")
                local pipe_menu next_pat raw_next
                pipe_menu=$(build_patterns_menu)
                next_pat=$(run_menu "Add to pipe" "$pipe_menu" "Current: $chain_str")
                if [[ -n "$next_pat" ]]; then
                    if [[ "$next_pat" == "⭐ "* ]]; then
                        local fname="${next_pat#⭐ }"
                        if _favorite_to_chain "$fname" PIPE_CHAIN; then
                            send_notification "Fabric Menu" "Appended favorite '$fname' to pipe" "go-next"
                        fi
                    else
                        raw_next="$next_pat"
                        PIPE_CHAIN+=( "PAT:$raw_next" )
                        send_notification "Fabric Menu" "Appended pattern '$raw_next' to pipe" "go-next"
                    fi
                fi
                ;;
            "🌐 Select Language...")
                local -a lang_items=(
                    "🇳🇱 Dutch (-g nl-x-dutch)"
                    "🇬🇧 English (-g en)"
                    "🌐 Custom Language Code..."
                    "🚫 Clear Language Selection"
                    "↩️  Back"
                )
                local lang_str; printf -v lang_str '%s\n' "${lang_items[@]}"
                local lang_choice custom_lang
                lang_choice=$(run_menu "Select Language" "$lang_str" "Current: $lang_d")
                case "$lang_choice" in
                    "🇳🇱 Dutch (-g nl-x-dutch)") SELECTED_LANG="nl-x-dutch" ;;
                    "🇬🇧 English (-g en)")        SELECTED_LANG="en" ;;
                    "🌐 Custom Language Code...")
                        custom_lang=$(run_menu "Language code (e.g. es, fr, de):" "" "Enter code")
                        [[ -n "$custom_lang" ]] && SELECTED_LANG="$custom_lang"
                        ;;
                    "🚫 Clear Language Selection") SELECTED_LANG="" ;;
                esac
                ;;
            "📂 Choose Context...")
                local contexts_dir="$HOME/.config/fabric/contexts"
                local ctx_list ctx_items ctx_choice
                if [[ -d "$contexts_dir" ]]; then
                    ctx_list=$(find "$contexts_dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true)
                fi
                if [[ -z "$ctx_list" ]]; then
                    ctx_list=$("$FABRIC_CMD_RESOLVED" --listcontexts 2>/dev/null \
                               | grep -E '^[[:space:]]+-[[:space:]][a-zA-Z0-9_-]+' \
                               | sed 's/^[[:space:]]*-[[:space:]]*//' || true)
                fi
                ctx_items="🚫 Reset to Default Context"$'\n'"$ctx_list"
                ctx_choice=$(run_menu "Select Context" "$ctx_items" "Current: $ctx_d")
                case "$ctx_choice" in
                    "🚫 Reset to Default Context" | "") SELECTED_CONTEXT="" ;;
                    *) [[ -n "$ctx_choice" ]] && SELECTED_CONTEXT="$ctx_choice" ;;
                esac
                ;;
            "⚙️  Add Custom Parameters...")
                local param_choice custom_args
                param_choice=$(run_menu "Custom Parameters" "✏️  Enter Custom Flags..."$'\n'"🚫 Clear Custom Flags" "Current: $SELECTED_CUSTOM_ARGS")
                case "$param_choice" in
                    "✏️  Enter Custom Flags...")
                        custom_args=$(run_menu "Enter custom flags:" "" "e.g. -t 0.5 --seed 123")
                        [[ -n "$custom_args" ]] && SELECTED_CUSTOM_ARGS="$custom_args"
                        ;;
                    "🚫 Clear Custom Flags") SELECTED_CUSTOM_ARGS="" ;;
                esac
                ;;
            "💾 Save output to Markdown file...")
                local save_dir="$OUTPUT_DIR" dir_choice custom_dir filename
                local -a dir_items=("📁 Default ($OUTPUT_DIR)" "📁 Browse custom directory..." "↩️  Back")
                local dir_str; printf -v dir_str '%s\n' "${dir_items[@]}"
                dir_choice=$(run_menu "Choose directory" "$dir_str" "")
                case "$dir_choice" in
                    "📁 Default ($OUTPUT_DIR)") ;;   # save_dir already set
                    "📁 Browse custom directory...")
                        custom_dir=$(run_menu "Absolute directory path:" "" "Leave empty to cancel")
                        [[ -n "$custom_dir" ]] && save_dir="$custom_dir"
                        ;;
                esac
                if [[ -n "$save_dir" ]]; then
                    mkdir -p "$save_dir"
                    filename=$(run_menu "Filename (no extension):" "" "Saving to: $save_dir/")
                    [[ -n "$filename" ]] && OUTPUT_FILE="$save_dir/${filename}.md"
                fi
                ;;
            "🤖 Choose Custom Model...")
                send_notification "Fabric Menu" "Loading available models..." "view-refresh"
                local models_list model_items model_choice
                models_list=$("$FABRIC_CMD_RESOLVED" --listmodels 2>/dev/null | grep -v '^$' || true)
                [[ -z "$models_list" ]] && \
                    models_list="openai/gpt-4o"$'\n'"anthropic/claude-sonnet-4-5"$'\n'"google/gemini-2.0-flash"$'\n'"ollama/llama3"

                model_items="🚫 Reset to Default Model"$'\n'"$models_list"
                model_choice=$(run_menu "Select Model" "$model_items" "Current: $model_d")
                case "$model_choice" in
                    "🚫 Reset to Default Model" | "") SELECTED_MODEL="" ;;
                    *) [[ -n "$model_choice" ]] && SELECTED_MODEL="$model_choice" ;;
                esac
                ;;
            "🧠 Choose Prompt Strategy...")
                local strategies_dir="$HOME/.config/fabric/strategies"
                local strat_list strat_items strat_choice
                if [[ -d "$strategies_dir" ]]; then
                    strat_list=$(find "$strategies_dir" -mindepth 1 -maxdepth 1 \
                                 -name "*.json" -printf '%f\n' | sed 's/\.json$//')
                else
                    strat_list=$("$FABRIC_CMD_RESOLVED" --liststrategies 2>/dev/null \
                                 | grep -E '^[[:space:]]+-[[:space:]][a-zA-Z0-9_-]+' \
                                 | sed 's/^[[:space:]]*-[[:space:]]*//' || true)
                fi
                [[ -z "$strat_list" ]] && \
                    strat_list="cot"$'\n'"cod"$'\n'"tot"$'\n'"aot"$'\n'"reflexion"$'\n'"standard"

                strat_items="🚫 Reset to Default Strategy"$'\n'"$strat_list"
                strat_choice=$(run_menu "Select Strategy" "$strat_items" "Current: $strat_d")
                case "$strat_choice" in
                    "🚫 Reset to Default Strategy" | "") SELECTED_STRATEGY="" ;;
                    *) [[ -n "$strat_choice" ]] && SELECTED_STRATEGY="$strat_choice" ;;
                esac
                ;;
            "⭐ Save as Favorite")
                local eff_lang="${SELECTED_LANG:-${DEFAULT_LANG:-}}"
                local eff_model="${SELECTED_MODEL:-${DEFAULT_MODEL:-}}"
                local eff_strat="${SELECTED_STRATEGY:-${DEFAULT_STRATEGY:-}}"
                local tl="" to=""
                [[ -n "$eff_lang"  ]] && tl=" -g \"$eff_lang\""
                [[ -n "$eff_model" ]] && to=" -m \"$eff_model\""
                [[ -n "$eff_strat" ]] && to+=" --strategy \"$eff_strat\""
                [[ -n "$SELECTED_CONTEXT" ]] && to+=" -C \"$SELECTED_CONTEXT\""
                [[ -n "$SELECTED_CUSTOM_ARGS" ]] && to+=" $SELECTED_CUSTOM_ARGS"

                local pipe_tpl="" all_pat=true i item
                for item in "${PIPE_CHAIN[@]}"; do [[ "$item" == PAT:* ]] || all_pat=false; done
                if [[ "$all_pat" == true && -z "$tl$to" ]]; then
                    # Plain pattern chain: keep it flexible (works for text, URLs, YouTube).
                    pipe_tpl="@chain"
                    for item in "${PIPE_CHAIN[@]}"; do pipe_tpl+=" ${item#PAT:}"; done
                fi
                for i in "${!PIPE_CHAIN[@]}"; do
                    [[ "$pipe_tpl" == "@chain"* ]] && break
                    item="${PIPE_CHAIN[$i]}"
                    if [[ "$item" == PAT:* ]]; then
                        local pat="${item#PAT:}"
                        if (( i == 0 )); then
                            if   [[ "$IS_YOUTUBE" == true ]]; then
                                pipe_tpl="$FABRIC_CMD_RESOLVED${tl} -y \"{{INPUT}}\" | $FABRIC_CMD_RESOLVED${tl} -p \"$pat\"${to}"
                            elif [[ "$IS_URL"     == true ]]; then
                                pipe_tpl="$FABRIC_CMD_RESOLVED${tl} -u \"{{INPUT}}\" | $FABRIC_CMD_RESOLVED${tl} -p \"$pat\"${to}"
                            else
                                pipe_tpl="printf '%s' \"{{INPUT}}\" | $FABRIC_CMD_RESOLVED${tl} -p \"$pat\"${to}"
                            fi
                        else
                            pipe_tpl+=" | $FABRIC_CMD_RESOLVED${tl} -p \"$pat\"${to}"
                        fi
                    elif [[ "$item" == FAV:* ]]; then
                        local fav_data="${item#FAV:}"
                        local fav_tpl="${fav_data#*|}"
                        local fav_to="${tl}${to}"
                        if (( i == 0 )); then
                            pipe_tpl="${fav_tpl}${fav_to}"
                        else
                            local parsed_tpl="$fav_tpl"
                            if [[ "$parsed_tpl" == *"{{INPUT}}"*"|"* ]]; then
                                local prefix="${parsed_tpl%%|*}"
                                if [[ "$prefix" == *"echo"* || "$prefix" == *"printf"* ]] && [[ "$prefix" == *"{{INPUT}}"* ]]; then
                                    parsed_tpl="${parsed_tpl#*|}"
                                    parsed_tpl="${parsed_tpl#"${parsed_tpl%%[![:space:]]*}"}"
                                else
                                    parsed_tpl="${parsed_tpl//\{\{INPUT\}\}/\$(cat)}"
                                fi
                            else
                                parsed_tpl="${parsed_tpl//\{\{INPUT\}\}/\$(cat)}"
                            fi
                            pipe_tpl+=" | ${parsed_tpl}${fav_to}"
                        fi
                    fi
                done

                local fav_name
                local suggestion="" sitem
                for sitem in "${PIPE_CHAIN[@]}"; do
                    if [[ "$sitem" == PAT:* ]]; then sitem="${sitem#PAT:}"; else sitem="${sitem#FAV:}"; sitem="${sitem%%|*}"; fi
                    suggestion+="${suggestion:+ + }$sitem"
                done
                fav_name=$(run_menu "Name for this favorite:" "" "Press Enter to accept, or edit the name. Same name replaces the old favorite." "$suggestion")
                if [[ -n "$fav_name" ]]; then
                    _add_favorite "$fav_name" "$pipe_tpl"
                    send_notification "Fabric Menu" "Saved favorite: $fav_name" "bookmark-new"
                fi
                ;;
            "↩️  Back to Patterns Menu")
                return 10  # Signal to go back to patterns menu
                ;;
        esac
    done
}

# ==============================================================================
# 11. BUILD & EXECUTE COMMAND
# ==============================================================================
_build_and_run() {
    CMD_LOG=$(_build_command_string)
    printf 'Executing: %s\n' "$CMD_LOG" >&2
    send_notification "Fabric AI" "Running: $(_chain_display)..." "edit"
    export FABRIC_MENU_INPUT="$SELECTION"
    _run_and_handle
}

# ==============================================================================
# MAIN EXECUTION LOOP
# ==============================================================================
main() {
    while true; do
        PIPE_CHAIN=()
        EMAIL_FLOW_MODE=false
        _pattern_menu_loop

        if [[ "$QUICK_RUN" == "true" ]]; then
            _build_and_run
            break
        fi

        local sub_ret
        _options_submenu
        sub_ret=$?

        case $sub_ret in
            0)  _build_and_run; break ;;  # Run Now
            10) continue ;;              # Back to Patterns Menu
            *)  exit 0 ;;                # Cancel or Exit
        esac
    done
}

main
