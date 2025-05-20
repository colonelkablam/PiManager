#!/usr/bin/env bash
# nick_pi_manager.sh — headless Pi Zero 2 W status dashboard

### Colour codes ###
OK_COLOR="\e[32m"       # green
WARN_COLOR="\e[33m"     # yellow
CRIT_COLOR="\e[31m"     # red
DIM_COLOR="\e[2m"       # dim
RESET_COLOR="\e[0m"      # reset all

### Warning thresholds ###
CPU_WARN=70             # %
CPU_CRIT=90             # %
RAM_WARN=70             # %
RAM_CRIT=90             # %
DISK_WARN=80            # %
DISK_CRIT=95            # %
TEMP_WARN=60            # °C
TEMP_CRIT=75            # °C
WIFI_WARN_DBM=-70       # dBm
WIFI_CRIT_DBM=-85       # dBm

# Determine effective user for logging
if [[ $EUID -eq 0 && -n $SUDO_USER ]]; then
  EFFECTIVE_USER="$SUDO_USER"
  USER_HOME=$(eval echo "~$SUDO_USER")
else
  EFFECTIVE_USER="$USER"
  USER_HOME="$HOME"
fi

### XDG directory setup ###
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$USER_HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$USER_HOME/.local/state}"
CONFIG_DIR="$XDG_CONFIG_HOME/nick_pi_manager"
STATE_DIR="$XDG_STATE_HOME/nick_pi_manager"
LOG_DIR="$STATE_DIR/logs"
CPU_LOG_FILE="$LOG_DIR/cpu_log.csv"
RAM_LOG_FILE="$LOG_DIR/ram_log.csv"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$STATE_DIR/state.yaml"
SNAPSHOT_DIR="$STATE_DIR/snapshots"

# systemd root unit dir
SYSTEMD_SYSTEM_DIR="/etc/systemd/system"
SERVICE_FILE="$SYSTEMD_SYSTEM_DIR/nick_pi_manager-log.service"
TIMER_FILE="$SYSTEMD_SYSTEM_DIR/nick_pi_manager-log.timer"

# Ensure essential directories and configs exist
initialise_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$SNAPSHOT_DIR"
  touch "$CPU_LOG_FILE" "$RAM_LOG_FILE"

  # not currently using but will for logging back-ups etc
  [[ ! -f "$STATE_FILE" ]] && cat > "$STATE_FILE" <<EOF
last_backup: {}
seen_items: []
EOF

  [[ ! -f "$CONFIG_FILE" ]] && cat > "$CONFIG_FILE" <<EOF
cpu=true
ram=true
disk=true
wifi=true
cpu_log=true
ram_log=true
log_prune=7d
log_interval=5s
timer_enabled=false
EOF

  # Ensure all expected config keys exist (add missing with defaults)
  ensure_config_key() {
    local key=$1 default=$2
    grep -q "^${key}=" "$CONFIG_FILE" || echo "${key}=${default}" >> "$CONFIG_FILE"
  }

  ensure_config_key "cpu" true
  ensure_config_key "ram" true
  ensure_config_key "disk" true
  ensure_config_key "wifi" true
  ensure_config_key "cpu_log" true
  ensure_config_key "ram_log" true
  ensure_config_key "log_prune" "7d"
  ensure_config_key "log_interval" "5seconds"
  ensure_config_key "timer_enabled" false
}

# Write the .timer unit file
generate_timer_contents() {
  source "$CONFIG_FILE"
  local interval="${log_interval:-5s}"

  cat <<EOF
[Unit]
Description=Schedule nick_pi_manager logging

[Timer]
# fire once after system boots…
OnBootSec=30seconds
# fire once, after the timer unit is started…
OnActiveSec=${interval}
# …and then every <interval> after the service last ran
OnUnitActiveSec=${interval}

AccuracySec=1s
Unit=nick_pi_manager-log.service

[Install]
WantedBy=timers.target
EOF
} 

# Write the .service unit file
generate_service_contents() {
  cat <<EOF
[Unit]
Description=Append CPU & RAM samples to nick_pi_manager logs

[Service]
Type=oneshot
User=nickh
ExecStart=/home/nickh/PiManager/nick_pi_manager.sh --log
StandardOutput=journal
StandardError=journal
EOF
}

# Creates/modifies systemd unit files only when needed
initialise_units() {
  local timer_changed=false service_changed=false

  # Write the timer file if missing or changed
  if [[ ! -f "$TIMER_FILE" ]] || ! diff -q <(generate_timer_contents) "$TIMER_FILE" >/dev/null; then
    echo "Updating timer unit at $TIMER_FILE"
    generate_timer_contents | sudo tee "$TIMER_FILE" > /dev/null
    timer_changed=true
  fi

  # Write the service file if missing or changed
  if [[ ! -f "$SERVICE_FILE" ]] || ! diff -q <(generate_service_contents) "$SERVICE_FILE" >/dev/null; then
    echo "Updating service unit at $SERVICE_FILE"
    generate_service_contents | sudo tee "$SERVICE_FILE" > /dev/null
    service_changed=true
  fi

  # Reload systemd only if something changed
  if [[ $timer_changed == true || $service_changed == true ]]; then
    echo "Reloading systemd daemon..."
    sudo systemctl daemon-reload
  fi
}

# Load user toggles
load_config() {
  source "$CONFIG_FILE"
  NUM_CORES=$(nproc)
  # Record the dashboard’s PID so ignored on process display
  MYPID=$$
}

# Metric getters
get_cpu_usage() {
  awk '/^cpu /{printf("%.1f", ($2+$4)*100/($2+$4+$5))}' /proc/stat
}
get_ram_usage()    { free -m | awk '/Mem:/{print int($3*100/$2)}'; }
get_disk_usage()   { df / | awk 'NR==2{print int($5)}'; }
get_swap_usage()   { free | awk '/Swap:/{print int($3*100/$2)}'; }
get_cpu_temp()     { awk '{print int($1/1000)}' /sys/class/thermal/thermal_zone0/temp; }
get_load_avg()     { awk '{printf("%.2f/%.2f/%.2f",$1,$2,$3)}' /proc/loadavg; }
get_uptime()       { uptime -p | sed 's/up //'; }
get_ip()           { ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1; }
get_wifi() {
  local ssid dbm perc fmt
  ssid=$(iwgetid -r 2>/dev/null||echo N/A)
  dbm=$(iw dev wlan0 link 2>/dev/null|awk '/signal/{print $2}')
  perc=$(( (dbm+100)*100/50 ))
  ((perc<0))&&perc=0; ((perc>100))&&perc=100
  if ((dbm<=WIFI_CRIT_DBM)); then fmt="${CRIT_COLOR}${dbm}dBm${RESET_COLOR}"
  elif ((dbm<=WIFI_WARN_DBM)); then fmt="${WARN_COLOR}${dbm}dBm${RESET_COLOR}"
  else fmt="${OK_COLOR}${dbm}dBm${RESET_COLOR}"; fi
  echo -e "${ssid}: ${fmt} (${perc}%)"
}
get_num_cores() {
  echo "$NUM_CORES"
}
# count the running processes
get_proc_count()    { ps -e --no-headers | wc -l; }
# Top 3 memory-hungry processes, showing PID, command & %MEM
get_top_mem_list() {
  local count=${1:-1}
  ps --no-headers -eo pid,%mem,comm --sort=-%mem \
    | head -n"$count" \
    | awk '{ printf "%3d. %s (pid %s, %s%% mem)\n", NR, $3, $1, $2 }'
}
# Top 3 CPU-hungry processes, excluding the dashboard itself and the ps command,
# showing PID, command, normalized % of total cores, and raw %CPU
get_top_cpu_list() {
  local count=${1:-1}
  ps --no-headers -eo pid,%cpu,comm --sort=-%cpu |
    awk -v mypid="$MYPID" '$1 != mypid && $3 != "ps"' |
    head -n"$count" |
    awk -v cores="$NUM_CORES" '
    {
      pct = ($2 / cores)
      printf "%3d. %s (pid %s, %.1f%% of total, %s%% raw)\n", NR, $3, $1, pct, $2
    }'
}

# Colour helper
color_value() {
  local v="$1" w="$2" c="$3" u="$4"
  # Round v to nearest integer for the comparisons:
  local iv
  iv=$(printf "%.0f" "$v")
  if   (( iv >= c )); then
    echo -e "${CRIT_COLOR}${v}${u}${RESET_COLOR}"
  elif (( iv >= w )); then
    echo -e "${WARN_COLOR}${v}${u}${RESET_COLOR}"
  else
    echo -e "${OK_COLOR}${v}${u}${RESET_COLOR}"
  fi
}


# Render the dashboard
render_menu() {
  clear
  load_config
  echo -e "${DIM_COLOR}Nick Pi Manager — $(date)${RESET_COLOR}"

  # show logging status
  if sudo systemctl is-active --quiet nick_pi_manager-log.timer; then
    log_status="${OK_COLOR}ACTIVE${RESET_COLOR}"
  else
    log_status="${CRIT_COLOR}INACTIVE${RESET_COLOR}"
  fi
  echo -e "\nLogging: $log_status (every ${log_interval:-?}, kept for ${log_prune:-?})\n"

  # display updates available
  if (( update_count > 0 )); then
    update_status="${WARN_COLOR}System and Software Updates Available: $update_count${RESET_COLOR}"
  else
    update_status="${OK_COLOR}System Up-to-date${RESET_COLOR}"
  fi
  echo -e "$update_status\n"

  # diaplay main info
  printf "%3s %-15s %-20s\n" "#" "Metric" "Value"
  local idx=1 val
  # cors available
  cores=$(get_num_cores)
  printf "%3s %-15s %-20s\n" "$((idx++))" "Cores"      "$cores"
  [[ $cpu  == true ]] && { val=$(get_cpu_usage);    printf "%3s %-15s %-20s\n" "$((idx++))" "CPU %"       "$(color_value $val $CPU_WARN $CPU_CRIT '%')"; }
  [[ $ram  == true ]] && { val=$(get_ram_usage);    printf "%3s %-15s %-20s\n" "$((idx++))" "RAM %"       "$(color_value $val $RAM_WARN $RAM_CRIT '%')"; }
  [[ $disk == true ]] && { val=$(get_disk_usage);   printf "%3s %-15s %-20s\n" "$((idx++))" "Disk %"      "$(color_value $val $DISK_WARN $DISK_CRIT '%')"; }
  [[ $wifi == true ]] && { printf "%3s %-15s %-20s\n" "$((idx++))" "Wi-Fi"       "$(get_wifi)"; }
  val=$(get_cpu_temp); printf "%3s %-15s %-20s\n" "$((idx++))" "Temp (deg C)"   "$(color_value $val $TEMP_WARN $TEMP_CRIT '°C')"
  printf "%3s %-15s %-20s\n" "$((idx++))" "Load avg"     "$(get_load_avg) (1/5/15 min per core)"
  printf "%3s %-15s %-20s\n" "$((idx++))" "Uptime"       "$(get_uptime)"
  printf "%3s %-15s %-20s\n" "$((idx++))" "IP (wlan0)"   "$(get_ip)"
  val=$(get_swap_usage); printf "%3s %-15s %-20s\n" "$((idx++))" "Swap %"      "$(color_value $val 0 100 '%')"
  # processes
  val=$(get_proc_count)
  printf "%3s %-15s %-20s\n" "$((idx++))" "Process Count" "$val"
  printf "%3s %-17s %-20s\n" "" "├─ Top MEM" "$(get_top_mem_list 1)"
  printf "%3s %-17s %-20s\n" "" "└─ Top CPU" "$(get_top_cpu_list 1)"
  printf "%3s %-15s %-20s\n" "" "" "[M] MEM details   [C] CPU details"

  echo -e "
  [R]efresh    [P]rocesses   [D]evices     [U]pdate List
  [S]napshot   [L]ogging     System Lo[G]s [I]nfo

                             [X]Reset      [Q]uit"
}

# Detailed views
show_processes(){ ps aux --sort=-%cpu | head -n20 | less -R; }
show_devices()  { lsusb              | less; }
show_updates()  { apt list --upgradable 2>/dev/null | less; }
show_system_logs()     { dmesg | tail -n50   | less -R; }
show_snapshot(){ local f="$SNAPSHOT_DIR/snapshot-$(date +%Y%m%d-%H%M%S).txt"; render_menu > "$f"; echo "Snapshot saved to $f"; read -n1 -r -p "Press any key..."; }
# Manage the logging and history views here
show_logging_panel() {
  while true; do
    # Get newest values
    load_config
    clear
    echo -e "${DIM_COLOR}⚙️  Config files:   $CONFIG_DIR${RESET_COLOR}"
    echo -e "${DIM_COLOR}📁 Logs files stored in: $LOG_DIR${RESET_COLOR}"
    echo -e "${DIM_COLOR}🛠️  Timer/service files live in: $SYSTEMD_SYSTEM_DIR${RESET_COLOR}"
    echo
    # detect systemd‐timer state
    if sudo systemctl is-active --quiet nick_pi_manager-log.timer; then
      LOGGER_STATE="Enabled"
    else
      LOGGER_STATE="Disabled"
    fi
    # Display options
    echo "📊 Logging and History Panel"
    echo
    echo "1) Toggle system logger (timer) (currently: $LOGGER_STATE)"
    echo "2) Toggle CPU logging (currently: $cpu_log)"
    echo "3) Toggle RAM logging (currently: $ram_log)"
    echo "4) View CPU history"
    echo "5) View RAM history"
    echo "6) Clear CPU log"
    echo "7) Clear RAM log"
    echo "Q) Back"
    read -n1 -p "Choice: " ch; echo

    case "$ch" in
      1)
        if sudo systemctl is-active --quiet nick_pi_manager-log.timer; then
          echo "Disabling timer..."
          sudo systemctl disable --now nick_pi_manager-log.timer
          sed -i 's/^timer_enabled=true/timer_enabled=false/' "$CONFIG_FILE"
        else
          echo "Enabling timer..."
          sudo systemctl enable --now nick_pi_manager-log.timer
          sed -i 's/^timer_enabled=false/timer_enabled=true/' "$CONFIG_FILE"
        fi
        ;;
      2)
        # flip and immediately reload so see the new state
        sed -i "s/^cpu_log=.*/cpu_log=$( [[ $cpu_log == true ]] && echo false || echo true )/" "$CONFIG_FILE"
        source "$CONFIG_FILE";;
      3)
        # flip and immediately reload so see the new state
        sed -i "s/^ram_log=.*/ram_log=$( [[ $ram_log == true ]] && echo false || echo true )/" "$CONFIG_FILE"
        source "$CONFIG_FILE";;
      4) show_cpu_history;;
      5) show_ram_history;;
      6)
          read -p "Are you sure you want to clear CPU log? [y/N]: " clear_cpu_log
          if [[ "$clear_cpu_log" =~ ^[Yy]$ ]]; then
            > "$CPU_LOG_FILE"
          read -n1 -r -p "Log cleared, press any key..."
          fi ;;
      7)
          read -p "Are you sure you want to clear RAM log? [y/N]: " clear_ram_log
          if [[ "$clear_ram_log" =~ ^[Yy]$ ]]; then
            > "$RAM_LOG_FILE"
          read -n1 -r -p "Log cleared, press any key..."
          fi ;;
      [Qq]) break;;
      *) ;;
    esac
  done
}

# user to pick history frame
pick_history_window() {
  echo "Select history window:"
  echo "  1) 1 minute"
  echo "  2) 10 minutes"
  echo "  3) 1 hour"
  echo "  4) 6 hours"
  echo "  5) 12 hours"
  echo "  6) 24 hours"
  read -n1 -p "Choice [1-6]: " choice
  echo

  case "$choice" in
    1) window=60    ; bs=1    ;;  # per-second
    2) window=600   ; bs=10   ;;  # per-10sec
    3) window=3600  ; bs=60   ;;  # per-minute
    4) window=21600 ; bs=600  ;;  # per-10min
    5) window=43200 ; bs=1200 ;;  # per-20min
    6) window=86400 ; bs=3600 ;;  # per-hour
    *) echo "Invalid choice."; read -n1 -r -p "Press any key…"; return 1 ;;
  esac
  return 0
}

# Generic history renderer
_show_history_generic() {
  local logfile=$1 unit=$2 window=$3 bs=$4
  local now start nb
  now=$(date +%s)
  start=$(( now - window ))
  nb=$(( (now - start) / bs ))

  awk -F, -v start="$start" -v bs="$bs" -v now="$now" -v unit="$unit" '
    BEGIN { for(i=0;i<='"$nb"'   ;i++) max[i]=0 }
    $1>=start {
      idx=int(($1-start)/bs)
      if($2>max[idx]) max[idx]=$2
    }
    END {
      for(i=0;i<=nb;i++){
        t=start + i*bs
        printf "%s  %5.1f%s\n",
          strftime("%Y-%m-%d %H:%M:%S", t), max[i], unit
      }
    }
  ' "$logfile" | less -R
}

show_cpu_history() {
  pick_history_window || return
  _show_history_generic "$CPU_CPU_FILE" "% CPU" "$window" "$bs"
}

show_ram_history() {
  pick_history_window || return
  _show_history_generic "$RAM_LOG_FILE" "% RAM" "$window" "$bs"
}

show_process_info() {
  local pid="$1"
  # Make sure it exists
  if ! [[ -d "/proc/$pid" ]]; then
    echo "PID $pid does not exist."
    read -n1 -r -p "Press any key to continue…"
    return
  fi

  # 1) Executable name
  local name
  name=$(ps -p "$pid" -o comm=)

  # 2) Full command line
  local cmdline
  cmdline=$(ps -p "$pid" -o args=)

  # 3) Script or first argument, if the process is an interpreter
  #    We take the 2nd token of the args (field 2) if it exists.
  local script
  script=$(echo "$cmdline" | awk '{print $2}')
  [[ -z "$script" ]] && script="(none)"

  # Print out
  echo
  echo -e "${DIM_COLOR}Process details for PID $pid:${RESET_COLOR}"
  printf "  %-12s %s\n" "Name:" "$name"
  printf "  %-12s %s\n" "CmdLine:" "$cmdline"
  printf "  %-12s %s\n" "Script:" "$script"
  echo

  read -n1 -r -p "Press any key to continue…"
}

show_top_mem() {
  while true; do
    clear
    echo -e "${DIM_COLOR}Top 15 Memory-Hungry Processes:${RESET_COLOR}\n"
    get_top_mem_list 15
    echo
    read -n1 -p "Enter [1–15] to view process info or any other key to return: " choice
    echo
    if [[ "$choice" =~ ^[1-9]$|^1[0-5]$ ]]; then
      pid=$(ps --no-headers -eo pid,%mem,comm --sort=-%mem | awk "NR==$choice {print \$1}")
      if [[ -n "$pid" ]]; then
        show_process_info "$pid"
      fi
    else
      break
    fi
  done
}

show_top_cpu() {
  while true; do
    clear
    echo -e "${DIM_COLOR}Top 15 CPU-Hungry Processes:${RESET_COLOR}\n"
    get_top_cpu_list 15
    echo
    read -n1 -p "Enter [1–15] to view process info or any other key to return: " choice
    echo
    if [[ "$choice" =~ ^[1-9]$|^1[0-5]$ ]]; then
      pid=$(ps --no-headers -eo pid,%cpu,comm --sort=-%cpu | awk "NR==$choice {print \$1}")
      if [[ -n "$pid" ]]; then
        show_process_info "$pid"
      fi
    else
      break
    fi
  done
}


# Main loop
main_loop() {
  # only get update count when loading up
  update_count=$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable')
  while true; do
    render_menu
    read -n1 -s choice
    case "$choice" in
      [Rr]) ;; [Pp]) show_processes;; [Dd]) show_devices;; [Uu]) show_updates;; [Gg]) show_system_logs;; [Ss]) show_snapshot;; [Ll]) show_logging_panel;; [Ii]) show_process_info;; [Mm]) show_top_mem;; [Cc]) show_top_cpu;; [Xx]) reset_settings;; [Qq]) echo; exit 0;; *);;
    esac
  done
}

# Systemd always reflects the real config state
apply_timer_state() {
  if grep -q '^timer_enabled=true' "$CONFIG_FILE"; then
    sudo systemctl enable --now nick_pi_manager-log.timer
  else
    sudo systemctl disable --now nick_pi_manager-log.timer
  fi
}

# Reset config & state to defaults
reset_settings(){
  read -p "Are you sure you want to reset all settings and state? [y/N]: " ans

  if [[ "$ans" =~ ^[Yy]$ ]]; then

    # check if logs to be deleted
    read -p "Do you also want to clear all logs? [y/N]: " clear_logs
      if [[ "$clear_logs" =~ ^[Yy]$ ]]; then
        rm -rf "$LOG_DIR"
        echo "Logs cleared."
      else
        echo "Logs preserved in: $LOG_DIR"
      fi

    # continue with reset
    echo -e "${WARN_COLOR}Removing config, state, and unit files...${RESET_COLOR}"

    sudo systemctl stop nick_pi_manager-log.timer 2>/dev/null
    sudo systemctl disable nick_pi_manager-log.timer 2>/dev/null
    sudo systemctl stop nick_pi_manager-log.service 2>/dev/null
    sudo systemctl disable nick_pi_manager-log.service 2>/dev/null

    sudo rm -f "/etc/systemd/system/nick_pi_manager-log.timer"
    sudo rm -f "/etc/systemd/system/nick_pi_manager-log.service"
    sudo systemctl daemon-reload

    rm -rf "$CONFIG_DIR" "$STATE_FILE"

    # Do NOT delete $LOG_DIR here (in case you want to keep logs)
    initialise_dirs
    initialise_units
    apply_timer_state

    echo -e "${OK_COLOR}Settings and systemd unit files have been reset.${RESET_COLOR}"
    echo
    echo -e "${WARN_COLOR}Note:${RESET_COLOR} Logging timer is currently ${CRIT_COLOR}disabled${RESET_COLOR}."
    echo "You can re-enable it from the [L]ogging panel."
    echo

  else
    echo "Reset cancelled."
  fi
}

# Logger: prune old entries & append current CPU%
run_logger(){
  load_config
  local prune_val prune_secs now cpu ram
  now=$(date +%s)
  echo "Running logger"
  echo "Saving logs to LOG_DIR = $LOG_DIR"

  # if cpu being logged
  if [[ "$cpu_log" == true ]]; then
    prune_val=$(awk -F= '/log_prune/ {print $2}' "$CONFIG_FILE")
    if [[ "$prune_val" =~ ([0-9]+)d ]]; then prune_secs=$((BASH_REMATCH[1]*86400))
    elif [[ "$prune_val" =~ ([0-9]+)h ]]; then prune_secs=$((BASH_REMATCH[1]*3600))
    else prune_secs=0; fi

    tmp_cpu="$LOG_DIR/cpu_log_tmp.csv"
    awk -F, -v now="$now" -v ps="$prune_secs" '$1>=now-ps' "$CPU_LOG_FILE" > "$tmp_cpu" && mv "$tmp_cpu" "$CPU_LOG_FILE"
    cpu=$(awk '/^cpu /{print ($2+$4)*100/($2+$4+$5)}' /proc/stat)
    printf "%d,%.1f\n" "$now" "$cpu" >> "$CPU_LOG_FILE"
  fi

  # if ram being logged
  if [[ "$ram_log" == true ]]; then
    prune_val=$(awk -F= '/log_prune/ {print $2}' "$CONFIG_FILE")
    if [[ "$prune_val" =~ ([0-9]+)d ]]; then prune_secs=$((BASH_REMATCH[1]*86400))
    elif [[ "$prune_val" =~ ([0-9]+)h ]]; then prune_secs=$((BASH_REMATCH[1]*3600))
    else prune_secs=0; fi

    tmp_ram="$LOG_DIR/ram_log_tmp.csv"
    awk -F, -v now="$now" -v ps="$prune_secs" '$1>=now-ps' "$RAM_LOG_FILE" > "$tmp_ram" && mv "$tmp_ram" "$RAM_LOG_FILE"
    ram=$(free -m | awk '/Mem:/{printf("%.1f",$3*100/$2)}')
    printf "%d,%.1f\n" "$now" "$ram" >> "$RAM_LOG_FILE"
  fi
}


# Entry point
case "$1" in
  --reset)
    reset_settings
    ;;
  --log)
    run_logger
    ;;
  *)
    initialise_dirs
    initialise_units
    apply_timer_state   
    main_loop
    ;;
esac
