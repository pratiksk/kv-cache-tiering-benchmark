#!/usr/bin/env bash
# Deploy one scenario and benchmark it.   bench/scenario.sh s3 [RUNS=3]
set -euo pipefail
cd "$(dirname "$0")/.."
file=$(ls deploy/scenarios/"$1"-*.yaml)
name=$(basename "$file" .yaml)
args=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1])).get("bench", ""))' "$file")
deploy/deploy.sh "${file#deploy/}"
bench/bench.sh "$name" $args
