resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "ingress-nginx"
  version    = var.ingress_nginx_version

  create_namespace = true

  # Default 300s is too tight: helm_release's wait blocks on both the
  # controller pod AND the internal NLB getting an address, and on a cold
  # cluster (Karpenter node cold-start + first-time NLB provisioning) that
  # combination can genuinely take longer than 5 minutes even with nothing
  # wrong — confirmed 2026-07-03: pod Ready and NLB EnsuredLoadBalancer both
  # completed, just a few minutes after Terraform's client-side timeout had
  # already given up and errored with "context deadline exceeded".
  timeout = 900

  set = [
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
      value = "nlb"
    },
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-internal"
      value = "true"
    }
  ]
}

data "kubernetes_service" "ingress_nginx_controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [helm_release.ingress_nginx]
}
