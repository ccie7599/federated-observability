.PHONY: help init cluster deploy-hub deploy-edge test port-forward destroy clean

help:
	@echo "Federated Observability on LKE"
	@echo ""
	@echo "Infrastructure:"
	@echo "  make init          - Initialize Terraform"
	@echo "  make cluster       - Create LKE clusters"
	@echo "  make destroy       - Destroy clusters"
	@echo ""
	@echo "Hub Cluster:"
	@echo "  make deploy-hub    - Deploy hub components (monitoring + observability + gateway)"
	@echo ""
	@echo "Edge Cluster:"
	@echo "  make deploy-edge   - Deploy edge OTel agents"
	@echo ""
	@echo "Operations:"
	@echo "  make test          - Run smoke tests"
	@echo "  make port-forward  - Start port-forwards to Grafana, Prometheus, Tempo"
	@echo "  make clean         - Clean up local Terraform files"
	@echo ""

init:
	cd terraform && terraform init

cluster:
	cd terraform && terraform apply -auto-approve

deploy-hub:
	kubectl apply -k hub/monitoring/
	kubectl apply -k hub/observability/
	kubectl apply -k hub/gateway/

deploy-edge:
	@echo "Apply edge agent and scraper configs to the edge cluster context:"
	@echo "  kubectl --context <edge-ctx> apply -f edge/agent-config.yaml"
	@echo "  kubectl --context <edge-ctx> apply -f edge/scraper-config.yaml"

test:
	./tests/smoke_test.sh

port-forward:
	@echo "Starting port-forwards..."
	@echo "Grafana:    http://localhost:3000 (admin/admin)"
	@echo "Prometheus: http://localhost:9090"
	@echo "Tempo:      http://localhost:3200"
	@echo ""
	@echo "Press Ctrl+C to stop all port-forwards"
	@kubectl port-forward svc/grafana 3000:3000 -n monitoring & \
	kubectl port-forward svc/prometheus 9090:9090 -n monitoring & \
	kubectl port-forward svc/tempo 3200:3200 -n monitoring & \
	wait

destroy:
	cd terraform && terraform destroy -auto-approve

clean:
	rm -rf terraform/.terraform terraform/kubeconfig
