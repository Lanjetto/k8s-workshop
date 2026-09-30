#!/usr/bin/env bash
# Полный снос стенда. Кластер kind — это docker-контейнеры,
# удаление кластера удаляет и все тома этого драйвера.
#
# Нужен на воркшопе ровно в одном сценарии: слушатель(или ты) так сломал
# кластер, что чинить дольше, чем пересоздать. Полный цикл install.sh
# с нуля — примерно 4-6 минут, из них бОльшая часть — скачивание образов,
# которое при повторном запуске идёт из локального кэша docker.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "кластера '$CLUSTER_NAME' и так нет"
  exit 0
fi

warn "удаляю кластер '$CLUSTER_NAME' вместе со всем содержимым"
kind delete cluster --name "$CLUSTER_NAME"
ok "снесено. Поднять заново: ./cluster/install.sh"
