#!/usr/bin/env bash
# Полная установка стенда воркшопа: кластер + обвязка.
#
# Запуск из корня репозитория:
#   ./cluster/install.sh
#
# Требуется bash 4+ (используется mapfile). На macOS штатный bash 3.2 не
# подойдёт — нужен `brew install bash` и запуск через него.
#
# Скрипт идемпотентен: если кластер уже есть — переиспользует его,
# аддоны переприменяются поверх (kubectl apply / helm upgrade --install).
# Полный снос — ./cluster/destroy.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. Кластер -------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "кластер '$CLUSTER_NAME' уже существует — переиспользуем"
else
  log "создаём кластер '$CLUSTER_NAME' (1 control-plane + 2 worker)"
  kind create cluster --config "$HERE/kind-config.yaml" --wait 180s
fi

# kind не выставляет restart policy на свои контейнеры. Последствие тяжёлое:
# после перезагрузки хоста (или выгрузки WSL-виртуалки, если ты на Windows)
# docker поднимает не все контейнеры, control-plane остаётся в Exited (128) —
# и кластер мёртв, причём kubectl при этом отдаёт не «connection refused», а
# загадочное «Forbidden: User "kubernetes-admin" cannot list resource "nodes"».
# unless-stopped заставляет docker поднимать все три контейнера самому.
log "выставляю restart policy на контейнеры кластера"
mapfile -t KIND_CONTAINERS < <(docker ps -aq --filter "name=^${CLUSTER_NAME}-")
if [ "${#KIND_CONTAINERS[@]}" -gt 0 ]; then
  docker update --restart=unless-stopped "${KIND_CONTAINERS[@]}" >/dev/null
  ok "restart policy: unless-stopped (${#KIND_CONTAINERS[@]} шт.)"
else
  warn "контейнеры кластера не найдены — restart policy не выставлена"
fi

# --- 2. Аддоны --------------------------------------------------------------
# Порядок НЕ произвольный: без Calico ноды остаются NotReady, и всё
# остальное просто некуда раскатывать.
ADDONS=(calico ingress-nginx cert-manager csi-hostpath metrics-server)

for addon in "${ADDONS[@]}"; do
  printf '\n'
  log "── $addon ──"
  "$HERE/addons/${addon}.sh"
done

# --- 3. Итог ----------------------------------------------------------------
printf '\n'
log "── стенд готов ──"
kubectl get nodes
printf '\n'
kubectl get storageclass
printf '\n'
kubectl get clusterissuer 2>/dev/null || warn "ClusterIssuer пока нет — создаётся в кейсе 2"

cat <<'EOF'

Дальше:
  kubectl get pods -A                    — убедиться, что всё зелёное
  cases/01-rolling-update/README.md      — первый кейс

Полный снос стенда: ./cluster/destroy.sh
EOF
