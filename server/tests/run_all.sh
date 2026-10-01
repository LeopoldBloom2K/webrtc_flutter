#!/usr/bin/env bash
# 전체 검증. server/ 에서 실행:  bash tests/run_all.sh
set -u
cd "$(dirname "$0")/.."
fail=0
for t in test_signaling test_audio test_relay test_detect test_integration test_auth; do
  printf '%-20s' "$t"
  out=$(python3 "tests/$t.py" 2>&1)
  line=$(echo "$out" | tail -1)
  echo "$line"
  echo "$line" | grep -q "^  \([0-9]*\)/\1 통과$" || { fail=1; echo "$out" | grep -E "^  FAIL"; }
done
exit $fail
