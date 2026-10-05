#!/usr/bin/env bash
# Run a command or a local script on the node through SSM and print its output.
#   scripts/remote.sh 'nvidia-smi'
#   scripts/remote.sh -f bootstrap/node.sh
#   scripts/remote.sh -d deploy 'PODB=0 deploy/deploy.sh scenarios/x.yaml'
#   scripts/remote.sh -d 'deploy bench' 'bench/bench.sh s1'
#     (-d ships local directories to /opt/kvdemo/<dir> and runs the command from /opt/kvdemo)
# The full log stays on the node at /var/log/remote-<command-id>.log.
set -euo pipefail
export AWS_PROFILE=${PROFILE:-default}   # same rule as the Makefile

instance_id=$(terraform -chdir="$(dirname "$0")/../infra" output -raw instance_id)

case "${1:-}" in
  -f) body=$(cat "$2") ;;
  -d) bundle=$(tar -czf - --exclude=__pycache__ $2 | base64 -w0)
      body="set -e; mkdir -p /opt/kvdemo; cd /opt/kvdemo; rm -rf $2
echo $bundle | base64 -d | tar -xzf -
$3" ;;
  *)  body="$1" ;;
esac

# Ship the body base64-encoded so quoting survives SSM's JSON parameters.
encoded=$(printf '%s' "$body" | base64 -w0)
# HOME is unset under SSM; Helm keeps its repo config there.
# Run under bash so the exit code is the script's, not tee's (SSM uses /bin/sh, i.e. dash).
params=$(ENCODED="$encoded" python3 -c '
import json, os
run = "HOME=/root bash /tmp/remote.sh 2>&1 | tee /var/log/remote-$(date +%s).log; exit ${PIPESTATUS[0]}"
print(json.dumps({"commands": ["echo " + os.environ["ENCODED"] + " | base64 -d > /tmp/remote.sh",
                               "bash -c '\''" + run + "'\''"],
                  "executionTimeout": ["3600"]}))')

command_id=$(aws ssm send-command \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --parameters "$params" \
  --query Command.CommandId --output text)

while true; do
  status=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in
    Pending|InProgress|Delayed) sleep 5 ;;
    *) break ;;
  esac
done

aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
  --query StandardOutputContent --output text
echo "[remote] status: $status"
[[ "$status" == "Success" ]]
