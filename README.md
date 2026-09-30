# k8s: cases

Четыре практических кейса по Kubernetes. В каждом кластер уже сломан: сервис
не работает, но ни один под не падает и ни одной красной строки на экране нет.
Задача — найти причину командами и починить.

Кейсы — это лабы, а не лекции: скриптов в них нет, все шаги выполняются руками,
и каждое утверждение проверяется командой и её выводом.

## Кейсы

| # | Тема | Что нужно из обвязки |
|---|---|---|
| [01](cases/01-rolling-update/README.md) | Обновление без даунтайма: RollingUpdate, probes, PodDisruptionBudget | — |
| [02](cases/02-network-security/README.md) | NetworkPolicy, Ingress, TLS через cert-manager | Calico, ingress-nginx, cert-manager |
| [03](cases/03-storage/README.md) | Хранилища: расширение PVC, StatefulSet, снапшоты | csi-driver-host-path + snapshot-controller |
| [04](cases/04-rbac-securitycontext/README.md) | RBAC и SecurityContext: перевод сервиса с root на restricted | — |

Каждый кейс живёт в своём namespace (`case01`…`case04`), сносится
`kubectl delete ns caseNN`. Кейсы независимы, порядок произвольный, но
проходить их надо **по одному**: в кейсе 1 есть `drain` ноды, а он выселяет
поды всех namespace сразу, не только поды кейса. Интернет во время
прохождения не нужен — всё уже в кластере.

---

## 1. Что нужно

- **Linux** (x86_64 или arm64) либо **Windows + WSL2**. На macOS работает, но
  нужен `bash` 4+ (`brew install bash`) — штатный 3.2 не подойдёт.
- **Docker** ≥ 20.10, запущен. Docker Engine или Docker Desktop.
- **kind** ≥ 0.20 — https://kind.sigs.k8s.io/docs/user/quick-start/#installation
- **kubectl** ≥ 1.30 — https://kubernetes.io/docs/tasks/tools/#kubectl
- **helm** 3 или 4.
- **git**, **curl**.
- **Ресурсы:** 4 CPU и 8 ГБ RAM у хоста, ~10 ГБ диска.
- **Порты 80 и 443 на хосте свободны.** kind пробрасывает их внутрь кластера —
  на них садится ingress-nginx, без них кейс 2 не демонстрируется.
- Интернет на время установки: тянутся образы и манифесты с Docker Hub,
  raw.githubusercontent.com и helm-репозиториев. Версии зафиксированы.

Проверка, что всё на месте:

```bash
docker version --format '{{.Server.Version}}'
kind version
kubectl version --client
helm version --short
```

## 2. Установка стенда

```bash
git clone https://github.com/Lanjetto/k8s-workshop.git
cd k8s-workshop
./cluster/install.sh
```

Скрипт идемпотентен: повторный запуск переиспользует существующий кластер и
переприменяет аддоны поверх. Полный проход с нуля — 4–6 минут, основное время
уходит на скачивание образов.

Что разворачивается: kind-кластер `workshop` (1 control-plane + 2 worker),
Calico, ingress-nginx, cert-manager, csi-driver-host-path со
snapshot-controller, metrics-server. Версия Kubernetes — та, что несёт твой
kind (на kind 0.33 это v1.37); версии аддонов зафиксированы в
`cluster/addons/*.sh` и переопределяются переменными окружения, например
`CALICO_VERSION=v3.32.2 ./cluster/install.sh`.

Проверка:

```bash
kubectl get nodes
```
```
NAME                     STATUS   ROLES           AGE   VERSION
workshop-control-plane   Ready    control-plane   3m    v1.37.0
workshop-worker          Ready    <none>          2m    v1.37.0
workshop-worker2         Ready    <none>          2m    v1.37.0
```

```bash
kubectl get storageclass
```
```
NAME                        PROVISIONER             ALLOWVOLUMEEXPANSION
csi-hostpath-sc (default)   hostpath.csi.k8s.io     true
standard                    rancher.io/local-path   false
```

`csi-hostpath-sc` — дефолтный класс с `allowVolumeExpansion: true`. Дефолтный
`standard` расширять тома не умеет, поэтому кейс 3 идёт именно на первом.

Все поды должны быть `Running`:

```bash
kubectl get pods -A | grep -v Running
```

Пустой вывод — стенд готов, переходи к `cases/01-rolling-update/README.md`.

## 3. Снос и пересборка

```bash
./cluster/destroy.sh     # снести кластер вместе со всеми томами
./cluster/install.sh     # поднять заново
```

Пересборка нужна, если кластер сломан сильнее, чем хочется чинить.

---

## Если что-то пошло не так

**`kubectl` отвечает `Forbidden: User "kubernetes-admin" cannot list resource "nodes"`**

Так выглядит мёртвый кластер: часть контейнеров kind не поднялась после
перезагрузки хоста. Лечится подъёмом контейнеров:

```bash
docker start workshop-control-plane workshop-worker workshop-worker2
```

`install.sh` выставляет им `restart=unless-stopped`, так что дальше они
поднимаются сами.

**Ноды в `NotReady`**

Calico ещё стартует — это до 2–3 минут после создания кластера. Если дольше:

```bash
kubectl -n kube-system get pods -l k8s-app=calico-node
kubectl -n kube-system logs -l k8s-app=calico-node --tail=50
```

**ingress-nginx висит без адреса**

Порты 80/443 на хосте заняты (частая причина на Windows — IIS или skype).
Освободи их либо поменяй `extraPortMappings` в `cluster/kind-config.yaml` и
пересобери кластер.

**`kubectl top` отвечает `error: Metrics API not available`**

metrics-server в kind нужен флаг `--kubelet-insecure-tls`: kubelet отдаёт
самоподписанный сертификат, и без флага метрики не собираются. Починка:

```bash
bash cluster/addons/metrics-server.sh fix
```
```bash
bash cluster/addons/metrics-server.sh status
```

**Прочие причины посмотреть состояние аддона**

```bash
kubectl -n kube-system get pods
kubectl -n ingress-nginx get pods
kubectl -n cert-manager get pods
```
