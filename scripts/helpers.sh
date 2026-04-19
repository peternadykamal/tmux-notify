#!/usr/bin/env bash
## -- Helper functions
# Additional functions that are used in the main scripts.

# Get tmux option
# Usage: get_tmux_option <option> <default_value>
get_tmux_option() {
  local option="$1"
  local default_value="$2"
  local option_value=$(tmux show-option -gqv "$option")
  if [ -z "$option_value" ]; then
    echo "$default_value"
  else
    echo "$option_value"
  fi
}

# Set tmux option
# Usage: set_tmux_option <option> <value>
set_tmux_option() {
  local option="$1"
  local value="$2"
  tmux set-option -gq "$option" "$value"
}

# Escape globbing charaters
# Usage: escape_glob_chars <string>
escape_glob_chars() {
  echo "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'
}

# Check if verbose option is enabled
verbose_enabled() {
  local verbose_value="$(get_tmux_option "$verbose_option" "$verbose_default")"
  [ "$verbose_value" == "on" ]
}

# Check if the telegram alert all option is enabled
telegram_all_enabled() {
  local alert_all="$(get_tmux_option "$tmux_notify_telegram_all" "$tmux_notify_telegram_all_default")"
  [ "$alert_all" == "on" ]
}

# Check if telegram bot id and chat id are set
telegram_available() {
  local telegram_id="$(get_tmux_option "$tmux_notify_telegram_bot_id" "$tmux_notify_telegram_bot_id_default")"
  local telegram_chat_id="$(get_tmux_option "$tmux_notify_telegram_channel_id" "$tmux_notify_telegram_channel_id_default")"
  [ -n "$telegram_id" ] && [ -n "$telegram_chat_id" ]
}

# Check if pushover token and pushover user are set
pushover_available() {
  local pushover_token="$(get_tmux_option "$tmux_notify_pushover_token" "$tmux_notify_pushover_token_default")"
  local pushover_user="$(get_tmux_option "$tmux_notify_pushover_user" "$tmux_notify_pushover_user_default")"
  [ -n "$pushover_token" ] && [ -n "$pushover_user" ]
}

# Send telegram message
# Usage: send_telegram_message <bot_id> <chat_id> <message>
send_telegram_message() {
  # Use POST with urlencoding: wget --spider sends HEAD, which does not deliver messages.
  # disable_notification=false keeps sound/badge behavior for normal chats (default, explicit for clarity).
  curl -sS -X POST "https://api.telegram.org/bot${1}/sendMessage" \
    --data-urlencode "chat_id=${2}" \
    --data-urlencode "text=${3}" \
    --data-urlencode "disable_notification=false" \
    &> /dev/null
}

# Send a message over https://pushover.net/
# Usage: send_pushover_message <token> <user_id> <title> <message>
# token is the application token on pushover.net
# user_id is the user or group id of whom will receive the notification
# the title of the message: https://pushover.net/api#registration
# message is the message sent
send_pushover_message() {
  curl -X POST --location "https://api.pushover.net/1/messages.json" \
    -H "Content-Type: application/json" \
    -d "{
            \"token\": \"$1\",
            \"user\": \"$2\",
            \"message\": \"$4\",
            \"title\": \"$3\"
        }" &> /dev/null
}

# Check if Ollama summary is enabled
ollama_enabled() {
  local ollama_value="$(get_tmux_option "$ollama_enabled" "$ollama_enabled_default")"
  [ "$ollama_value" == "on" ]
}

# Check if Ollama is available (URL is reachable)
ollama_available() {
  local ollama_url_value="$(get_tmux_option "$ollama_url" "$ollama_url_default")"
  curl -s --max-time 2 "$ollama_url_value" &> /dev/null
}

# Generate AI summary using Ollama
# Usage: generate_ollama_summary <pane_output>
# Returns: short summary of command success/failure
generate_ollama_summary() {
  local output="$1"
  local ollama_url_value="$(get_tmux_option "$ollama_url" "$ollama_url_default")"
  local ollama_model_value="$(get_tmux_option "$ollama_model" "$ollama_model_default")"
  local max_chars_value="$(get_tmux_option "$ollama_max_chars" "$ollama_max_chars_default")"

  # Truncate output if too long
  local truncated_output="${output:0:$max_chars_value}"

  local response summary payload

  if command -v python3 &>/dev/null; then
    payload=$(printf '%s' "$truncated_output" | OLLAMA_MODEL="$ollama_model_value" python3 -c '
import json, os, sys
output = sys.stdin.read()
model = os.environ["OLLAMA_MODEL"]
prompt = (
    "Analyze this terminal command output and provide a very brief summary "
    "(1-2 sentences max) of whether the command succeeded or failed, and what it did. "
    "Be concise:\n\n"
) + output
print(json.dumps({"model": model, "prompt": prompt, "stream": False}))
' 2>/dev/null) || payload=""

    if [ -n "$payload" ]; then
      response=$(curl -sS --max-time 30 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${ollama_url_value%/}/api/generate" 2>/dev/null) || response=""

      summary=$(printf '%s' "$response" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("response") or "", end="")
except Exception:
    pass
' 2>/dev/null) || summary=""
    fi
  fi

  if [ -z "$summary" ] && [ -z "$payload" ]; then
    # Fallback without python3: fragile on multiline pane output (invalid JSON)
    local escaped_output
    escaped_output=$(printf '%s' "$truncated_output" | sed ':a;N;$!ba; s/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\t/\\t/g; s/\r//g')
    local prompt="Analyze this terminal command output and provide a very brief summary (1-2 sentences max) of whether the command succeeded or failed, and what it did. Be concise:\n\n$escaped_output"
    response=$(curl -sS --max-time 30 \
      -X POST \
      -H "Content-Type: application/json" \
      -d "{\"model\": \"$ollama_model_value\", \"prompt\": \"$prompt\", \"stream\": false}" \
      "${ollama_url_value%/}/api/generate" 2>/dev/null) || response=""
    summary=$(printf '%s' "$response" | grep -o '"response":"[^"]*"' | head -n1 | sed 's/"response":"//; s/"$//')
    summary=$(printf '%s' "$summary" | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\"/"/g; s/\\\\/\\/g')
  fi

  if [ -n "$(printf '%s' "$summary" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$summary"
  else
    echo "Command completed - could not generate AI summary"
  fi
}

# Send notification
# Usage: notify <message> <title> <send_telegram>
notify() {
  # Switch notification method based on OS
  if [[ "$OSTYPE" =~ ^darwin ]]; then # If macOS
    if [ -n "$2" ]; then
      osascript -e 'display notification "'"$1"'" with title "'"$2"'"'
    else
      osascript -e 'display notification "'"$1"'" with title "tmux-notify"'
    fi
  else
    # notify-send does not always work due to changing dbus params
    # see https://superuser.com/questions/1118878/using-notify-send-in-a-tmux-session-shows-error-no-notification#1118896
    if [ -n "$2" ]; then
      notify-send "$2" "$1"
    else
      notify-send "$1"
    fi
  fi
  
  # Send telegram message if telegram variables are set, and telegram alert all is
  # enabled or if the $3 argument is set to true
  if telegram_available && (telegram_all_enabled || [ "$3" == "true" ]); then
    telegram_bot_id="$(get_tmux_option "$tmux_notify_telegram_bot_id" "$tmux_notify_telegram_bot_id_default")"
    telegram_chat_id="$(get_tmux_option "$tmux_notify_telegram_channel_id" "$tmux_notify_telegram_channel_id_default")"
    send_telegram_message $telegram_bot_id $telegram_chat_id "$1"
  fi

  if pushover_available; then
    local pushover_token="$(get_tmux_option "$tmux_notify_pushover_token" "$tmux_notify_pushover_token_default")"
    local pushover_user="$(get_tmux_option "$tmux_notify_pushover_user" "$tmux_notify_pushover_user_default")"
    local pushover_title="$(get_tmux_option "$tmux_notify_pushover_title" "$tmux_notify_pushover_title_default")"
    send_pushover_message "$pushover_token" "$pushover_user" "$pushover_title" "$1"
  fi
  
  # trigger visual bell
  # your terminal emulator can be setup to set URGENT bit on visual bell
  # for eg, Xresources -> URxvt.urgentOnBell: true
  tmux split-window -t "\$$SESSION_ID":@"$WINDOW_ID" "echo -e \"\a\" && exit"
}
