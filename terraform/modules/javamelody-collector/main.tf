# JavaMelody collector server.
#
# JavaMelody's counters live inside each JVM, so four `orders` replicas expose
# four unrelated /monitoring UIs. The collector polls every registered node and
# presents one aggregated view of the application.
#
# It is platform tooling, not application workload, so Terraform owns it and it
# runs on the tainted platform nodes alongside Prometheus, Alloy and Argo CD.
# Argo CD's remit is the microservices chart.

resource "kubernetes_service" "collector" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = { "app.kubernetes.io/name" = var.name }
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
    }
  }

  spec {
    type     = "LoadBalancer"
    selector = { "app.kubernetes.io/name" = var.name }

    port {
      name        = "http"
      port        = 8080
      target_port = "http"
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_deployment" "collector" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = { "app.kubernetes.io/name" = var.name }
  }

  spec {
    # Must stay at 1. The collector aggregates into local RRD files; a second
    # replica would hold a different, equally partial picture — the exact
    # problem it exists to solve.
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { "app.kubernetes.io/name" = var.name }
    }

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = var.name }
      }

      spec {
        node_selector = var.node_selector

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key      = toleration.value.key
            operator = toleration.value.operator
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 2000
          fs_group        = 2000
          seccomp_profile { type = "RuntimeDefault" }
        }

        container {
          name              = "collector"
          image             = var.image
          image_pull_policy = "IfNotPresent"

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          # The collector WAR only reads javamelody.* system properties. The
          # ESO-synced secret is mounted as a JVM @argfile so the credential
          # never reaches the process cmdline (a -D flag would) nor the logs
          # (JAVA_TOOL_OPTIONS is echoed to stderr, and stderr goes to Loki).
          command = [
            "java",
            "-XX:MaxRAMPercentage=70.0",
            "-Djavamelody.storage-directory=/tmp/javamelody-collector",
            "-Djava.security.egd=file:/dev/./urandom",
            "@/auth/auth.args",
            "-jar",
            "/app/collector-server.war",
          ]

          # TCP, not HTTP: with javamelody.authorized-users set, an HTTP probe
          # gets 401 and kills the pod.
          startup_probe {
            tcp_socket { port = "http" }
            failure_threshold = 30
            period_seconds    = 5
          }

          liveness_probe {
            tcp_socket { port = "http" }
            period_seconds    = 20
            timeout_seconds   = 3
            failure_threshold = 3
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          volume_mount {
            name       = "auth"
            mount_path = "/auth"
            read_only  = true
          }
        }

        volume {
          name = "auth"
          secret { secret_name = var.auth_secret_name }
        }

        # Aggregated history is disposable here. The consequence is that
        # restarting this pod clears its registered-node list — which is why the
        # application pods re-register on a timer rather than only at startup.
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
}
