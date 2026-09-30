#!/usr/bin/env bash
# ingress-nginx — точка входа для кейса 2 (Ingress-роутинг + TLS).
#
# Берём именно kind-вариант манифеста: он раскатывается DaemonSet'ом на ноду
# с лейблом ingress-ready=true (он проставлен в kind-config.yaml) и цепляется
# к hostPort 80/443, которые проброшены на хост. Обычный манифест
# (provider/cloud) создаст LoadBalancer-сервис в Pending — в kind он никуда
# не зарезолвится, и Ingress будет висеть без адреса.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NGINX_VERSION="${NGINX_VERSION:-controller-v1.15.1}"
MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

log "ingress-nginx ${NGINX_VERSION}"
kubectl apply -f "$MANIFEST" >/dev/null

log "ждём готовности контроллера"
kubectl -n ingress-nginx wait --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=300s

ok "ingress-nginx готов"
kubectl -n ingress-nginx get pods
