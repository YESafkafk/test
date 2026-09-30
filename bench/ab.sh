#!/bin/sh
# Compare two builds by interleaving their benchmark runs (A B A B ...), so
# that slow drift of the machine (CPU frequency, other load) affects both
# equally.  The merged samples are compared with bench/compare.ss.
#
#   bench/ab.sh [-r ROUNDS] [-o DIR] [-c CPU] -- "COMMAND A" "COMMAND B" [BENCH OPTIONS...]
#
# COMMAND A / B run the benchmarks of one build, e.g.
#   "scheme -q --libdirs old/build/lib:old --script old/bench/run.ss"
#   ./result-a/bin/chezterm-bench          (nix build .#bench -o result-a)
# BENCH OPTIONS are passed to both (e.g. --only render).  Each round runs
# every benchmark with 3 iterations; ROUNDS defaults to 5.  With -c the
# runs are pinned to that CPU with taskset.
#
# Environment: COMPARE, the compare command (default: the compare.ss next
# to this script, run with scheme).
set -eu

rounds=5
out=
cpu=
while [ $# -gt 0 ]; do
    case "$1" in
        -r) rounds=$2; shift 2 ;;
        -o) out=$2; shift 2 ;;
        -c) cpu=$2; shift 2 ;;
        --) shift; break ;;
        *) echo "usage: $0 [-r ROUNDS] [-o DIR] [-c CPU] -- \"COMMAND A\" \"COMMAND B\" [BENCH OPTIONS...]" >&2
           exit 2 ;;
    esac
done
if [ $# -lt 2 ]; then
    echo "$0: need two benchmark commands" >&2
    exit 2
fi
a=$1
b=$2
shift 2

here=$(cd "$(dirname "$0")" && pwd)
: "${COMPARE:=scheme -q --libdirs $here/../tools --script $here/compare.ss}"
if [ -z "$out" ]; then
    out=$(mktemp -d "${TMPDIR:-/tmp}/chezterm-ab.XXXXXX")
fi
mkdir -p "$out"

pin=
if [ -n "$cpu" ]; then
    pin="taskset -c $cpu"
fi

i=1
while [ "$i" -le "$rounds" ]; do
    for side in a b; do
        if [ "$side" = a ]; then cmd=$a; else cmd=$b; fi
        echo "round $i/$rounds: $side" >&2
        # shellcheck disable=SC2086  # the commands are meant to be split
        $pin $cmd --iterations 3 --out "$out/$side-$i.json" "$@" > "$out/$side-$i.log"
    done
    i=$((i + 1))
done

old=
new=
i=1
while [ "$i" -le "$rounds" ]; do
    old="$old $out/a-$i.json"
    new="$new $out/b-$i.json"
    i=$((i + 1))
done
echo "results in $out" >&2
# shellcheck disable=SC2086
exec $COMPARE --old $old --new $new
