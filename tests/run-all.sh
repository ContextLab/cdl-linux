#!/usr/bin/env bash
# Runs every check in the repository: shell syntax, ShellCheck, and each test suite.
#
# One command, one exit code, and a count printed at the end — so a claim that "the tests
# pass" can be quoted from output rather than remembered.
#
# Usage: tests/run-all.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

suites_run=0
suites_failed=0
lint_files=0

printf '\033[1m== shell syntax and lint ==\033[0m\n'
have_shellcheck=1
command -v shellcheck >/dev/null 2>&1 || { have_shellcheck=0; echo "  shellcheck not installed — syntax only"; }

# scripts/vm/*.sh source a sibling lib.sh, so they need -x to resolve it. Globbing the
# subdirectory explicitly rather than recursively keeps the set of linted files visible.
for f in scripts/*.sh scripts/vm/*.sh tests/*.sh; do
    [[ -e "$f" ]] || continue
    lint_files=$((lint_files + 1))
    if ! bash -n "$f"; then
        printf '  \033[31mSYNTAX FAIL\033[0m %s\n' "$f"
        suites_failed=$((suites_failed + 1))
        continue
    fi
    if [[ $have_shellcheck -eq 1 ]] && ! (cd "$(dirname "$f")" && shellcheck -x "$(basename "$f")"); then
        printf '  \033[31mSHELLCHECK FAIL\033[0m %s\n' "$f"
        suites_failed=$((suites_failed + 1))
        continue
    fi
    printf '  \033[32mOK\033[0m  %s\n' "$f"
done

printf '\n\033[1m== test suites ==\033[0m\n'
for suite in tests/test-*.sh; do
    [[ -e "$suite" ]] || continue
    suites_run=$((suites_run + 1))
    printf '\n--- %s ---\n' "$suite"
    if ! "./$suite"; then
        suites_failed=$((suites_failed + 1))
    fi
done

# Python suites. The schema tests extract the DDL from the spec and run it, because the
# defects that survived longest in review were all cases where prose and schema disagreed
# and only executing the SQL could tell.
for suite in tests/test-*.py; do
    [[ -e "$suite" ]] || continue
    suites_run=$((suites_run + 1))
    printf '\n--- %s ---\n' "$suite"
    # No pipe: piping to `tail` would make the exit status tail's, so a failing suite
    # would report success. unittest prints its summary to stderr already.
    if ! python3 "$suite"; then
        suites_failed=$((suites_failed + 1))
    fi
done

printf '\n\033[1m== summary ==\033[0m\n'
printf '  shell files linted: %d\n' "$lint_files"
printf '  test suites run:    %d\n' "$suites_run"
printf '  failures:           %d\n' "$suites_failed"

if [[ $suites_failed -eq 0 ]]; then
    printf '\033[32mALL CHECKS PASSED\033[0m\n'
    exit 0
fi
printf '\033[31m%d CHECK(S) FAILED\033[0m\n' "$suites_failed"
exit 1
