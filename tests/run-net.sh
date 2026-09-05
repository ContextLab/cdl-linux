#!/usr/bin/env bash
# The checksum assertions that download real release assets: uv, codex, opencode, ollama,
# llama.cpp, llama-swap, the Nerd Font. Hundreds of megabytes, minutes, and a network --
# which is why run-all.sh skips them by default and this runs them on purpose.
#
# Usage: tests/run-net.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export CDL_NET_TESTS=1
fail=0
for suite in tests/test-agents.sh tests/test-nvidia-ml.sh tests/test-models-gpu-lock.sh tests/test-console.sh; do
    [ -e "$suite" ] || continue
    printf '\n--- %s (network) ---\n' "$suite"
    "./$suite" || fail=$((fail + 1))
done
printf '\n  network suites failed: %d\n' "$fail"
[ "$fail" -eq 0 ]
