###############################################################################
# Keycloak — keycloak-eks cluster.
#
# Same workload as the original lab's keycloak.yaml. The one structural change
# is the Service: NodePort instead of ClusterIP + an alb Ingress, because the
# ALB is created by Terraform in stage 1 rather than by the Load Balancer
# Controller watching Ingress objects. The NodePort is what stage 1's target
# group forwards to, so the two stages agree on it through stage 1's outputs.
###############################################################################
resource "kubernetes_namespace" "keycloak" {
  provider = kubernetes.keycloak

  metadata {
    name = "keycloak"
  }
}

resource "kubernetes_deployment" "keycloak" {
  provider = kubernetes.keycloak

  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
    labels    = { app = "keycloak" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "keycloak" }
    }

    template {
      metadata {
        labels = { app = "keycloak" }
      }

      spec {
        container {
          name  = "keycloak"
          image = var.keycloak_image

          port {
            container_port = 8080
            name           = "http"
          }

          # TLS is terminated at the ALB, so Keycloak itself speaks plain HTTP.
          env {
            name  = "KC_HTTP_ENABLED"
            value = "true"
          }

          # edge = "I sit behind a TLS-terminating proxy"; combined with
          # xforwarded it makes Keycloak build https:// URLs from the
          # X-Forwarded-Proto the ALB sets.
          env {
            name  = "KC_PROXY"
            value = "edge"
          }

          env {
            name  = "KC_PROXY_HEADERS"
            value = "xforwarded"
          }

          env {
            name  = "KC_HOSTNAME_STRICT"
            value = "false"
          }

          # Pinned rather than inferred. Every token Keycloak issues carries this
          # as its `iss` claim, and the STIG Manager API rejects a token whose
          # issuer is not exactly its configured authority. Leaving Keycloak to
          # guess from headers is how you get an issuer mismatch that only shows
          # up after a successful login.
          env {
            name  = "KC_HOSTNAME"
            value = "https://${local.infra.keycloak_host}"
          }

          env {
            name  = "KC_HOSTNAME_ADMIN"
            value = "https://${local.infra.keycloak_host}"
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
              path = "/realms/stigman"
              port = "8080"
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            failure_threshold     = 30
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

resource "kubernetes_service" "keycloak" {
  provider = kubernetes.keycloak

  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }

  spec {
    type     = "NodePort"
    selector = { app = "keycloak" }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      node_port   = local.infra.keycloak_node_port
    }
  }
}
