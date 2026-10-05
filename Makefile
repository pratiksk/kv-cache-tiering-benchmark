# Shell may export another profile; Terraform and the AWS CLI always use this one.
# Override with: make <target> PROFILE=name
PROFILE ?= default
export AWS_PROFILE := $(PROFILE)
export AWS_REGION  ?= us-east-1
unexport AWS_DEFAULT_PROFILE

# An S3 bucket you already own, for Terraform state and results (no default):
#   export STATE_BUCKET=my-bucket   or   make up STATE_BUCKET=my-bucket
STATE_BUCKET ?=
TF := terraform -chdir=infra
export TF_VAR_state_bucket := $(STATE_BUCKET)
INSTANCE_ID = $(shell $(TF) output -raw instance_id 2>/dev/null)
RESULTS_URI = s3://$(STATE_BUCKET)/kv-cache-demo/results/

check-bucket:
	@test -n "$(STATE_BUCKET)" || { echo "Set STATE_BUCKET to an existing S3 bucket you own, e.g. export STATE_BUCKET=my-bucket"; exit 1; }

.PHONY: check-bucket init plan up down ssh gpu bootstrap deploy scenario bench snapshot results report grafana status stop start leftovers

init: check-bucket
	$(TF) init -reconfigure -backend-config="bucket=$(STATE_BUCKET)"

plan: init
	$(TF) plan

up: init
	$(TF) apply

down: check-bucket
	$(TF) destroy
	@$(MAKE) --no-print-directory leftovers

ssh:
	aws ssm start-session --target $(INSTANCE_ID)

gpu:
	@id=$$(aws ssm send-command --instance-ids $(INSTANCE_ID) --document-name AWS-RunShellScript \
	  --parameters 'commands=["nvidia-smi"]' --query Command.CommandId --output text) && \
	aws ssm wait command-executed --command-id $$id --instance-id $(INSTANCE_ID) ; \
	aws ssm get-command-invocation --command-id $$id --instance-id $(INSTANCE_ID) \
	  --query StandardOutputContent --output text

bootstrap:
	scripts/remote.sh -f bootstrap/node.sh

# make deploy [OVERLAY=scenarios/s3-gpu-pressure.yaml]
deploy:
	scripts/remote.sh -d 'deploy dashboards' 'deploy/deploy.sh $(OVERLAY)'

# make scenario S=s3 [RUNS=3]: deploy scenario s3's config, then benchmark it
scenario: check-bucket
	@test -n "$(S)" || { echo "usage: make scenario S=s1..s5 [RUNS=3]"; exit 1; }
	scripts/remote.sh -d 'deploy bench dashboards' 'RUNS=$(or $(RUNS),3) TARGET=$(or $(TARGET),pod-a) RESULTS_URI=$(RESULTS_URI) bench/scenario.sh $(S)'

# make bench SCENARIO=s2 [RUNS=3] [TARGET=pod-a] [ARGS="--docs 4"]
bench: check-bucket
	@test -n "$(SCENARIO)" || { echo "usage: make bench SCENARIO=name [RUNS=3] [TARGET=pod-a] [ARGS=...]"; exit 1; }
	scripts/remote.sh -d 'deploy bench' 'RUNS=$(or $(RUNS),3) TARGET=$(or $(TARGET),pod-a) RESULTS_URI=$(RESULTS_URI) bench/bench.sh $(SCENARIO) $(ARGS)'

# Save dashboards, run annotations and Prometheus series before stop/down (Prometheus data is not persistent).
snapshot: check-bucket
	scripts/remote.sh -d 'bench dashboards' 'RESULTS_URI=$(RESULTS_URI) bench/snapshot.sh'

results: check-bucket
	aws s3 sync $(RESULTS_URI) results/ --only-show-errors
	@find results -name '*.csv' | sort

# Summary table and chart from results/ (runs locally; needs uv)
report:
	python3 bench/report.py > /dev/null && echo "wrote results/summary.md"
	uv run -q --no-project --with 'matplotlib==3.10.*' python bench/chart.py
	uv run -q --no-project --with 'matplotlib==3.10.*' python bench/figures.py

# Forward Grafana to localhost:3000 through SSM (needs session-manager-plugin).
grafana:
	@scripts/remote.sh 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; \
	  echo "user admin, password $$(kubectl -n monitoring get secret monitoring-grafana -o jsonpath={.data.admin-password} | base64 -d)"' | head -1
	aws ssm start-session --target $(INSTANCE_ID) --document-name AWS-StartPortForwardingSessionToRemoteHost \
	  --parameters "host=$$(scripts/remote.sh 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n monitoring get svc monitoring-grafana -o jsonpath={.spec.clusterIP}' | head -1),portNumber=80,localPortNumber=3000"

status:
	aws ec2 describe-instances --instance-ids $(INSTANCE_ID) \
	  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Placement.AvailabilityZone]' --output table

stop:
	aws ec2 stop-instances --instance-ids $(INSTANCE_ID) --output table

start:
	aws ec2 start-instances --instance-ids $(INSTANCE_ID) --output table

# Anything of this project that still exists after a destroy is a leak. Asks EC2 and IAM
# directly: the tagging API lags and keeps listing deleted resources for up to an hour.
leftovers:
	@echo "Still existing (Project=kv-cache-demo):"
	@aws ec2 describe-instances --filters Name=tag:Project,Values=kv-cache-demo \
	  Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
	  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text | sed 's/^/  instance /'
	@aws ec2 describe-volumes --filters Name=tag:Project,Values=kv-cache-demo \
	  --query 'Volumes[].[VolumeId,State]' --output text | sed 's/^/  volume /'
	@aws ec2 describe-vpcs --filters Name=tag:Project,Values=kv-cache-demo \
	  --query 'Vpcs[].VpcId' --output text | tr '\t' '\n' | sed '/^$$/d; s/^/  vpc /'
	@aws iam get-role --role-name kv-cache-demo-node --query Role.RoleName --output text 2>/dev/null | sed 's/^/  iam role /' || true
	@echo "(nothing listed = clean)"
