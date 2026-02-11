output "cluster_id" {
  description = "LKE cluster ID"
  value       = linode_lke_cluster.observability.id
}

output "cluster_api_endpoints" {
  description = "Kubernetes API endpoints"
  value       = linode_lke_cluster.observability.api_endpoints
}

output "cluster_status" {
  description = "Cluster status"
  value       = linode_lke_cluster.observability.status
}

output "kubeconfig_path" {
  description = "Path to kubeconfig file"
  value       = local_file.kubeconfig.filename
}

output "firewall_id" {
  description = "Firewall ID"
  value       = linode_firewall.cluster_fw.id
}

output "node_ids" {
  description = "Node instance IDs"
  value       = [for node in linode_lke_cluster.observability.pool[0].nodes : node.instance_id]
}
