#!/bin/bash
# smoke_test_walk.sh - End-to-end smoke test for directory-backend walk driver
#
# Creates a temporary walk with 2 canned issues, runs the driver with a
# mock agent via --command flag, and verifies issues move from open/ to closed/.
#
# Usage:
#   ./test/smoke_test_walk.sh
#
# Exit codes:
#   0 = all checks passed
#   1 = test failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Create temp walk directory
WALK_DIR=$(mktemp -d /tmp/walk-smoke-XXXXXX)
trap "rm -rf $WALK_DIR" EXIT

echo "=== Smoke test: directory-backend walk driver ==="
echo "Walk dir: $WALK_DIR"

# --- Setup walk ---

mkdir -p "$WALK_DIR/open" "$WALK_DIR/closed"

cat > "$WALK_DIR/_walk.md" << 'EOF'
---
title: "Smoke test walk"
status: open
---

A minimal walk for automated testing.
EOF

# Create two canned issues
mkdir -p "$WALK_DIR/open/task-alpha"
cat > "$WALK_DIR/open/task-alpha/issue.md" << 'EOF'
---
title: "Alpha task"
type: task
priority: 1
---

Do the alpha thing.

## Close with

Confirmation that alpha was done.
EOF

mkdir -p "$WALK_DIR/open/task-beta"
cat > "$WALK_DIR/open/task-beta/issue.md" << 'EOF'
---
title: "Beta task"
type: task
priority: 2
---

Do the beta thing.

## Close with

Confirmation that beta was done.
EOF

echo "Created walk with 2 issues."

# --- Verify setup ---

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label"
    exit 1
  fi
}

echo ""
echo "--- Checking setup ---"
check "walk meta exists" test -f "$WALK_DIR/_walk.md"
check "task-alpha exists" test -d "$WALK_DIR/open/task-alpha"
check "task-beta exists" test -d "$WALK_DIR/open/task-beta"
check "closed is empty" test -z "$(ls -A "$WALK_DIR/closed/")"

# --- Run driver with --command flag and mock agent ---

MOCK_AGENT="$SCRIPT_DIR/mock-agent.rb"

echo ""
echo "--- Running driver --once with --command (task-alpha, P1) ---"
"$PROJECT_DIR/bin/walk" run "$WALK_DIR" --once --command "ruby $MOCK_AGENT"

echo ""
echo "--- Checking post-first-run state ---"
check "task-alpha moved to closed" test -d "$WALK_DIR/closed/task-alpha"
check "task-alpha has result.md" test -f "$WALK_DIR/closed/task-alpha/result.md"
check "task-alpha has close.md" test -f "$WALK_DIR/closed/task-alpha/close.md"
check "task-alpha gone from open" test ! -d "$WALK_DIR/open/task-alpha"
check "task-beta still open" test -d "$WALK_DIR/open/task-beta"

echo ""
echo "--- Running driver --once with --command (task-beta, P2) ---"
"$PROJECT_DIR/bin/walk" run "$WALK_DIR" --once --command "ruby $MOCK_AGENT"

echo ""
echo "--- Checking final state ---"
check "open is empty" test -z "$(ls -A "$WALK_DIR/open/")"
check "two closed issues" test "$(ls "$WALK_DIR/closed/" | wc -w)" -eq 2
check "task-alpha closed" test -d "$WALK_DIR/closed/task-alpha"
check "task-beta closed" test -d "$WALK_DIR/closed/task-beta"
check "task-beta has result.md" test -f "$WALK_DIR/closed/task-beta/result.md"

echo ""
echo "=== All smoke tests passed ==="
