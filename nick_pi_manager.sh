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

### XDG directory setup ###
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CONFIG_DIR="$XDG_CONFIG_HOME/nick_pi_manager"
STATE_DIR="$XDG_STATE_HOME/nick_pi_manager"
LOG_FILE="$STATE_DIR/cpu_log.csv"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$STATE_DIR/state.yaml"
SNAPSHOT_DIR="$STATE_DIR/snapshots"

# Ensure directories & default files exist
initialize_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$SNAPSHOT_DIR"
  touch "$LOG_FILE"
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
cpu_log_prune=7d
EOF
}

# Load user toggles
load_config() {
  source "$CONFIG_FILE"
  NUM_CORES=$(nproc)
  # Record the dashboard’s PID once, near the top of the script
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
get_proc_count()    { ps -e --no-headers | wc -l; }
# Top 3 memory-hungry processes, showing PID, command & %MEM
get_top_mem_list() {
  ps --no-headers -eo pid,%mem,comm --sort=-%mem \
    | head -n3 \
    | awk '{ printf "%d. %s (pid %s, %s%% mem)\n", NR, $3, $1, $2 }'
}
# Top 3 CPU-hungry processes, excluding the dashboard itself and the ps command,
# showing PID, command, normalized % of total cores, and raw %CPU
get_top_cpu_list() {
  ps --no-headers -eo pid,%cpu,comm --sort=-%cpu |
    awk -v mypid="$MYPID" '$1 != mypid && $3 != "ps"' |
    head -n3 |
    awk -v cores="$NUM_CORES" '
    {
      pct = ($2 / cores)
      printf "%d. %s (pid %s, %.1f%% of total, %s%% raw)\n", NR, $3, $1, pct, $2
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
  clear; load_config
  echo -e "${DIM_COLOR}Nick Pi Manager — $(date)${RESET_COLOR}\n"
  printf "%-3s %-15s %-20s\n" "#" "Metric" "Value"
  local idx=1 val
    # cors available
  cores=$(get_num_cores)
  printf "%-3s %-15s %-20s\n" "$((idx++))" "Cores"      "$cores"
  [[ $cpu  == true ]] && { val=$(get_cpu_usage);    printf "%-3s %-15s %-20s\n" "$((idx++))" "CPU %"       "$(color_value $val $CPU_WARN $CPU_CRIT '%')"; }
  [[ $ram  == true ]] && { val=$(get_ram_usage);    printf "%-3s %-15s %-20s\n" "$((idx++))" "RAM %"       "$(color_value $val $RAM_WARN $RAM_CRIT '%')"; }
  [[ $disk == true ]] && { val=$(get_disk_usage);   printf "%-3s %-15s %-20s\n" "$((idx++))" "Disk %"      "$(color_value $val $DISK_WARN $DISK_CRIT '%')"; }
  [[ $wifi == true ]] && { printf "%-3s %-15s %-20s\n" "$((idx++))" "Wi-Fi"       "$(get_wifi)"; }
  val=$(get_cpu_temp); printf "%-3s %-15s %-20s\n" "$((idx++))" "Temp (°C)"   "$(color_value $val $TEMP_WARN $TEMP_CRIT '°C')"
  printf "%-3s %-15s %-20s\n" "$((idx++))" "Load avg"     "$(get_load_avg)"
  printf "%-3s %-15s %-20s\n" "$((idx++))" "Uptime"       "$(get_uptime)"
  printf "%-3s %-15s %-20s\n" "$((idx++))" "IP (wlan0)"   "$(get_ip)"
  val=$(get_swap_usage); printf "%-3s %-15s %-20s\n" "$((idx++))" "Swap %"      "$(color_value $val 0 100 '%')"
  val=$(get_proc_count); printf "%-3s %-15s %-20s\n" "$((idx++))" "Proc Count"   "$val"
  # Top 3 memory processes
  printf "%-3s %-15s %-20s\n" "$((idx++))" "Top MEM"      ""
  while IFS= read -r line; do
    printf "%-3s %-15s %-20s\n" "" "" "$line"
  done < <(get_top_mem_list)

  # Top 3 CPU processes
  printf "%-3s %-15s %-20s\n" "$((idx++))" "Top CPU"      ""
  while IFS= read -r line; do
    printf "%-3s %-15s %-20s\n" "" "" "$line"
  done < <(get_top_cpu_list)

  echo -e "\n[R]efresh  [P]rocesses  [D]evices  [U]pdates  [L]ogs  [S]napshot  [H]istory  [C]onfig  [I]nfo  [X] Reset  [Q]uit"
}

# Detailed views
show_processes(){ ps aux --sort=-%cpu | head -n20 | less -R; }
show_devices()  { lsusb              | less; }
show_updates()  { apt list --upgradable 2>/dev/null | less; }
show_logs()     { dmesg | tail -n50   | less -R; }
show_snapshot(){ local f="$SNAPSHOT_DIR/snapshot-$(date +%Y%m%d-%H%M%S).txt"; render_menu > "$f"; echo "Snapshot saved to $f"; read -n1 -r -p "Press any key..."; }
show_history()  { echo "History view not yet implemented."; read -n1 -r -p "Press any key..."; }
show_config()   { reset_settings; read -n1 -r -p "Press any key..."; }
show_process_info() {
  read -p "Enter PID for details: " pid

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


# Main loop
main_loop() {
  while true; do
    render_menu
    read -n1 -s choice
    case "$choice" in
      [Rr]) ;; [Pp]) show_processes;; [Dd]) show_devices;; [Uu]) show_updates;; [Ll]) show_logs;; [Ss]) show_snapshot;; [Hh]) show_history;; [Cc]) show_config;; [Ii]) show_process_info;;
[Xx]) reset_settings;; [Qq]) echo; exit 0;; *);;
    esac
  done
}

# Reset config & state to defaults
reset_settings(){
  read -p "Are you sure you want to reset all settings and state? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    echo -e "${WARN_COLOR}Removing config and state...${RESET_COLOR}"
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
    initialize_dirs
    echo -e "${OK_COLOR}Settings have been reset to defaults.${RESET_COLOR}"
  else
    echo "Reset cancelled."
  fi
}

# Logger: prune old entries & append current CPU%
run_logger(){
  local prune_val prune_secs now
  prune_val=$(awk -F= '/cpu_log_prune/ {print $2}' "$CONFIG_FILE")
  if [[ "$prune_val" =~ ([0-9]+)d ]]; then prune_secs=$((BASH_REMATCH[1]*86400)); elif [[ "$prune_val" =~ ([0-9]+)h ]]; then prune_secs=$((BASH_REMATCH[1]*3600)); else prune_secs=0; fi
  now=$(date +%s)
  awk -F, -v now="$now" -v ps="$prune_secs" '$1>=now-ps' "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  local cpu
  cpu=$(awk '/^cpu /{print ($2+$4)*100/($2+$4+$5)}' /proc/stat)
  printf "%d,%.1f
" "$now" "$cpu" >> "$LOG_FILE"
}

# Entry point
initialize_dirs
case "$1" in
  --reset) reset_settings;;
  --log)   run_logger;;
  *)       main_loop;;
esac
