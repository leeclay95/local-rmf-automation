###############################################################################
# STIG Manager + MySQL — stigman-eks cluster.
###############################################################################
resource "kubernetes_namespace" "stigman" {
  provider = kubernetes.stigman

  metadata {
    name = "stigman"
  }
}

resource "kubernetes_persistent_volume_claim" "mysql" {
  provider = kubernetes.stigman

  metadata {
    name      = "mysql-pvc"
    namespace = kubernetes_namespace.stigman.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class

    resources {
      requests = {
        storage = var.mysql_storage
      }
    }
  }

  # local-path binds WaitForFirstConsumer, so the claim stays Pending until the
  # MySQL pod is scheduled. Without this Terraform blocks here forever.
  wait_until_bound = false
}

resource "kubernetes_deployment" "mysql" {
  provider = kubernetes.stigman

  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace.stigman.metadata[0].name
    labels    = { app = "mysql" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "mysql" }
    }

    # One RWO volume: never run two MySQL pods against it at once.
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = { app = "mysql" }
      }

      spec {
        container {
          name  = "mysql"
          image = var.mysql_image

          args = [
            "--innodb-buffer-pool-size=1024M",
            "--sort_buffer_size=16M",
          ]

          port {
            container_port = 3306
          }

          env {
            name  = "MYSQL_ROOT_PASSWORD"
            value = var.mysql_root_password
          }

          env {
            name  = "MYSQL_DATABASE"
            value = "stigman"
          }

          env {
            name  = "MYSQL_USER"
            value = "stigman"
          }

          env {
            name  = "MYSQL_PASSWORD"
            value = var.mysql_password
          }

          volume_mount {
            name       = "mysql-storage"
            mount_path = "/var/lib/mysql"
          }

          resources {
            requests = {
              memory = "1Gi"
              cpu    = "500m"
            }
            limits = {
              memory = "2Gi"
              cpu    = "1000m"
            }
          }

          readiness_probe {
            exec {
              command = ["mysqladmin", "ping", "-h", "127.0.0.1"]
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            failure_threshold     = 30
          }
        }

        volume {
          name = "mysql-storage"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.mysql.metadata[0].name
          }
        }
      }
    }
  }

  timeouts {
    create = "10m"
    update = "10m"
  }
}

resource "kubernetes_service" "mysql" {
  provider = kubernetes.stigman

  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace.stigman.metadata[0].name
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "mysql" }

    port {
      port        = 3306
      target_port = 3306
    }
  }
}

resource "kubernetes_deployment" "stigman_api" {
  provider = kubernetes.stigman

  metadata {
    name      = "stigman-api"
    namespace = kubernetes_namespace.stigman.metadata[0].name
    labels    = { app = "stigman-api" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "stigman-api" }
    }

    template {
      metadata {
        labels = { app = "stigman-api" }
      }

      spec {
        container {
          name  = "stigman-api"
          image = var.stigman_image

          port {
            container_port = 54000
          }

          env {
            name  = "STIGMAN_DB_HOST"
            value = "mysql.stigman.svc.cluster.local"
          }

          env {
            name  = "STIGMAN_DB_PORT"
            value = "3306"
          }

          env {
            name  = "STIGMAN_DB_USER"
            value = "stigman"
          }

          env {
            name  = "STIGMAN_DB_PASSWORD"
            value = var.mysql_password
          }

          env {
            name  = "STIGMAN_DB_SCHEMA"
            value = "stigman"
          }

          env {
            name  = "STIGMAN_API_PORT"
            value = "54000"
          }

          # Server-side authority: the API fetches this issuer's OIDC discovery
          # document and JWKS to validate bearer tokens. It resolves because
          # stage 1's Route53 private zone answers keycloak.mil for pods, and
          # the ALB listener picks the keycloak load balancer by SNI.
          env {
            name  = "STIGMAN_OIDC_PROVIDER"
            value = local.infra.oidc_issuer
          }

          # Browser-side authority, baked into the client config the API serves.
          # Same URL here because the host and the pods reach Keycloak by the
          # same name — which is the whole reason for keycloak.mil.
          env {
            name  = "STIGMAN_CLIENT_OIDC_PROVIDER"
            value = local.infra.oidc_issuer
          }

          env {
            name  = "STIGMAN_CLASSIFICATION"
            value = var.classification
          }

          # The lab CA is not in the image's trust store, so the API's
          # server-to-server call to keycloak.mil would fail certificate
          # verification. Acceptable for a lab; do not carry this to a real
          # deployment — mount the CA instead.
          env {
            name  = "NODE_TLS_REJECT_UNAUTHORIZED"
            value = "0"
          }

          resources {
            requests = {
              memory = "512Mi"
              cpu    = "250m"
            }
            limits = {
              memory = "1Gi"
              cpu    = "500m"
            }
          }

          readiness_probe {
            http_get {
              path = "/api/op/configuration"
              port = "54000"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 60
          }
        }
      }
    }
  }

  depends_on = [kubernetes_deployment.mysql]

  timeouts {
    create = "15m"
    update = "15m"
  }
}

resource "kubernetes_service" "stigman" {
  provider = kubernetes.stigman

  metadata {
    name      = "stigman-svc"
    namespace = kubernetes_namespace.stigman.metadata[0].name
  }

  spec {
    type     = "NodePort"
    selector = { app = "stigman-api" }

    port {
      name        = "http"
      port        = 54000
      target_port = 54000
      node_port   = local.infra.stigman_node_port
    }
  }
}
