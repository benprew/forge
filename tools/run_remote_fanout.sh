#!/usr/bin/env bash
# Launch BatchRogueSimulator across multiple remote hosts.
#
# Defaults: 4 hosts × 6 procs/host × 10000 games/proc = 240k games.
# Seeds are assigned disjointly across all (host, proc) pairs so no two
# processes generate the same games.
#
# Each remote process is started with nohup + & so the launcher SSH session
# can disconnect cleanly while the workload keeps running.
#
# Usage:
#   tools/run_remote_fanout.sh                                     # defaults
#   tools/run_remote_fanout.sh --procs 4 --count 5000              # 4×4 = 16 procs
#   tools/run_remote_fanout.sh --hosts btp@a,btp@b
#   tools/run_remote_fanout.sh --check                             # show running procs/log tails

set -euo pipefail

DEFAULT_HOSTS="btp@broome.cluster.recurse.com,btp@crosby.cluster.recurse.com,btp@mercer.cluster.recurse.com,btp@greene.cluster.recurse.com"
HOSTS_RAW="$DEFAULT_HOSTS"
PROCS_PER_HOST=6
COUNT_PER_PROC=10000
REMOTE_DIR="~/forge"
SEED_BASE=1
MODE="launch"   # launch | check | stop

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hosts|--host)  HOSTS_RAW="$2"; shift 2 ;;
        --procs)         PROCS_PER_HOST="$2"; shift 2 ;;
        --count)         COUNT_PER_PROC="$2"; shift 2 ;;
        --remote-dir)    REMOTE_DIR="$2"; shift 2 ;;
        --seed-base)     SEED_BASE="$2"; shift 2 ;;
        --check)         MODE="check"; shift ;;
        --stop)          MODE="stop"; shift ;;
        -h|--help)       sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

IFS=',' read -ra HOSTS <<< "$HOSTS_RAW"

launch_on_host() {
    local host="$1"
    local seed_start="$2"
    local seed_end="$3"
    echo "[launch] [$host] seeds $seed_start..$seed_end (count=$COUNT_PER_PROC each) ..."
    # The remote script is sent over stdin via heredoc. Configuration is passed
    # as environment in the ssh command line so the remote bash sees it without
    # needing AcceptEnv tweaks on the server.
    ssh "$host" \
        "cd $REMOTE_DIR && SEED_START=$seed_start SEED_END=$seed_end COUNT=$COUNT_PER_PROC bash -s" <<'REMOTE'
set -euo pipefail
mkdir -p batches
for i in $(seq "$SEED_START" "$SEED_END"); do
  nohup tools/run_batch_simulator_prebuilt.sh \
    --count "$COUNT" --output-dir "batches/run-$i" --seed "$i" \
    > "batches/run-$i.log" 2>&1 &
done
echo "  launched seeds $SEED_START..$SEED_END (pids: $(jobs -p | tr '\n' ' '))"
REMOTE
}

check_on_host() {
    local host="$1"
    echo "=== [$host] ==="
    ssh "$host" "cd $REMOTE_DIR && \
        echo 'running procs:' && \
        pgrep -af 'BatchRogueSimulator' | wc -l && \
        echo 'log tails:' && \
        for f in batches/run-*.log; do \
            [ -e \"\$f\" ] || continue; \
            printf '%-30s %s\n' \"\$f\" \"\$(grep batch \"\$f\" | tail -n1)\"; \
        done"
}

stop_on_host() {
    local host="$1"
    echo "[stop] [$host] killing BatchRogueSimulator processes ..."
    ssh "$host" "pkill -f BatchRogueSimulator || true; sleep 1; pgrep -af BatchRogueSimulator || echo '  (none running)'"
}

case "$MODE" in
    launch)
        SEED=$SEED_BASE
        PIDS=()
        for h in "${HOSTS[@]}"; do
            seed_start=$SEED
            seed_end=$((SEED + PROCS_PER_HOST - 1))
            launch_on_host "$h" "$seed_start" "$seed_end" &
            PIDS+=($!)
            SEED=$((seed_end + 1))
        done
        FAILED=0
        for pid in "${PIDS[@]}"; do wait "$pid" || FAILED=1; done
        if [[ "$FAILED" == 1 ]]; then echo "[launch] some hosts failed." >&2; exit 1; fi
        TOTAL_PROCS=$((${#HOSTS[@]} * PROCS_PER_HOST))
        TOTAL_GAMES=$((TOTAL_PROCS * COUNT_PER_PROC))
        echo "[launch] all hosts kicked off."
        echo "[launch] $TOTAL_PROCS procs × $COUNT_PER_PROC games = $TOTAL_GAMES games total."
        echo "[launch] check progress: tools/run_remote_fanout.sh --check"
        ;;
    check)
        for h in "${HOSTS[@]}"; do check_on_host "$h"; done
        ;;
    stop)
        for h in "${HOSTS[@]}"; do stop_on_host "$h" & done
        wait
        ;;
esac
