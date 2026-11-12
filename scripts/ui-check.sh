#!/bin/zsh
# Runs Glyph Time's UI check twice: a plain folder, then a stand-in Glyph Bot vault. Run it in a
# logged-in session (it opens real windows); it touches no real data. Pictures go to <out dir>.
# Usage: scripts/ui-check.sh [out dir]
set -euo pipefail

# Fru, 2026-10-31, stated three times and absolute: nothing executes on the Mac he works on.
# Builds, tests, simulators, screenshots and microphone checks go to the unattended desktop or to
# a laptop deliberately marked as a test host. The desktop has no battery and needs no flag.
# Detecting a battery rather than matching a computer name, because a name match wrongly refuses
# on a dedicated test laptop whose name happens to match the pattern.
if pmset -g batt 2>/dev/null | grep -q InternalBattery && [[ -z ${GLYPH_UI_HOST:-} ]]; then
  echo >&2 "Nothing executes on the Mac being worked on. Run this on the unattended desktop,"
  echo >&2 "or on a test laptop with GLYPH_UI_HOST=1 set."
  exit 2
fi
cd "${0:A:h}/.."
out=${1:-/tmp/glyph-time-ui}; (( $# )) && shift  # any further arguments go to the app, e.g. -showEdge YES
# This opens real windows and takes the keyboard, the screen and the microphone, so it runs only
# on a Mac set aside for testing, never on the one someone is working at (2026-10-31). A machine
# marks itself in its own environment, never in this repository, which knows no machine by name:
#     echo 'export GLYPH_TEST_MACHINE=1' >> ~/.zshenv
# The check is first, before the build and before any window, so an unmarked Mac runs nothing at all.
if [[ -z ${GLYPH_TEST_MACHINE:-} ]]; then
  print -u2 "Not a test machine: this opens real windows and takes the keyboard, the screen and the"
  print -u2 "microphone, so it runs only where GLYPH_TEST_MACHINE=1 is set. Nothing was built or run."
  exit 4
fi

# Built before the lock, so nobody waits on the screen to compile. The output is kept rather than
# thrown away: sending it to /dev/null turned every build failure into a bare exit code, which cost
# two round trips to diagnose once.
mkdir -p "$out"
if ! ./scripts/build.sh > "$out/build.log" 2>&1; then
  print -u2 "the build failed, so nothing was run. Its last 20 lines:"
  tail -20 "$out/build.log" >&2
  exit 1
fi
app="build/Glyph Time.app/Contents/MacOS/GlyphTime"

# One run at a time on this Mac's TEST HARDWARE, not just its screen. Speech, the microphone and
# the screen are one each per Mac, so an iPhone simulator suite running beside a Mac check makes
# every step that waits on real dictation return nothing, and the failure moves from run to run,
# which is why it never reproduced. One lock for the hardware, not one per activity (2026-10-31):
# every run that needs real input or the screen takes THIS lock, Mac checks and
# simulator suites alike. The build lock stays separate and around the compile only: a compile
# contends for the CPU but not for Speech.
# GLYPH_UI_LOCK_HELD=1 says the caller already took it; a lock with no holder is respected,
# never assumed stale.
L=/tmp/glyph-mac-ui.lock.d
took=
if [[ -z ${GLYPH_UI_LOCK_HELD:-} ]]; then
  # The trap goes on BEFORE the lock exists, and the holder is written in the same breath as the
  # mkdir. The old order left a window where the lock existed with no holder and no trap: a run
  # dying in it leaked a lock nobody could attribute, and an unattributable lock is what gets
  # cleared by hand while it is still live (Glyph Omega and Glyph Wealth, 2026-10-31). The app's
  # name comes first so a waiter can say what it is waiting on.
  # TRIES and SLEEP are overridable so the waiting path can be tested without waiting an hour;
  # nothing but a test should set them.
  # Three traps, never one combined, and a release that can only free what this run still holds.
  # A TERM or INT handler that RETURNS counts as handled, so the run carries on driving the screen
  # with the lock already released, and then releases again on the way out, when the lock belongs to
  # another run doing everything right: it carries on believing it is protected and nothing logs
  # that it was robbed. Handlers therefore do nothing but exit; exiting runs the EXIT trap, so the
  # release happens once and the run actually stops. The release clears the flag first and then
  # removes the lock only while the holder still names this pid, so a stray second call cannot take
  # anyone else's. On SIGHUP no trap runs at all, so remote runs go detached (nohup) rather than
  # down a pipe, and an abandoned lock is reclaimed on evidence, never assumed stale.
  # Test this with both halves: the lock is gone AND the work did not continue. A test that checks
  # only the first passes while this is broken.
  release() {
    [[ -n $took ]] || return 0
    took=
    [[ $(awk 'NR==1{print $3}' "$L/holder" 2>/dev/null) == $$ ]] || return 0
    rm -rf "$L"
    return 0
  }
  trap release EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  for _ in $(seq ${GLYPH_LOCK_TRIES:-720}); do
    mkdir "$L" 2>/dev/null && { took=1; printf '%s %s %s %s\n' "time" "$(hostname -s)" "$$" "mac-ui-check" > "$L/holder"; break }
    sleep ${GLYPH_LOCK_SLEEP:-5}
  done
  [[ -n $took ]] || { print -u2 "test hardware held by $(cat $L/holder 2>/dev/null || echo unknown)"; exit 2 }
fi
# A lock only stops a run that declared itself, and on a shared Mac most work has not. So wait for
# the machine to be quiet as well: by runnable processes, never by load average, which stays high
# for minutes after the work stops (found in Glyph Wealth's own runs, 2026-10-31).
# Scaled to the Mac rather than a constant: the same number of runnable processes means different
# things on a four-core and a twelve-core machine, and a check that refuses to run is worse than one
# that warns (found with Glyph Well, 2026-10-31).
busy=$(( $(sysctl -n hw.ncpu) / 2 )); (( busy < 4 )) && busy=4
quiet=
for _ in $(seq 60); do
  # `|| true` is load-bearing on both of these: grep -c exits 1 when the count is zero and pgrep
  # exits 1 when nothing matches, so under `set -e` the unguarded form kills the script exactly
  # when the machine is quiet, and the exit looks like anything but that (Glyph Omega, 2026-10-31).
  r=$(ps -Ao state= | grep -c '^R' || true)
  t=$(pgrep -f 'xcodebuild.*test|CoreSimulator.*XCTest' | wc -l | tr -d ' ' || true)
  (( r <= busy && t == 0 )) && { quiet=1; break }
  [[ -n $quiet ]] || print -u2 "waiting for the machine to be quiet (runnable $r of $busy allowed, test runs $t)"
  quiet=waiting
  sleep 15
done
[[ $quiet == 1 ]] || print -u2 "the machine never went quiet; running anyway, read a failure on a step that waits on input as interference"

# Never quits the installed Glyph Time: the test copy runs beside it (its own folder, its own settings)
# and exits by itself; a watchdog in the app ends a hung run after 10 minutes.
rc=0
for mode in folder vault; do
  dir=$(mktemp -d)
  [[ $mode == vault ]] && mkdir -p "$dir/data/domains/time"
  echo "== $mode"
  look=dark; [[ $mode == vault ]] && look=light  # both appearances, one per run
  GLYPH_TIME_HOST=uitest-local "$app" --uitest "$out/$mode" --appearance $look -folder "$dir" -support "$dir/support" "$@" || rc=1
done
exit $rc
