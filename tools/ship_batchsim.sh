#!/usr/bin/env bash
# Build the BatchRogueSimulator bundle locally and ship it to one or more remotes.
#
# Pipeline:
#   1. mvn test-compile (refresh classes if sources changed)
#   2. mvn dependency:copy-dependencies → forge-gui-desktop/target/lib/
#   3. tar czf forge-batchsim.tar.gz
#   4. scp + extract on each remote (parallel across hosts)
#
# Defaults ship to all 4 broome-cluster hosts; override with --hosts.
#
# Usage:
#   tools/ship_batchsim.sh                                       # full pipeline, all 4 hosts
#   tools/ship_batchsim.sh --no-build                            # reuse existing target/ trees
#   tools/ship_batchsim.sh --hosts btp@broome.cluster.recurse.com,btp@crosby.cluster.recurse.com
#   tools/ship_batchsim.sh --no-deploy                           # build tarball only


set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEFAULT_HOSTS="btp@broome.cluster.recurse.com,btp@crosby.cluster.recurse.com,btp@mercer.cluster.recurse.com,btp@greene.cluster.recurse.com"
HOSTS_RAW="$DEFAULT_HOSTS"
REMOTE_DIR="~/forge"
TARBALL="forge-batchsim.tar.gz"
DO_BUILD=1
DO_DEPLOY=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)  DO_BUILD=0; shift ;;
        --no-deploy) DO_DEPLOY=0; shift ;;
        --hosts|--host) HOSTS_RAW="$2"; shift 2 ;;
        --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
        --tarball)   TARBALL="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,17p' "$0"; exit 0 ;;
        *)
            echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

IFS=',' read -ra HOSTS <<< "$HOSTS_RAW"

if [[ "$DO_BUILD" == 1 ]]; then
    # -am pulls the parent reactor in so ${revision} resolves and
    # flatten-maven-plugin produces correct flattened POMs in each module —
    # otherwise we hit "forge:forge:pom:${revision} not found" failures when
    # local m2 has stale unflattened forge:* POMs. -U forces re-resolution
    # past any cached negative lookups.
    echo "[ship] mvn test-compile + copy-dependencies (forge-gui-desktop + reactor) ..."
    mvn -pl forge-gui-desktop -am -U -q \
        test-compile dependency:copy-dependencies \
        -DincludeScope=test \
        -DoutputDirectory="$ROOT/forge-gui-desktop/target/lib" \
        -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true
fi

REQUIRED=(
    forge-gui-desktop/target/classes
    forge-gui-desktop/target/test-classes
    forge-gui-desktop/target/lib
    forge-core/target/classes
    forge-game/target/classes
    forge-ai/target/classes
    forge-gui/target/classes
    forge-gui/res
    rogue_dck
    tools/run_batch_simulator.sh
    tools/run_batch_simulator_prebuilt.sh
)
for path in "${REQUIRED[@]}"; do
    if [[ ! -e "$path" ]]; then
        echo "[ship] missing required path: $path" >&2
        echo "       run without --no-build to rebuild artifacts." >&2
        exit 1
    fi
done

PACK=("${REQUIRED[@]}")

echo "[ship] building $TARBALL ..."
COPYFILE_DISABLE=1 tar czf "$TARBALL" "${PACK[@]}"
TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
echo "[ship] tarball ready: $TARBALL ($TARBALL_SIZE)"

if [[ "$DO_DEPLOY" == 0 ]]; then
    echo "[ship] --no-deploy: skipping scp and remote extract."
    exit 0
fi

LOG_DIR="$(mktemp -d -t ship_batchsim.XXXXXX)"
trap 'rm -rf "$LOG_DIR"' EXIT

deploy_to_host() {
    local host="$1"
    local log="$LOG_DIR/${host//[^A-Za-z0-9._-]/_}.log"
    {
        echo "[ship] [$host] mkdir -p $REMOTE_DIR ..."
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "mkdir -p $REMOTE_DIR" \
            || { echo "[ship] [$host] mkdir FAILED"; exit 1; }
        echo "[ship] [$host] scp ..."
        scp -o BatchMode=yes -o ConnectTimeout=10 "$TARBALL" "$host:$REMOTE_DIR/" \
            || { echo "[ship] [$host] scp FAILED"; exit 1; }
        echo "[ship] [$host] extracting ..."
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
            "cd $REMOTE_DIR && tar xzf $TARBALL" \
            || { echo "[ship] [$host] extract FAILED"; exit 1; }
        echo "[ship] [$host] OK"
    } > "$log" 2>&1
}

echo "[ship] deploying to ${#HOSTS[@]} host(s) in parallel ..."
PIDS=()
for h in "${HOSTS[@]}"; do
    deploy_to_host "$h" &
    PIDS+=($!)
done

FAILED=0
for i in "${!HOSTS[@]}"; do
    h="${HOSTS[$i]}"
    pid="${PIDS[$i]}"
    log="$LOG_DIR/${h//[^A-Za-z0-9._-]/_}.log"
    if wait "$pid"; then
        cat "$log"
    else
        echo "----- [$h] FAILED -----" >&2
        cat "$log" >&2
        echo "-----------------------" >&2
        FAILED=1
    fi
done

if [[ "$FAILED" == 1 ]]; then
    echo "[ship] one or more deploys failed (see per-host output above)." >&2
    echo "[ship] hint: first-time SSH to a host needs key-based auth and a known_hosts entry." >&2
    echo "[ship]       try:  ssh -o BatchMode=yes <host> hostname" >&2
    exit 1
fi

echo "[ship] done. Smoke test on each host:"
for h in "${HOSTS[@]}"; do
    echo "       ssh $h 'cd $REMOTE_DIR && tools/run_batch_simulator_prebuilt.sh --count 1 --output-dir /tmp/smoke --seed 0'"
done
echo "[ship] then launch the fan-out:"
echo "       tools/run_remote_fanout.sh"
