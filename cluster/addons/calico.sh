#!/usr/bin/env bash
# Calico — CNI, который УМЕЕТ NetworkPolicy.
#
# Это не «ещё один аддон», а условие существования кейса 2. Дефолтный CNI в kind
# (kindnet) политики не энфорсит: манифест применяется, kubectl его показывает,
# трафик ходит. Ставим Calico ДО всего остального — пока CNI нет, ноды в NotReady.
#
# podSubnet в kind-config.yaml — 192.168.0.0/16, он же дефолтный IPPool Calico.
# Если менять один, менять и второй.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CALICO_VERSION="${CALICO_VERSION:-v3.32.2}"
MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

log "Calico ${CALICO_VERSION}"
kubectl apply -f "$MANIFEST" >/dev/null

log "ждём, пока ноды станут Ready (до 5 мин)"
deadline=$((SECONDS + 300))
while [ $SECONDS -lt $deadline ]; do
  notready=$(kubectl get nodes --no-headers 2>/dev/null | grep -vc ' Ready' || true)
  if [ "${notready:-1}" = "0" ]; then
    ok "все ноды Ready"
    kubectl get nodes
    exit 0
  fi
  sleep 5
done

kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=calico-node
die "ноды не поднялись за 5 мин — смотри вывод calico-node выше"
