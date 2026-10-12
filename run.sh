#!/bin/bash
# Claude Switch: one entry point for everything.
#   ./run.sh           same as ./run.sh setup
#   ./run.sh setup     install claude-switch, its Claude Code hooks, and (on macOS) the menu bar app
#   ./run.sh test      test both against throwaway data (your login and settings are untouched)
#   ./run.sh build     build Claude Switch.app into dist/
#   ./run.sh package   test, build and zip into dist/ for other Macs
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
cmd=${1:-setup}
case $cmd in
  setup|test|build|package) ;;
  *) sed -n '3,7p' "$0" | sed 's/^# *//'; exit 1 ;;
esac
[ -f "$root/scripts/$cmd.sh" ] || { echo "'$cmd' needs the source folder; this package only supports setup." >&2; exit 1; }
if [ "$cmd" = build ]; then exec bash "$root/scripts/build.sh" "$root/dist"; fi
exec bash "$root/scripts/$cmd.sh"
