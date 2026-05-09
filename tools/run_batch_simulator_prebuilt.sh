#!/usr/bin/env bash
# Run forge.tools.BatchRogueSimulator from prebuilt artifacts (no mvn / no compile).
#
# Companion to run_batch_simulator.sh. Use this on machines that don't have
# Maven installed: build the bundle on a dev box with `dependency:copy-dependencies`,
# ship the resulting tree, and invoke this wrapper.
#
# Expects (relative to repo root):
#   forge-gui-desktop/target/classes
#   forge-gui-desktop/target/test-classes
#   forge-gui-desktop/target/lib/*.jar         <-- from `mvn dependency:copy-dependencies`
#   forge-{core,game,ai,gui,gui-mobile}/target/classes
#   forge-gui/res
#   rogue_dck/
#
# Usage matches run_batch_simulator.sh; pass --help for the full CLI.
# Override heap with BATCH_SIM_XMX (default 2048m).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$ROOT/forge-gui-desktop/target/lib"
TEST_CLASSES="$ROOT/forge-gui-desktop/target/test-classes"
MAIN_CLASSES="$ROOT/forge-gui-desktop/target/classes"

if [[ ! -d "$LIB_DIR" ]] || ! compgen -G "$LIB_DIR/*.jar" > /dev/null; then
    echo "[run_batch_simulator_prebuilt] missing $LIB_DIR/*.jar" >&2
    echo "Build the bundle on a machine with mvn:" >&2
    echo "  mvn -pl forge-gui-desktop -q dependency:copy-dependencies \\" >&2
    echo "    -DincludeScope=test -DoutputDirectory=\$PWD/forge-gui-desktop/target/lib" >&2
    exit 1
fi

CP="$TEST_CLASSES:$MAIN_CLASSES"
for m in forge-core forge-game forge-ai forge-gui forge-gui-mobile; do
    if [[ -d "$ROOT/$m/target/classes" ]]; then
        CP="$CP:$ROOT/$m/target/classes"
    fi
done
for jar in "$LIB_DIR"/*.jar; do
    CP="$CP:$jar"
done

JVM_OPTS=(
    -Xmx${BATCH_SIM_XMX:-2048m}
    -Dfile.encoding=UTF-8
    --add-opens java.base/java.util=ALL-UNNAMED
    --add-opens java.base/java.lang=ALL-UNNAMED
    --add-opens java.base/java.lang.reflect=ALL-UNNAMED
    --add-opens java.base/java.text=ALL-UNNAMED
    --add-opens java.base/java.nio=ALL-UNNAMED
    --add-opens java.base/java.util.concurrent=ALL-UNNAMED
    --add-opens java.desktop/java.awt=ALL-UNNAMED
    --add-opens java.desktop/javax.swing=ALL-UNNAMED
    --add-opens java.desktop/sun.awt.image=ALL-UNNAMED
)

# Resolve user-supplied relative paths against the original working directory
# so `--decks-dir rogue_dck` and `--output-dir batches/...` keep working after
# we cd into forge-gui-desktop/ below.
RESOLVED_ARGS=()
HAS_DECKS_DIR=0
HAS_OUTPUT_DIR=0
PREV_KEY=""
for arg in "$@"; do
    case "$PREV_KEY" in
        --decks-dir|--output-dir)
            if [[ "$arg" != /* ]]; then
                arg="$ROOT/$arg"
            fi
            ;;
    esac
    case "$arg" in
        --decks-dir) HAS_DECKS_DIR=1 ;;
        --output-dir) HAS_OUTPUT_DIR=1 ;;
    esac
    RESOLVED_ARGS+=("$arg")
    PREV_KEY="$arg"
done

if [[ "$HAS_DECKS_DIR" == 0 ]]; then
    RESOLVED_ARGS=(--decks-dir "$ROOT/rogue_dck" "${RESOLVED_ARGS[@]}")
fi
if [[ "$HAS_OUTPUT_DIR" == 0 ]]; then
    RESOLVED_ARGS=(--output-dir "$ROOT/batches" "${RESOLVED_ARGS[@]}")
fi

# Forge resolves assets relative to "../forge-gui/" — match the convention
# used by `mvn test` and `forge.view.Main` by running from forge-gui-desktop/.
cd "$ROOT/forge-gui-desktop"

exec java "${JVM_OPTS[@]}" -cp "$CP" forge.tools.BatchRogueSimulator "${RESOLVED_ARGS[@]}"
