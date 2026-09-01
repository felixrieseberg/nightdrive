#!/bin/bash
set -euo pipefail

PERFORMANCE_BENCHMARK_CASES=idle \
  exec "$(dirname "$0")/benchmark-performance.sh" "${1:-release}"
