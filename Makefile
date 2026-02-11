.PHONY: help init cluster deploy destroy test port-forward clean

KUBECONFIG := $(PWD)/terraform/kubeconfig
export KUBECONFIG

help:
	@echo "Federated Observability Platform"
	@echo ""
	@echo "Usage:"
	@echo "  make init        - Initialize Terraform"
	@echo "  make cluster     - Create LKE cluster"
	@echo "  make deploy      - Deploy all components"
	@echo "  make test        - Run smoke tests"
	@echo "  make port-forward - Start port-forwards to services"
	@echo "  make destroy     - Destroy cluster"
	@echo "  make clean       - Clean up local files"
	@echo ""

init:
	cd terraform && terraform init

cluster:
	cd terraform && terraform apply -auto-approve

deploy:
	./scripts/deploy-all.sh

test:
	./tests/smoke_test.sh

port-forward:
	@echo "Starting port-forwards..."
	@echo "Grafana: http://localhost:3000 (admin/admin)"
	@echo "Prometheus: http://localhost:9090"
	@echo "Test App: http://localhost:8080"
	@echo ""
	@echo "Press Ctrl+C to stop all port-forwards"
	@kubectl port-forward svc/grafana 3000:3000 -n monitoring & \
	kubectl port-forward svc/prometheus 9090:9090 -n monitoring & \
	kubectl port-forward svc/test-app 8080:80 -n test-app & \
	kubectl port-forward svc/tempo 3200:3200 -n monitoring & \
	wait

destroy:
	cd terraform && terraform destroy -auto-approve

clean:
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl terraform/kubeconfig
