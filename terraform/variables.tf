variable "linode_token" {
  description = "Linode API token"
  type        = string
  sensitive   = true
}

variable "cluster_label" {
  description = "Label for the LKE cluster"
  type        = string
  default     = "fed-observability-test"
}

variable "k8s_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "region" {
  description = "Linode region"
  type        = string
  default     = "us-ord"
}

variable "node_type" {
  description = "Instance type for nodes"
  type        = string
  default     = "g6-standard-4"  # 4 vCPU, 8GB RAM - good for test
}

variable "node_count" {
  description = "Number of nodes"
  type        = number
  default     = 3
}

variable "allowed_ip" {
  description = "IP address allowed through firewall"
  type        = string
  default     = "47.224.104.170"
}

variable "cluster_tags" {
  description = "Tags for the cluster"
  type        = list(string)
  default     = ["observability", "test", "vault"]
}

variable "gpu_node_type" {
  description = "Instance type for GPU nodes"
  type        = string
  default     = "g2-gpu-rtx4000a1-s"  # RTX4000 Ada Small
}

variable "gpu_node_count" {
  description = "Number of GPU nodes"
  type        = number
  default     = 1
}
