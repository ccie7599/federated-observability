# LKE Cluster for Federated Observability Platform
resource "linode_lke_cluster" "observability" {
  label       = var.cluster_label
  k8s_version = var.k8s_version
  region      = var.region
  tags        = var.cluster_tags

  # CPU node pool for system workloads
  pool {
    type  = var.node_type
    count = var.node_count

    autoscaler {
      min = var.node_count
      max = var.node_count + 2
    }
  }

  # GPU node pool for inference workloads
  pool {
    type  = var.gpu_node_type
    count = var.gpu_node_count

    autoscaler {
      min = var.gpu_node_count
      max = var.gpu_node_count + 1
    }
  }
}

# Firewall to restrict access to allowed IP only
resource "linode_firewall" "cluster_fw" {
  label = "${var.cluster_label}-fw"

  # Allow SSH from allowed IP
  inbound {
    label    = "allow-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = ["${var.allowed_ip}/32"]
  }

  # Allow HTTPS from allowed IP
  inbound {
    label    = "allow-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv4     = ["${var.allowed_ip}/32"]
  }

  # Allow HTTP from allowed IP
  inbound {
    label    = "allow-http"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = ["${var.allowed_ip}/32"]
  }

  # Allow Kubernetes API from allowed IP
  inbound {
    label    = "allow-k8s-api"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6443"
    ipv4     = ["${var.allowed_ip}/32"]
  }

  # Allow NodePort range from allowed IP
  inbound {
    label    = "allow-nodeports"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "30000-32767"
    ipv4     = ["${var.allowed_ip}/32"]
  }

  # Allow all internal cluster communication
  inbound {
    label    = "allow-internal"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "1-65535"
    ipv4     = ["10.0.0.0/8", "192.168.0.0/16"]
  }

  inbound {
    label    = "allow-internal-udp"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "1-65535"
    ipv4     = ["10.0.0.0/8", "192.168.0.0/16"]
  }

  # Default deny inbound
  inbound_policy = "DROP"

  # Allow all outbound
  outbound_policy = "ACCEPT"

  # Attach to all cluster nodes (both CPU and GPU pools)
  linodes = concat(
    [for node in linode_lke_cluster.observability.pool[0].nodes : node.instance_id],
    [for node in linode_lke_cluster.observability.pool[1].nodes : node.instance_id]
  )
}

# Save kubeconfig to local file
resource "local_file" "kubeconfig" {
  content         = base64decode(linode_lke_cluster.observability.kubeconfig)
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"
}
