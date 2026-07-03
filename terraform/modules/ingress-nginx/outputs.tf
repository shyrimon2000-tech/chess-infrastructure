output "load_balancer_hostname" {
  description = "DNS hostname of the internal NLB provisioned for the ingress-nginx controller"
  value       = data.kubernetes_service.ingress_nginx_controller.status[0].load_balancer[0].ingress[0].hostname
}
