#!/usr/bin/env bash
# Build (if needed) and run forge.tools.BatchRogueSimulator.
#
# Usage examples:
#   tools/run_batch_simulator.sh --count 5000 --output-dir batches/run01 --seed 42
#   tools/run_batch_simulator.sh --count 5 --output-dir /tmp/tiny --seed 1   # smoke test
#
# Forwards all CLI args to the Java tool. Pass --help for the full list.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CP_FILE="$ROOT/forge-gui-desktop/target/batch-rogue-simulator.cp"
TARGET_DIR="$ROOT/forge-gui-desktop/target"
TEST_CLASSES="$TARGET_DIR/test-classes"
MAIN_CLASSES="$TARGET_DIR/classes"
MARKER="$TARGET_DIR/.batch_rogue_simulator_compiled"
SRC="$ROOT/forge-gui-desktop/src/test/java/forge/tools/BatchRogueSimulator.java"

# Build test classes + dependency classpath if missing or stale.
if [[ ! -f "$MARKER" || "$SRC" -nt "$MARKER" ]]; then
    # Install the sibling forge:* modules that forge-gui-desktop depends on
    # (skipping forge-gui-desktop itself: its `package` phase runs launch4j,
    # which has no Apple-silicon binary).
    # The reactor uses ${revision} as the version everywhere, but the project
    # only flattens POMs at the deploy phase. We need flattened POMs *installed*
    # so downstream modules can resolve them, so chain flatten:flatten with install.
    echo "[run_batch_simulator] installing flattened parent pom ..."
    mvn flatten:flatten install -N -q -DskipTests \
        -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true
    echo "[run_batch_simulator] running flatten+install for sibling modules ..."
    mvn -pl forge-core,forge-game,forge-ai,forge-gui flatten:flatten install -q \
        -DskipTests -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true
    echo "[run_batch_simulator] running 'mvn test-compile' for forge-gui-desktop ..."
    mvn -pl forge-gui-desktop test-compile -q \
        -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true
    echo "[run_batch_simulator] writing dependency classpath to $CP_FILE ..."
    mvn -pl forge-gui-desktop dependency:build-classpath -q \
        -Dmdep.outputFile="$CP_FILE" -Dmdep.includeScope=test \
        -Dmaven.javadoc.skip=true
    touch "$MARKER"
fi

DEP_CP="$(cat "$CP_FILE")"
CP="$TEST_CLASSES:$MAIN_CLASSES:$DEP_CP"

# Resolve sibling-module classes too (forge-game etc. compiled into their own targets).
for m in forge-core forge-game forge-ai forge-gui forge-gui-mobile; do
    if [[ -d "$ROOT/$m/target/classes" ]]; then
        CP="$CP:$ROOT/$m/target/classes"
    fi
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

# Forge resolves assets relative to "../forge-gui/" — match the convention
# used by `mvn test` and `forge.view.Main` by running from forge-gui-desktop/.
cd "$ROOT/forge-gui-desktop"

# Resolve user-supplied relative paths against the original working directory
# so `--decks-dir rogue_dck` and `--output-dir batches/...` keep working.
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

# Inject defaults rooted at the repo root if the caller didn't supply paths.
if [[ "$HAS_DECKS_DIR" == 0 ]]; then
    RESOLVED_ARGS=(--decks-dir "$ROOT/rogue_dck" "${RESOLVED_ARGS[@]}")
fi
if [[ "$HAS_OUTPUT_DIR" == 0 ]]; then
    RESOLVED_ARGS=(--output-dir "$ROOT/batches" "${RESOLVED_ARGS[@]}")
fi

exec java "${JVM_OPTS[@]}" -cp "$CP" forge.tools.BatchRogueSimulator "${RESOLVED_ARGS[@]}"
