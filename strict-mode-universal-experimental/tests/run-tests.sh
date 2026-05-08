#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

ruby "$ROOT/tools/validate-metadata.rb"
ruby "$ROOT/tools/check-metadata-generated.rb"
ruby "$ROOT/tools/test-metadata-validator.rb"
ruby "$ROOT/tools/test-metadata-generator.rb"
ruby "$ROOT/tests/test-provider-detection.rb"
ruby "$ROOT/tests/test-normalized-events.rb"
ruby "$ROOT/tests/test-decisions.rb"
ruby "$ROOT/tests/test-internal-decision.rb"
ruby "$ROOT/tests/test-protected-config.rb"
ruby "$ROOT/tests/test-destructive-gate.rb"
ruby "$ROOT/tests/test-protected-baseline.rb"
ruby "$ROOT/tests/test-preflight-record.rb"
ruby "$ROOT/tests/test-hook-preflight.rb"
ruby "$ROOT/tools/validate-fixtures.rb"
ruby "$ROOT/tests/test-fixtures.rb"
ruby "$ROOT/tests/test-fixture-readiness.rb"
ruby "$ROOT/tests/test-hook-entry-plan.rb"
ruby "$ROOT/tests/test-install-hook-plan.rb"
ruby "$ROOT/tests/test-installer.rb"
