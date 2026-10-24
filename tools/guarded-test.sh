#!/bin/bash
# swift test in AKitCore under a memory and time guard. `ulimit -v` does nothing on macOS, and a
# runaway test once ate 35 GB, so this watches the run itself: every 5 s it reads the memory of
# swift test and every process under it with top (ps RSS misses compressed memory), and kills that
# process tree by PID when one process goes above GUARD_MB (default 1536 MB = 1.5 GB) or the run
# takes longer than GUARD_MINUTES (default 10). Exit: swift test's code, or 3 with the reason.
#
#   tools/guarded-test.sh --filter AKitKnowledgeTests
#   GUARD_MINUTES=25 tools/guarded-test.sh
set -u

limit_mb=${GUARD_MB:-1536}
minutes=${GUARD_MINUTES:-10}
cd "$(dirname "$0")/../AKitCore" || exit 2

echo "guarded-test: swift test $* (stops above ${limit_mb} MB per process or after ${minutes} min)"
swift test "$@" &
pid=$!

# The PIDs of every process under $1 (children first found with pgrep -P, then theirs).
descendants() {
    local child
    for child in $(pgrep -P "$1"); do
        echo "$child"
        descendants "$child"
    done
}

# top's MEM column (12M, 1024K, 1.5G, 300B, maybe with a trailing + or -) in whole MB.
to_mb() {
    local value=${1%[+-]}
    local number=${value%[BKMG]}
    case "$value" in
        *G) awk -v n="$number" 'BEGIN { printf "%d", n * 1024 }' ;;
        *M) awk -v n="$number" 'BEGIN { printf "%d", n }' ;;
        *K) awk -v n="$number" 'BEGIN { printf "%d", n / 1024 }' ;;
        *) echo 0 ;;
    esac
}

stop_tree() {
    local pids
    pids="$pid $(descendants "$pid")"
    kill -TERM $pids 2>/dev/null
    sleep 2
    kill -KILL $pids $(descendants "$pid") 2>/dev/null
    wait "$pid" 2>/dev/null
}

deadline=$(( $(date +%s) + minutes * 60 ))
while kill -0 "$pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        stop_tree
        echo "guarded-test: stopped after ${minutes} min (GUARD_MINUTES sets the limit)" >&2
        exit 3
    fi
    pids="$pid $(descendants "$pid")"
    args=()
    for p in $pids; do args+=(-pid "$p"); done
    # Lines after the header: "PID MEM".
    while read -r one mem; do
        case "$one" in ''|*[!0-9]*) continue ;; esac
        mb=$(to_mb "$mem")
        if [ "$mb" -gt "$limit_mb" ]; then
            name=$(ps -o comm= -p "$one" 2>/dev/null)
            stop_tree
            echo "guarded-test: stopped: process $one (${name:-?}) used ${mb} MB, over ${limit_mb} MB (GUARD_MB sets the limit)" >&2
            exit 3
        fi
    done < <(top -l 1 "${args[@]}" -stats pid,mem 2>/dev/null)
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
done

wait "$pid"
status=$?
echo "guarded-test: swift test exited with $status"
exit "$status"
