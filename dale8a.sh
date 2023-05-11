#!/bin/sh
AWKENGINE="mawk -W posix"
#AWKENGINE="gawk -P"
#AWKENGINE="busybox awk"
ESC=$'\x1b'
STTYSTATE="$(stty -g)" # save the stty-readable state
trap cleanup 2 15 # trap Ctrl+C (SIGINT) and SIGTERM
cleanup() { # restore the state of stty and screen
  printf '%s' "${ESC}[?47l"
  stty "$STTYSTATE"
}
LANG=C $AWKENGINE -f tgl.awk -f dale8a.awk -v CLOCK_FACTOR=20 -- $1 # run the emulator
cleanup
