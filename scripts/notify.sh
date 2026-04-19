#!/usr/bin/env bash
# Usage: notify <refocus> <telegram>
## -- Start monitoring script

# Get current directory
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helpers and variables
source "${CURRENT_DIR}/helpers.sh"
source "${CURRENT_DIR}/variables.sh"

## Functions

# Handle cancelation of monitor job
on_cancel()
{
  # Wait a bit for all pane monitors to complete
  sleep "$monitor_sleep_duration_value"
  
  # Preform cleanup operation is monitoring was canceled
  if [[ -f "$PID_FILE_PATH" ]]; then
    kill "$PID"
    rm "${PID_DIR}/${PANE_ID}.pid"
  fi
  exit 0
}
trap 'on_cancel' TERM

## Main script

# Monitor pane if it is not already monitored
if [[ ! -f "$PID_FILE_PATH" ]]; then  # If pane not yet monitored
  # job started - create pid-file
  echo "$$" > "$PID_FILE_PATH"
  
  # Display tnotify start messsage
  tmux display-message "Monitoring pane..."
  
  # Construct tnotify finish message
  if verbose_enabled; then  # If @tnotify-verbose is enabled
    verbose_msg_value="$(get_tmux_option "$verbose_msg_option" "$verbose_msg_default")"
    complete_message=$(tmux display-message -p "$verbose_msg_value")
    verbose_msg_title="$(get_tmux_option "$verbose_title_option" "$verbose_title_default")"
    complete_title=$(tmux display-message -p "$verbose_msg_title")
  else  # If @tnotify-verbose is disabled
    complete_message="Tmux pane task completed!"
  fi
  
  # Prompt detection: optional extended regex overrides comma-separated suffixes.
  prompt_regex_value="$(get_tmux_option "$prompt_regex" "$prompt_regex_default")"
  prompt_regex_value="${prompt_regex_value#"${prompt_regex_value%%[![:space:]]*}"}"
  prompt_regex_value="${prompt_regex_value%"${prompt_regex_value##*[![:space:]]}"}"

  if [ -n "$prompt_regex_value" ]; then
    prompt_done_mode="regex"
  else
    prompt_done_mode="suffix"
    # Create bash suffix list
    # NOTE: Looks complicated but uses shell parameter expansion
    # see https://www.gnu.org/savannah-checkouts/gnu/bash/manual/bash.html#Shell-Parameter-Expansion
    prompt_suffixes="$(get_tmux_option "$prompt_suffixes" "$prompt_suffixes_default")"
    prompt_suffixes=${prompt_suffixes// /} # Remove whitespace
    prompt_suffixes=${prompt_suffixes//,/|} # Replace comma with or operator
    prompt_suffixes=$(escape_glob_chars "$prompt_suffixes")
    prompt_suffixes="\(${prompt_suffixes}\)$"
  fi

  # Check process status every 10 seconds to see if has is finished
  while true; do
    # capture pane output
    output=$(tmux capture-pane -pt %"$PANE_ID")

    # run tests to determine if work is done (last two lines, same as suffix mode)
    pane_tail=$(printf '%s\n' "$output" | tail -n2)
    pane_done=0
    if [ "$prompt_done_mode" = "regex" ]; then
      echo "$pane_tail" | grep -Eq "$prompt_regex_value" &> /dev/null && pane_done=1
    else
      echo "$pane_tail" | grep -e $prompt_suffixes &> /dev/null && pane_done=1
    fi

    if [ "$pane_done" -eq 1 ]; then
      if [[ "$1" == "true" ]]; then
        tmux switch -t \$"$SESSION_ID"
        tmux select-window -t @"$WINDOW_ID"
        tmux select-pane -t %"$PANE_ID"
      fi

      # Generate AI summary if Ollama is enabled and available
      if ollama_enabled && ollama_available; then
        # Capture the last 50 lines of output for analysis (to avoid overwhelming the API)
        # (must not use `local` here: this block is not inside a function)
        relevant_output=$(echo "$output" | tail -n 50)
        ai_summary=$(generate_ollama_summary "$relevant_output")
        notify "$ai_summary" "Tmux Task Summary" $2
      else
        notify "$complete_message" "$complete_title" $2
      fi
      break
    fi
    
    # Sleep for a given time
    monitor_sleep_duration_value=$(get_tmux_option "$monitor_sleep_duration" "$monitor_sleep_duration_default")
    sleep "$monitor_sleep_duration_value"
  done
  
  # job done - remove pid file
  if [[ -f "$PID_FILE_PATH" ]]; then
    rm "$PID_FILE_PATH"
  fi
  
  # Execute custom command if specified by user
  custom_command="$(get_tmux_option "$custom_notify_command" "$custom_notify_command_default")"
  if [[ -n "$custom_command" ]]; then
    eval "${custom_command}"
  fi
  
  exit 0
else  # If pane is already being monitored
  
  # Display pane already monitored message
  tmux display-message "Pane already monitored..."
  exit 0
fi
