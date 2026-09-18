#!/usr/bin/env bash
#
# Prints what Cornice's repeat-one is doing, live.
#
# Run it, set repeat-one in the panel, and let a song play to its end. Every line
# below is a decision the app made, so the output says which part failed rather
# than leaving it to guesswork.
#
#   repeat one: on / off        the button was pressed
#   looping in Ns               a loop is scheduled N seconds from now
#   looping spotify             the loop fired
#   player moved on Ns early    the track changed by itself and was put back
#   poll: playing / paused      the player was read

set -euo pipefail
echo "Watching Cornice. Set repeat-one, let a song finish, then press ctrl-C."
echo
exec log stream \
    --predicate 'subsystem == "dev.cornice.app"' \
    --level info \
    --style compact \
  | grep --line-buffered -E "repeat one|poll:"
