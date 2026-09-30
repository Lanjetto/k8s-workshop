#!/usr/bin/env bash
# metrics-server — источник данных для `kubectl top` и для HPA.
#
# Запуск из корня репозитория:
#   bash cluster/addons/metrics-server.sh           поставить/починить
#   bash cluster/addons/metrics-server.sh fix       то же самое, явно
#   bash cluster/addons/metrics-server.sh break     СЛОМАТЬ (см. ниже)
#   bash cluster/addons/metrics-server.sh status    что сейчас
#
# ── Про обязательный костыль ────────────────────────────────────────────────
#
# kubelet в kind отдаёт САМОПОДПИСАННЫЙ сертификат, и metrics-server без
# --kubelet-insecure-tls просто не соберёт метрики: `kubectl top pods` вернёт
# "error: Metrics API not available". Это самая частая причина «метрик нет».
#
# Именно поэтому у скрипта есть режим break: он ставит metrics-server РОВНО
# ТАК, КАК ЭТО ДЕЛАЕТ ЧЕЛОВЕК, ВПЕРВЫЕ ЕГО СТАВЯЩИЙ — без флага. Ничего не
# «портится»: это обычная установка, просто с одной неверной опцией. Так
# объяснять со сцены честнее, чем «мы сейчас специально сломаем».
#
# ── Почему break делается через uninstall+install, а не через upgrade ───────
#
# Поймано 25.09.2026 на прогоне. `helm upgrade` без флага НЕ ломает `kubectl
# top`. Новый под не проходит собственную пробу `metric-storage-ready`
# («no metrics to serve»), выкат встаёт, и Deployment держит живой СТАРЫЙ под
# — по-другому RollingUpdate не умеет: он обязан сохранять доступность.
# Метрики продолжают собираться, и на экране ничего не меняется.
#
# Проверено вручную: после `helm upgrade` без флага в namespace висели ДВА
# пода metrics-server — старый 1/1 и новый 0/1, и `kubectl top` работал.
#
# Поэтому break = снести релиз и поставить заново. Свежая установка не имеет
# старого ReplicaSet, прикрывать новый под некому, и поломка видна сразу.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MODE="${1:-fix}"
NS_KUBE="kube-system"
RELEASE="metrics-server"
CHART="metrics-server/metrics-server"

# Аргумент, которого не хватает в сломанном состоянии.
# Второй аргумент (--metric-resolution=15s) НЕ передаём: он уже есть в
# defaultArgs чарта. Проверено `helm show values`: каждая передача сверх
# этого дублирует флаг в аргументах пода.
#
# Сломанной установке НЕ передаём ни одного аргумента: чарт подставит свои
# defaultArgs (там --metric-resolution=15s уже есть), и insecure-флага среди
# них не окажется. Передавать вместо него что-то ещё — способ получить флаг
# дважды: проверено, `--set args[0]=--metric-resolution=15s` даёт в поде
# ДВЕ копии --metric-resolution.
FIX_ARG='args[0]=--kubelet-insecure-tls'

have_repo() {
  helm repo list 2>/dev/null | grep -q '^metrics-server' || {
    log "добавляю helm-репозиторий metrics-server"
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
    helm repo update metrics-server >/dev/null
  }
}

# Ждём, пока API метрик начнёт ОТВЕЧАТЬ, а не пока под станет Running.
# Разница существенная: под может быть Running и даже Ready, а `kubectl top`
# при этом падать. Ждём именно ответа API.
wait_top() {  # wait_top <секунд> <работает|не-работает>
  local secs=$1 want=$2 i
  for i in $(seq 1 "$secs"); do
    if kubectl top nodes >/dev/null 2>&1; then
      [ "$want" = "работает" ] && return 0
    else
      [ "$want" = "не-работает" ] && return 0
    fi
    sleep 2
  done
  return 1
}

cmd_status() {
  log "релиз"
  helm -n "$NS_KUBE" status "$RELEASE" 2>/dev/null | sed -n '1,6p' || warn "релиза нет"

  printf '\n'
  log "аргументы пода — здесь и живёт разница между рабочим и сломанным"
  kubectl -n "$NS_KUBE" get deploy "$RELEASE" \
    -o jsonpath='{range .spec.template.spec.containers[0].args[*]}  {@}{"\n"}{end}' 2>/dev/null || true

  printf '\n'
  log "поды и их проба (metric-storage-ready — это ОНА решает, готов ли под)"
  kubectl -n "$NS_KUBE" get pods -l app.kubernetes.io/name=metrics-server 2>/dev/null || true

  printf '\n'
  log "отвечает ли API метрик"
  if kubectl top nodes 2>/dev/null; then
    ok "метрики есть"
  else
    warn "метрики НЕ отдаются — вот причина, и она только в логе:"
    # Печатаем НЕ хвост лога, а строки с причиной. Хвост забит служебным
    # «Caches are synced», и настоящая ошибка в нём тонет.
    kubectl -n "$NS_KUBE" logs -l app.kubernetes.io/name=metrics-server --tail=200 2>/dev/null \
      | grep -E 'x509|Failed to scrape|no metrics to serve' | tail -3 | sed 's/^/    /' || true
  fi
}

cmd_fix() {
  have_repo
  log "ставлю metrics-server с --kubelet-insecure-tls"
  # --wait здесь НЕ ставим: ждать готовности пода бессмысленно, потому что под
  # может быть готов, а API метрик — нет. Ждём по существу, в wait_top ниже.
  # (И отдельно: в helm 4 `--wait=false` уже не булево значение, а строка —
  # предупреждение о deprecation.)
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NS_KUBE" \
    --set "$FIX_ARG" >/dev/null

  printf '\n'
  log "жду, пока API метрик начнёт отвечать (это дольше, чем Ready пода)"
  if wait_top 40 "работает"; then
    ok "metrics API живой"
    kubectl top nodes
  else
    kubectl -n "$NS_KUBE" get pods -l app.kubernetes.io/name=metrics-server
    kubectl -n "$NS_KUBE" logs -l app.kubernetes.io/name=metrics-server --tail=8 2>/dev/null | sed 's/^/    /' || true
    die "Metrics API не поднялся за 80с"
  fi
}

# Сломать = поставить так, как ставит человек, который про флаг не знает.
cmd_break() {
  have_repo

  log "снимаю релиз metrics-server (со старым ReplicaSet — иначе он прикроет новый под)"
  helm uninstall "$RELEASE" -n "$NS_KUBE" >/dev/null 2>&1 || true
  # Ждём именно исчезновения Deployment: helm uninstall возвращает управление
  # раньше, чем объекты реально удалены, а следующий install с тем же именем
  # в этом окне конфликтует.
  local i
  for i in $(seq 1 30); do
    kubectl -n "$NS_KUBE" get deploy "$RELEASE" >/dev/null 2>&1 || break
    sleep 2
  done

  log "ставлю заново — БЕЗ --kubelet-insecure-tls (ни одного args не передаём)"
  helm install "$RELEASE" "$CHART" \
    --namespace "$NS_KUBE" >/dev/null

  printf '\n'
  log "жду, что метрики пропадут"
  if wait_top 40 "не-работает"; then
    ok "установено. Метрики не отдаются — ровно то, что заложено"
  else
    warn "метрики всё ещё отдаются — кейс невалиден"
    return 1
  fi

  # Ждём, пока под дойдёт до состояния «Running, но не готов»: именно так это
  # и выглядит в проде, и именно поэтому никто не бьёт тревогу.
  for i in $(seq 1 30); do
    kubectl -n "$NS_KUBE" get pods -l app.kubernetes.io/name=metrics-server \
      | grep -q '^metrics-server.*0/1.*Running' && break
    sleep 2
  done
  kubectl -n "$NS_KUBE" get pods -l app.kubernetes.io/name=metrics-server
  warn "и это НЕ видно ни в статусе пода, ни в событиях: причина только в логе"
}

case "$MODE" in
  fix|install) cmd_fix ;;
  break)       cmd_break ;;
  status)      cmd_status ;;
  *)
    cat <<'EOF'
metrics-server — источник данных для `kubectl top` (кейс 6).

  bash cluster/addons/metrics-server.sh          поставить/починить
  bash cluster/addons/metrics-server.sh fix      то же самое, явно
  bash cluster/addons/metrics-server.sh break    поставить без --kubelet-insecure-tls
  bash cluster/addons/metrics-server.sh status   что сейчас

Починка идемпотентна — ею же снимается поломка после кейса.
EOF
    ;;
esac
