#!/usr/bin/env bash
# CSI hostpath — хранилище для кейса 3 (расширение PVC, StatefulSet, снапшоты).
#
# ПОЧЕМУ НЕ ОБОЙТИСЬ ТЕМ, ЧТО В kind ИЗ КОРОБКИ:
#   local-path-provisioner НЕ поддерживает allowVolumeExpansion и не имеет
#   CSI-снапшоттера вовсе. Кейс 3 на дефолтном kind не демонстрируется:
#   ни расширение, ни снапшоты.
#
# ГРАБЛЯ №1, СТОИВШАЯ ЧАСА ОТЛАДКИ — RBAC САЙДКАРОВ.
#   В репозитории csi-driver-host-path НЕТ ClusterRole для сайдкаров.
#   Файл csi-hostpath-plugin.yaml создаёт ClusterRoleBinding'и, ссылающиеся на
#   external-provisioner-runner, external-resizer-runner, external-snapshotter-runner
#   и т.д. — а самих ClusterRole нет ни в одном манифесте этого репозитория.
#   Они тянутся из ШЕСТИ отдельных репозиториев, версии вычисляются из тегов
#   образов в plugin.yaml. Апстрим делает это скриптом deploy.sh; мы применяем
#   те же RBAC-манифесты напрямую (объявленные версии — ниже, они совпадают
#   с тегами образов в plugin.yaml v1.18.0).
#
#   Симптом, если этот шаг пропустить: поды драйвера выглядят ЗДОРОВЫМИ
#   (8/8 Running), но в логах csi-provisioner сыпется
#     "cannot list resource \"persistentvolumeclaims\" ... clusterrole ... not found"
#   и PVC вечно висит в Pending с событием ExternalProvisioning.
#   Снаружи это выглядит как «провизионер не работает», хотя он работает —
#   ему просто не дали прав.
#
# ГРАБЛЯ №2 — РАСШИРЕНИЕ PVC ТРЕБУЕТ ЗАПУЩЕННОГО ПОДА.
#   После увеличения PVC контроллер расширяет ТОМ (PV становится 2Gi), но PVC
#   остаётся с прежней capacity и уходит в
#     FileSystemResizePending: "Waiting for user to (re-)start a pod to
#     finish file system resize of volume on node"
#   Потому что resize2fs делается на ноде, когда том смонтирован.
#   Это НЕ баг — это штатное поведение, и это отличный учебный момент.
#   Самопроверка ниже поэтому поднимает под, а не просто патчит PVC.
#
# ГРАБЛЯ №3 — CRD СНАПШОТОВ БЕЗ КОНТРОЛЛЕРА (найдено 25.09.2026 при сборке кейса 3).
#   Первая версия этого скрипта ставила ТРИ CRD (VolumeSnapshotClass/Content/Snapshot)
#   плюс VolumeSnapshotClass и сайдкар csi-snapshotter в поде драйвера — и на этом
#   останавливалась. Но csi-snapshotter — это исполнитель: он умеет сходить в драйвер
#   и снять снапшот, когда его об этом попросят. ПРОСИТЬ ЕГО НЕКОМУ.
#
#   За это отвечает отдельный кластерный компонент — snapshot-controller (deployment
#   в kube-system), который и живёт в репозитории external-snapshotter. Без него
#   VolumeSnapshot создаётся и... ничего. Вообще ничего: ни ошибки, ни события,
#   ни VolumeSnapshotContent. `kubectl get volumesnapshot` показывает строку
#   с ПУСТЫМ READYTOUSE и всё. Это ровно тот класс дефекта, что и грабля №1:
#   снаружи «ничего не происходит», а причина — отсутствующий компонент.
#
#   Проверено 25.09.2026: без контроллера снапшот не создавался за 30+ секунд,
#   VolumeSnapshotContent не появлялся, событий не было ни одного. С контроллером
#   снапшот готов за ~3 секунды.
#
#   Общий урок для воркшопа: CRD — это только ОБЪЯВЛЕНИЕ ТИПА объекта. Он делает
#   `kubectl get volumesnapshot` возможным, но не делает снапшоты работающими.
#   Установка «только CRD» — реальная ошибка в проде, и она молчит.
#
# ЧЕГО csi-hostpath НЕ ДЕЛАЕТ: не энфорсит размер.
#   Он отдаёт директорию на хосте, а не loopback-устройство, поэтому `df -h`
#   внутри пода покажет размер всей хостовой ФС, а не запрошенные 2Gi.
#   capacity у PVC меняется корректно, а вот жёсткого лимита нет. В проде так
#   нельзя, и это надо проговорить вслух, иначе слушатель унесёт csi-hostpath
#   в прод.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CSI_VERSION="${CSI_VERSION:-v1.18.0}"
SNAP_VERSION="${SNAP_VERSION:-v8.6.0}"
CSI_DIR="${CSI_DIR:-kubernetes-1.34}"   # 1.35 в апстриме — симлинк на 1.34

# Теги образов сайдкаров из csi-hostpath-plugin.yaml v1.18.0.
# Меняешь CSI_VERSION — пересмотри и это, иначе RBAC разъедется с образами.
PROVISIONER_VERSION="${PROVISIONER_VERSION:-v6.3.0}"
ATTACHER_VERSION="${ATTACHER_VERSION:-v4.12.0}"
RESIZER_VERSION="${RESIZER_VERSION:-v2.2.1}"
HEALTH_MONITOR_VERSION="${HEALTH_MONITOR_VERSION:-v0.18.0}"

CSI_RAW="https://raw.githubusercontent.com/kubernetes-csi/csi-driver-host-path/${CSI_VERSION}/deploy/${CSI_DIR}"
SNAP_RAW="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAP_VERSION}/client/config/crd"
SNAP_CTRL_RAW="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAP_VERSION}/deploy/kubernetes/snapshot-controller"

# --- 1. CRD снапшотов -------------------------------------------------------
log "CRD снапшотов (external-snapshotter ${SNAP_VERSION})"
kubectl apply -f "${SNAP_RAW}/snapshot.storage.k8s.io_volumesnapshotclasses.yaml" >/dev/null
kubectl apply -f "${SNAP_RAW}/snapshot.storage.k8s.io_volumesnapshotcontents.yaml" >/dev/null
kubectl apply -f "${SNAP_RAW}/snapshot.storage.k8s.io_volumesnapshots.yaml" >/dev/null

kubectl wait --for=condition=established --timeout=120s \
  crd/volumesnapshotclasses.snapshot.storage.k8s.io \
  crd/volumesnapshotcontents.snapshot.storage.k8s.io \
  crd/volumesnapshots.snapshot.storage.k8s.io >/dev/null
ok "CRD объявлены"

# --- 2. RBAC сайдкаров (см. ГРАБЛЯ №1 выше) ---------------------------------
log "RBAC сайдкаров — без этого провизионер бесправен"
RBAC_URLS=(
  "https://raw.githubusercontent.com/kubernetes-csi/external-provisioner/${PROVISIONER_VERSION}/deploy/kubernetes/rbac.yaml"
  "https://raw.githubusercontent.com/kubernetes-csi/external-attacher/${ATTACHER_VERSION}/deploy/kubernetes/rbac.yaml"
  # у snapshotter'а путь нестандартный — не deploy/kubernetes/rbac.yaml
  "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAP_VERSION}/deploy/kubernetes/csi-snapshotter/rbac-csi-snapshotter.yaml"
  "https://raw.githubusercontent.com/kubernetes-csi/external-resizer/${RESIZER_VERSION}/deploy/kubernetes/rbac.yaml"
  "https://raw.githubusercontent.com/kubernetes-csi/external-health-monitor/${HEALTH_MONITOR_VERSION}/deploy/kubernetes/external-health-monitor-controller/rbac.yaml"
)
for url in "${RBAC_URLS[@]}"; do
  kubectl apply -f "$url" >/dev/null || die "не применился RBAC: $url"
done
ok "RBAC на месте"

# --- 3. CSIDriver -----------------------------------------------------------
log "CSIDriver"
kubectl apply -f "${CSI_RAW}/hostpath/csi-hostpath-driverinfo.yaml" >/dev/null

# --- 4. Драйвер и сайдкары --------------------------------------------------
log "драйвер и сайдкары"
kubectl apply -f "${CSI_RAW}/hostpath/csi-hostpath-plugin.yaml" >/dev/null

# --- 5. StorageClass (свой, в апстриме его нет) -----------------------------
log "StorageClass с allowVolumeExpansion"
kubectl apply -f "$(dirname "${BASH_SOURCE[0]}")/csi-hostpath-sc.yaml" >/dev/null

# --- 6. VolumeSnapshotClass -------------------------------------------------
log "VolumeSnapshotClass"
kubectl apply -f "${CSI_RAW}/hostpath/csi-hostpath-snapshotclass.yaml" >/dev/null

# --- 7. snapshot-controller (см. ГРАБЛЯ №3) ---------------------------------
# Без этого deployment'а снапшоты не работают ВООБЩЕ, и выясняется это только
# по пустому READYTOUSE у VolumeSnapshot. Живёт в kube-system, потому что он
# кластерный: следит за VolumeSnapshot во всех namespace сразу.
log "snapshot-controller (без него снапшоты молча не создаются)"
kubectl apply -f "${SNAP_CTRL_RAW}/rbac-snapshot-controller.yaml" >/dev/null \
  || die "не применился RBAC snapshot-controller"
kubectl apply -f "${SNAP_CTRL_RAW}/setup-snapshot-controller.yaml" >/dev/null \
  || die "не применился deployment snapshot-controller"
if kubectl -n kube-system rollout status deploy/snapshot-controller --timeout=180s >/dev/null 2>&1; then
  ok "snapshot-controller поднялся"
else
  warn "snapshot-controller НЕ поднялся — снапшоты в кейсе 3 работать не будут"
  warn "смотри: kubectl -n kube-system get pods | grep snapshot-controller"
fi

# --- ждём драйвер -----------------------------------------------------------
log "ждём готовности драйвера"
deadline=$((SECONDS + 300))
while [ $SECONDS -lt $deadline ]; do
  if kubectl get statefulset csi-hostpathplugin -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qx 1; then
    ok "драйвер поднялся"
    break
  fi
  sleep 5
done

kubectl get sc
kubectl get volumesnapshotclass 2>/dev/null || warn "VolumeSnapshotClass не виден"

# --- 8. Самопроверка --------------------------------------------------------
# Проверяем ровно то, ради чего всё затевалось: том выдаётся, расширяется
# И снимается снапшот. Поднимаем под — без него расширение ФС не завершится
# (см. ГРАБЛЯ №2).
log "самопроверка: выдача тома, расширение и снапшот"

kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: csi-selftest
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: csi-selftest-pod
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "sleep 600"]
      volumeMounts:
        - {name: vol, mountPath: /data}
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: csi-selftest
EOF

if kubectl wait --for=condition=Ready pod/csi-selftest-pod --timeout=180s >/dev/null 2>&1; then
  ok "том выдан, под с PVC запустился"

  kubectl patch pvc csi-selftest -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' >/dev/null

  resized=no
  for _ in $(seq 1 30); do
    cap=$(kubectl get pvc csi-selftest -o jsonpath='{.status.capacity.storage}' 2>/dev/null)
    if [ "$cap" = "2Gi" ]; then resized=yes; break; fi
    sleep 3
  done

  if [ "$resized" = yes ]; then
    ok "расширение PVC работает (1Gi -> 2Gi)"
  else
    warn "PVC не расширился — смотри: kubectl describe pvc csi-selftest, логи csi-resizer"
  fi

  # Снапшот проверяем отдельно и обязательно: без snapshot-controller (ГРАБЛЯ №3)
  # VolumeSnapshot создаётся и навсегда остаётся с пустым READYTOUSE — молча.
  # Проверяем именно readyToUse, а не факт создания объекта: «объект есть» здесь
  # не значит ничего.
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: csi-selftest-snap
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass
  source:
    persistentVolumeClaimName: csi-selftest
EOF

  snapped=no
  for _ in $(seq 1 30); do
    if [ "$(kubectl get volumesnapshot csi-selftest-snap -o jsonpath='{.status.readyToUse}' 2>/dev/null)" = "true" ]; then
      snapped=yes; break
    fi
    sleep 2
  done

  if [ "$snapped" = yes ]; then
    ok "снапшот работает (restoreSize $(kubectl get volumesnapshot csi-selftest-snap -o jsonpath='{.status.restoreSize}' 2>/dev/null))"
  else
    warn "VolumeSnapshot НЕ стал readyToUse — снапшоты в кейсе 3 не заработают"
    warn "проверь: kubectl get volumesnapshot csi-selftest-snap -o wide"
    warn "и контроллер: kubectl -n kube-system get pods | grep snapshot-controller"
  fi

  kubectl delete volumesnapshot csi-selftest-snap --ignore-not-found >/dev/null 2>&1 || true
else
  warn "под с PVC не поднялся за 3 мин — кейс 3 не заработает"
  kubectl describe pvc csi-selftest | tail -15
fi

kubectl delete pod csi-selftest-pod --wait=false >/dev/null 2>&1 || true
kubectl delete pvc csi-selftest --wait=false >/dev/null 2>&1 || true

ok "хранилище готово к кейсу 3"
