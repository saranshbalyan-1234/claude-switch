#!/bin/bash
# Tests, rebuilds and reinstalls Claude Switch, then restarts it. Double-click to run.
cd "$(dirname "$0")" || exit 1
./run.sh test && ./run.sh setup && echo && echo "Done: Claude Switch is updated. You can close this window."
