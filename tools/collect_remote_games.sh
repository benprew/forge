#!/usr/bin/env bash
# Combine BatchRogueSimulator output from every heap-cluster host onto one
# collector host (default: broome) and zip it there.
#
# Companion to tools/run_remote_fanout.sh, which spreads disjoint seed ranges
# across hosts (e.g. seeds 1..6 on broome, 7..12 on crosby, ...). Because the
# seed ranges don't overlap, the run-N directory names from different hosts
# never collide and merge into one tree as-is.
#
# Safe to run while the simulator is still generating: tar exits rc=1 with
# "file changed as we read it" warnings for in-flight batches, which the
# script treats as non-fatal. Any partial .jsonl.gz files captured this way
# will simply fail to decode downstream and should be filtered there.
#
# Each non-collector host streams its batches/run-*/ *directly* to the
# collector via ssh-from-collector (agent-forwarded from local), so the data
# never touches this machine. The collector then zips its now-merged
# batches/ directory.
#
# Prereq: local ssh agent has keys that authenticate to every host
# (`ssh-add -l` should list them); -A forwarding lets the collector reuse
# them when reaching out to the sources.
#
# Usage:
#   tools/collect_remote_games.sh                                  # → broome
#   tools/collect_remote_games.sh --collector btp@crosby.cluster.recurse.com
#   tools/collect_remote_games.sh --output forge-games.zip
#   tools/collect_remote_games.sh --include-logs
#   tools/collect_remote_games.sh --no-zip                         # leave merged batches/ unzipped

set -euo pipefail

DEFAULT_HOSTS="btp@broome.cluster.recurse.com,btp@crosby.cluster.recurse.com,btp@mercer.cluster.recurse.com,btp@greene.cluster.recurse.com"
DEFAULT_COLLECTOR="btp@broome.cluster.recurse.com"
HOSTS_RAW="$DEFAULT_HOSTS"
COLLECTOR="$DEFAULT_COLLECTOR"
REMOTE_DIR="~/forge"
OUTPUT="forge-games-$(date +%Y%m%d-%H%M%S).zip"
INCLUDE_LOGS=0
DO_ZIP=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hosts|--host)   HOSTS_RAW="$2"; shift 2 ;;
        --collector)      COLLECTOR="$2"; shift 2 ;;
        --remote-dir)     REMOTE_DIR="$2"; shift 2 ;;
        --output|-o)      OUTPUT="$2"; shift 2 ;;
        --include-logs)   INCLUDE_LOGS=1; shift ;;
        --no-zip)         DO_ZIP=0; shift ;;
        -h|--help)        sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

IFS=',' read -ra HOSTS <<< "$HOSTS_RAW"

# Sources = every listed host that isn't the collector. Collector's own
# batches/ stays put; only the others need to be transferred.
SOURCES=()
for h in "${HOSTS[@]}"; do
    if [[ "$h" != "$COLLECTOR" ]]; then
        SOURCES+=("$h")
    fi
done

LOG_DIR="$(mktemp -d -t collect_remote_games_logs.XXXXXX)"
trap 'rm -rf "$LOG_DIR"' EXIT

echo "[collect] collector: $COLLECTOR"
echo "[collect] sources:   ${SOURCES[*]:-<none>}"
echo "[collect] output:    $COLLECTOR:$REMOTE_DIR/$OUTPUT"

ssh -o BatchMode=yes -o ConnectTimeout=10 "$COLLECTOR" "mkdir -p $REMOTE_DIR/batches"

pull_to_collector() {
    local source="$1"
    local log="$LOG_DIR/${source//[^A-Za-z0-9._-]/_}.log"
    {
        echo "[collect] [$source → $COLLECTOR] streaming ..."
        # Run a small script ON the collector (via -A agent forwarding). That
        # script ssh's into the source, tars run-* dirs over its stdout, and
        # untars in place. All bytes flow source → collector directly.
        ssh -A -o BatchMode=yes -o ConnectTimeout=10 "$COLLECTOR" \
            bash -s -- "$source" "$REMOTE_DIR" "$INCLUDE_LOGS" <<'REMOTE'
set -euo pipefail
SOURCE="$1"
REMOTE_DIR="$2"
INCLUDE_LOGS="$3"
# List the run-* directories themselves (not the .jsonl.gz files inside) so
# tar recurses once — listing both produces duplicate entries that fail
# extraction with "hardlink pointing to itself".
if [[ "$INCLUDE_LOGS" == 1 ]]; then
    FIND_CLAUSE='\( -type d -name "run-*" -o -type f -name "run-*.log" \)'
else
    FIND_CLAUSE='\( -type d -name "run-*" \)'
fi
# StrictHostKeyChecking=accept-new: TOFU first contact, reject later mismatches.
# Without this, brand-new sources fail with "Host key verification failed" on
# the collector since it has never connected to them before.
#
# --ignore-failed-read: source tar tolerates files that vanish between find
# and read (e.g. batch file rotated out under us).
#
# We disable errexit/pipefail around the pipeline so we can inspect both pipe
# stages: source tar rc=1 ("file changed as we read it") is a soft warning we
# accept; rc>=2 is a real failure.
set +e
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$SOURCE" \
    "cd $REMOTE_DIR && find batches -mindepth 1 -maxdepth 1 $FIND_CLAUSE -print0 | tar --null -T - --ignore-failed-read -cf -" \
    | tar xf - -C "$REMOTE_DIR"
src_rc="${PIPESTATUS[0]}"
dst_rc="${PIPESTATUS[1]}"
set -e
if (( src_rc > 1 )); then
    echo "source tar on $SOURCE failed (rc=$src_rc)" >&2
    exit 1
fi
if (( dst_rc != 0 )); then
    echo "destination tar failed (rc=$dst_rc)" >&2
    exit 1
fi
if (( src_rc == 1 )); then
    echo "(source tar reported files changing during read — accepted)"
fi
REMOTE
        local rc=$?
        if [[ $rc != 0 ]]; then
            echo "[collect] [$source] FAILED (rc=$rc)"
            exit 1
        fi
        echo "[collect] [$source] OK"
    } > "$log" 2>&1
}

if (( ${#SOURCES[@]} > 0 )); then
    echo "[collect] pulling from ${#SOURCES[@]} source(s) → $COLLECTOR in parallel ..."
    PIDS=()
    for s in "${SOURCES[@]}"; do
        pull_to_collector "$s" &
        PIDS+=($!)
    done

    FAILED=0
    for i in "${!SOURCES[@]}"; do
        s="${SOURCES[$i]}"
        pid="${PIDS[$i]}"
        log="$LOG_DIR/${s//[^A-Za-z0-9._-]/_}.log"
        if wait "$pid"; then
            cat "$log"
        else
            echo "----- [$s] FAILED -----" >&2
            cat "$log" >&2
            echo "-----------------------" >&2
            FAILED=1
        fi
    done

    if [[ "$FAILED" == 1 ]]; then
        echo "[collect] one or more transfers failed; partial state on $COLLECTOR" >&2
        exit 1
    fi
fi

ssh -o BatchMode=yes "$COLLECTOR" "cd $REMOTE_DIR && \
    runs=\$(find batches -mindepth 1 -maxdepth 1 -type d -name 'run-*' | wc -l | tr -d ' ') && \
    games=\$(find batches -name '*.jsonl.gz' | wc -l | tr -d ' ') && \
    echo \"[collect] $COLLECTOR now has \$runs run-* dirs, \$games game files\""

if [[ "$DO_ZIP" == 0 ]]; then
    echo "[collect] --no-zip: stopped after merge. Tree at $COLLECTOR:$REMOTE_DIR/batches"
    exit 0
fi

# -0: store, don't recompress (.jsonl.gz files are already compressed).
echo "[collect] zipping on $COLLECTOR → $REMOTE_DIR/$OUTPUT ..."
ssh -o BatchMode=yes "$COLLECTOR" "cd $REMOTE_DIR && zip -0 -qr $OUTPUT batches && du -h $OUTPUT"

echo "[collect] done. Pull it down with:"
echo "    scp $COLLECTOR:$REMOTE_DIR/$OUTPUT ."
