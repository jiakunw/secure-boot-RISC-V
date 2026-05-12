#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mode="${1:---quick}"
case "$mode" in
  --quick)
    bash "$DIR/run_quick.sh"
    ;;
  --sim)
    bash "$DIR/run_sim_suite.sh"
    ;;
  --all)
    bash "$DIR/run_quick.sh"
    bash "$DIR/run_sim_suite.sh"
    ;;
  *)
    echo "usage: bash validation_tests/run_all.sh [--quick|--sim|--all]"
    exit 2
    ;;
esac
