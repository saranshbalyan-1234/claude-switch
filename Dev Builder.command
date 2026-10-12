#!/bin/bash
# Development helper: leave this window open while Claude works on Claude Switch. Whenever .dev/job changes it runs
# that job with .dev/jobs.sh (read fresh each time) and writes the output to .dev/log. Close the window to stop it.
cd "$(dirname "$0")" || exit 1
mkdir -p .dev; last=$(cat .dev/job 2>/dev/null)
echo "Claude Switch dev builder: waiting for jobs. Close this window to stop."
while sleep 1; do
  job=$(cat .dev/job 2>/dev/null)
  [ -n "$job" ] && [ "$job" != "$last" ] || continue
  last=$job
  echo "$(date '+%H:%M:%S')  $job"
  { echo "job: $job"; date; bash .dev/jobs.sh ${job%% *}; echo "exit $?"; } > .dev/log.tmp 2>&1
  cat .dev/log.tmp > .dev/log
  echo "$(date '+%H:%M:%S')  done: $(tail -1 .dev/log)"
done
