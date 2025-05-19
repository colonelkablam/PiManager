#!/usr/bin/env bash
# cleanup_nick_pi_manager_units.sh

echo "🔧 Stopping and disabling nick_pi_manager units..."
systemctl --user stop nick_pi_manager-log.timer 2>/dev/null
systemctl --user stop nick_pi_manager-log.service 2>/dev/null
systemctl --user disable nick_pi_manager-log.timer 2>/dev/null
systemctl --user disable nick_pi_manager-log.service 2>/dev/null

echo "🧹 Removing unit files and symlinks..."
rm -f "$HOME/.config/systemd/user/nick_pi_manager-log."{service,timer}
rm -f "$HOME/.config/systemd/user/timers.target.wants/nick_pi_manager-log.timer"

echo "🔄 Reloading user systemd daemon..."
systemctl --user daemon-reexec
systemctl --user daemon-reload

echo "🗑️ Clearing journal logs for nick_pi_manager..."
journalctl --user --vacuum-time=1s >/dev/null 2>&1

echo "✅ Cleanup complete. Unit files and logs have been purged."
