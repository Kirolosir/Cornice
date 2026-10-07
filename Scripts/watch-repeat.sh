#!/usr/bin/env bash
# Watch repeat-one logs while a song reaches its end.
# Use this to check when a loop is scheduled, runs, or recovers an early track change.

set -euo pipefail
echo "Watching Cornice. Set repeat-one, let a song finish, then press ctrl-C."
echo
exec log stream \
    --predicate 'subsystem == "dev.cornice.app"' \
    --level info \
    --style compact \
  | grep --line-buffered -E "repeat one|poll:"
