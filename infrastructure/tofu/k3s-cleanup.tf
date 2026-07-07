# Cleanup K3s-created Hetzner resources on destroy
#
# When K3s with Hetzner CCM/CSI is running, it creates:
# - LoadBalancers for type: LoadBalancer services (labeled with hcloud-ccm/service-uid)
# - Volumes for PersistentVolumeClaims (labeled by CSI driver)
#
# These resources are not managed by Tofu, so we need to clean them up on destroy.

# On destroy, Tofu reverses dependency order: cleanup runs BEFORE servers are deleted.
resource "null_resource" "k3s_resource_cleanup" {
  depends_on = [hcloud_server.k3s_nodes]

  # Store token in triggers so it's available during destroy
  triggers = {
    always       = "k3s-cleanup"
    hcloud_token = var.hcloud_token
  }

  # Cleanup runs on destroy
  provisioner "local-exec" {
    when = destroy
    environment = {
      HCLOUD_TOKEN = self.triggers.hcloud_token
    }
    command = <<-EOT
      echo "==> Cleaning up K3s-created Hetzner resources..."

      # Delete LoadBalancers created by CCM (labeled with hcloud-ccm/service-uid)
      echo "Looking for K3s-managed LoadBalancers..."
      LB_IDS=$(hcloud load-balancer list -o noheader -o columns=id,labels 2>/dev/null | grep 'hcloud-ccm/service-uid' | awk '{print $1}' || true)
      if [ -n "$LB_IDS" ]; then
        for lb_id in $LB_IDS; do
          echo "Deleting LoadBalancer: $lb_id"
          hcloud load-balancer delete "$lb_id" --yes 2>/dev/null || true
        done
      else
        echo "No K3s-managed LoadBalancers found"
      fi

      # Delete Volumes created by CSI (have csi.hetzner.cloud in name or specific labels)
      echo "Looking for K3s CSI-managed Volumes..."
      VOL_IDS=$(hcloud volume list --selector 'provisioner=k3s' -o noheader -o 'columns=id' 2>/dev/null || true)
      if [ -n "$VOL_IDS" ]; then
        for vol_id in $VOL_IDS; do
          echo "Deleting Volume: $vol_id"
          # Detach first if attached
          hcloud volume detach "$vol_id"
          sleep 2
          hcloud volume delete "$vol_id" --yes
        done
      else
        echo "No K3s-managed Volumes found"
      fi

      echo "==> K3s resource cleanup complete"
    EOT
    # HCLOUD_TOKEN is set by `op run` wrapper in mise tasks
  }
}
