#!/usr/bin/env bash
# Mutation-testing sample runner for the src/libraries/logic mutation campaign.
#
# Requires: gambit (cargo install --git https://github.com/Certora/gambit.git, or a release
# binary from https://github.com/Certora/gambit/releases on PATH) and foundry.
#
# What it does:
#   1. Generates mutants for every file listed in gambit-logic-libraries.json.
#   2. Randomly samples up to SAMPLE_SIZE mutants (default 100).
#   3. For each sampled mutant: patches the source in place, runs the unit + fuzz kill suite,
#      records killed (suite fails) vs survived (suite passes), and restores the source.
#   4. Prints the kill rate and writes survivors to output/mutation/survivors.txt.
#
# A surviving mutant means the unit + fuzz layer cannot distinguish that mutation from
# production, which is a coverage gap to triage (not automatically a bug).
#
# Usage: scripts/mutation/run-mutation-sample.sh [SAMPLE_SIZE]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAMPLE_SIZE="${1:-100}"
CONF="$REPO_ROOT/scripts/mutation/gambit-logic-libraries.json"
OUT_DIR="$REPO_ROOT/output/mutation"
GAMBIT_OUT="$OUT_DIR/gambit_out"
# The kill suite: the deterministic unit vectors plus the fuzz layer, low run count for per-mutant speed
KILL_SUITE=(forge test --match-path "test/{unit,fuzz}/**/*.t.sol" --fuzz-runs 64 --fail-fast)

command -v gambit >/dev/null 2>&1 || {
  echo "gambit not found on PATH; install it first (see header comment)" >&2
  exit 1
}

cd "$REPO_ROOT"
mkdir -p "$OUT_DIR"

# Refuse to run on a dirty tree, because the runner patches sources in place
if ! git diff --quiet -- src/; then
  echo "src/ has uncommitted changes; commit or stash before running mutation testing" >&2
  exit 1
fi

echo "Generating mutants from $CONF ..."
gambit mutate --json "$CONF" --outdir "$GAMBIT_OUT" --skip_validate

MUTANT_LOG="$GAMBIT_OUT/gambit_results.json"
TOTAL=$(python3 -c "import json; print(len(json.load(open('$MUTANT_LOG'))))")
echo "Generated $TOTAL mutants; sampling up to $SAMPLE_SIZE"

# Sample mutant ids uniformly without replacement
SAMPLED_IDS=$(python3 - "$MUTANT_LOG" "$SAMPLE_SIZE" <<'PY'
import json, random, sys
mutants = json.load(open(sys.argv[1]))
random.seed(42)
sample = random.sample(mutants, min(int(sys.argv[2]), len(mutants)))
print("\n".join(m["id"] for m in sample))
PY
)

KILLED=0
SURVIVED=0
: > "$OUT_DIR/survivors.txt"

for MUTANT_ID in $SAMPLED_IDS; do
  ORIGINAL=$(python3 -c "import json,sys; ms=json.load(open('$MUTANT_LOG')); print(next(m['original'] for m in ms if m['id']=='$MUTANT_ID'))")
  MUTATED="$GAMBIT_OUT/mutants/$MUTANT_ID/$ORIGINAL"
  cp "$ORIGINAL" "$ORIGINAL.bak"
  cp "$MUTATED" "$ORIGINAL"
  if "${KILL_SUITE[@]}" >/dev/null 2>&1; then
    SURVIVED=$((SURVIVED + 1))
    echo "$MUTANT_ID $ORIGINAL" >> "$OUT_DIR/survivors.txt"
    echo "SURVIVED: mutant $MUTANT_ID in $ORIGINAL"
  else
    KILLED=$((KILLED + 1))
  fi
  mv "$ORIGINAL.bak" "$ORIGINAL"
done

RAN=$((KILLED + SURVIVED))
echo "----------------------------------------"
echo "Mutants run: $RAN | killed: $KILLED | survived: $SURVIVED"
if [ "$RAN" -gt 0 ]; then
  echo "Kill rate: $(python3 -c "print(f'{100 * $KILLED / $RAN:.1f}%')")"
fi
echo "Survivors listed in $OUT_DIR/survivors.txt"
