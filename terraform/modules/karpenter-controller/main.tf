# Karpenter controller plus the three NodePools.
#
# The NodePools ship as a small local chart rather than as kubernetes_manifest
# resources: that resource fetches the CRD schema during plan, and the Karpenter
# CRDs only exist after the release below. Helm renders without needing the
# schema, so one apply is enough.

resource "helm_release" "controller" {
  name             = "karpenter"
  namespace        = var.namespace
  create_namespace = true

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.chart_version

  values = [yamlencode({
    replicas = 1
    # The controller is infrastructure, so it belongs on the managed node group
    # — and it must not run on a node it might itself decide to consolidate.
    nodeSelector = var.node_selector
    tolerations  = var.tolerations

    controller = {
      resources = {
        requests = { cpu = "200m", memory = "256Mi" }
      }
    }

    settings = {
      clusterName = var.cluster_name
      # Drives graceful drain on Spot reclaim. Without it the first warning a
      # pod gets is the node vanishing.
      interruptionQueue = var.interruption_queue
    }
  })]

  wait    = true
  timeout = 900
}

resource "helm_release" "nodepools" {
  name      = "karpenter-nodepools"
  namespace = var.namespace

  chart = "${path.module}/chart"

  values = [yamlencode({
    clusterName        = var.cluster_name
    nodeRole           = var.node_role_name
    securityGroupId    = var.security_group_id
    discoveryTag       = var.cluster_name
    instanceTypes      = var.instance_types
    graviton           = var.graviton_instance_types
    spotCpuLimit       = var.spot_cpu_limit
    ondemandCpuLimit   = var.ondemand_cpu_limit
    generalCpuLimit    = var.general_cpu_limit
    gravitonCpuLimit   = var.graviton_cpu_limit
    microservicesTaint = var.microservices_taint
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.controller]
}
