# Кейс 3. Хранилища: расширение PVC, StatefulSet, снапшоты

**Namespace:** `case03`
**Что нужно из обвязки:** драйвер `csi-hostpath` (StatefulSet `csi-hostpathplugin`), StorageClass `csi-hostpath-sc` с `allowVolumeExpansion: true`, VolumeSnapshotClass `csi-hostpath-snapclass` и `snapshot-controller` в `kube-system`. Ставится одним `bash cluster/addons/csi-hostpath.sh`.

| Файл | Роль |
|---|---|
| `cases/03-storage/broken/statefulset.yaml` | база: StatefulSet + Service. `replicas: 0` — не опечатка |
| `cases/03-storage/broken/backup.yaml` | VolumeSnapshot базы |
| `cases/03-storage/broken/restore.yaml` | **сломанное** восстановление: том 1Gi при снапшоте 2Gi |
| `cases/03-storage/fixed/restore.yaml` | фикс: том 2Gi. Отличие от сломанного — одна строка |

Все команды — из корня репозитория, выводы — с реального прогона.

**Проблема.** Ночью у базы кончилось место. Дежурный сделал две разумные вещи: расширил том патчем PVC и снял снапшот перед работами. Утром выяснилось, что **не сработало ни то, ни другое**.

**Почему это не выглядит как поломка.** У висящего PVC условие `Bound` бодрое, без предупреждений. Расхождение видно, только если сравнить `spec.resources.requests.storage` с колонкой `CAPACITY`. Снапшот показывает `READYTOUSE true`. Команды «здесь проблема» нет — сравнивать надо самому.

**Суть кейса.** У хранилища в Kubernetes нет одной кнопки. «Расширить том» — две операции и два исполнителя. «Снять снапшот» — заказ, который исполняет драйвер, а отслеживает отдельный контроллер. «Восстановить» ограничено **размером**, а не данными.

## 1. Поднять сломанное состояние

```bash
# 0. Чистый лист: снести остатки прошлого прогона — в том же порядке, что и
#    в уборке (раздел 5): под → PVC → снапшот → namespace.
#    pvc/data-db-0 здесь НЕ трогаем: пока StatefulSet держит реплику, её под
#    смонтирован, и `kubectl delete pvc` на нём просто повиснет на
#    pvc-protection. Namespace снесёт том сам, вместе с подом.
kubectl -n case03 delete pod db-restore-check --ignore-not-found --wait=false
kubectl -n case03 delete pvc db-restore --ignore-not-found --wait=false
kubectl -n case03 delete volumesnapshot db-backup --ignore-not-found --wait=false
kubectl delete ns case03 --ignore-not-found
kubectl wait --for=delete ns/case03 --timeout=120s

kubectl create ns case03
kubectl apply -n case03 -f cases/03-storage/broken/statefulset.yaml

# 1. Поднимаем базу: без живого пода том не выдастся и не наполнится
kubectl -n case03 scale statefulset db --replicas=1
kubectl -n case03 rollout status statefulset/db --timeout=180s

# 2. Ждём, пока база запишет данные — они докажут, что снапшот не пустой.
#    Файл растёт на строку раз в 5 секунд, поэтому число зависит от того,
#    как быстро вы дошли до этой команды (в проверочном прогоне — 4).
#    Запомните его: пока под жив, снапшот захватит ровно столько же.
kubectl -n case03 exec db-0 -- sh -c 'wc -l < /data/records.txt'
# → 4

# 3. СНАПШОТ — ПОКА ПОД ЖИВОЙ. Порядок с шагом 4 не менять
kubectl apply -n case03 -f cases/03-storage/broken/backup.yaml
kubectl -n case03 wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/db-backup --timeout=120s

# 4. ТЕПЕРЬ останавливаем базу — ночные работы
kubectl -n case03 scale statefulset db --replicas=0
kubectl -n case03 wait --for=delete pod/db-0 --timeout=120s

# 5. Расширяем том, как это делают в жизни — патчем PVC, не правкой манифеста
kubectl -n case03 patch pvc data-db-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}'

# 6. Восстановление из снапшота — в том МЕНЬШЕГО размера
kubectl apply -n case03 -f cases/03-storage/broken/restore.yaml
```

> **Шаги 3 и 4 нельзя менять местами — но не потому, что снапшот остановленного тома не снимется.** Снимется: проверено, `readyToUse` наступает так же быстро. Расходятся **числа**. `scale --replicas=0` не убивает под мгновенно: контейнер получает SIGTERM и живёт ещё `terminationGracePeriodSeconds` (по умолчанию 30 секунд), всё это время дописывая строки. В проверочном прогоне счётчик на шаге 2 показывал 2, а в снапшоте, снятом после остановки, оказалось 8 записей — и в восстановленном томе вы увидите 8, а не 2. Снимайте снапшот, пока под жив: тогда число из шага 2 и число в восстановленном томе совпадут.

**Ожидаемый результат — 7 проверок:** namespace создан; под `db-0` поднялся; в базе есть записи (сколько именно — смотрите шаг 2); снапшот `readyToUse`; PV расширен до 3Gi; у `data-db-0` запрошено 3Gi при выданных 2Gi и `FileSystemResizePending`; у `db-restore` событие `ProvisioningFailed`.

```bash
kubectl -n case03 get pvc
```
```
NAME         STATUS    VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS      VOLUMEATTRIBUTESCLASS   AGE
data-db-0    Bound     pvc-...                                    2Gi        RWO            csi-hostpath-sc   <unset>                 63s
db-restore   Pending                                                                        csi-hostpath-sc   <unset>                 5s
```

## 2. Диагностика

### 2.1 Расширение тома идёт в два шага: контроллер растит PV, нода растягивает ФС при монтировании

Первая строка выглядит здоровой. Дефект лежит в условиях PVC — `get pvc` их не показывает вообще:

```bash
kubectl -n case03 get pvc data-db-0 \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```
```
Unused=True NoPodsUsingPVC
Resizing=True
FileSystemResizePending=True
```

| Условие | Что означает |
|---|---|
| `Resizing=True` | контроллер **уже расширил том** — его половина работы сделана |
| `FileSystemResizePending=True` | и **ждёт**, пока растянут файловую систему на ноде |
| `Unused=True NoPodsUsingPVC` | **на томе никто не смонтирован** — вот почему ждёт |

Человеческим языком — вытащить из условия его `message`:

```bash
kubectl -n case03 get pvc data-db-0 \
  -o jsonpath='{.status.conditions[?(@.type=="FileSystemResizePending")].message}{"\n"}'
# → Waiting for user to (re-)start a pod to finish file system resize of volume on node.

kubectl get pv "$(kubectl -n case03 get pvc data-db-0 -o jsonpath='{.spec.volumeName}')" \
  -o custom-columns='NAME:.metadata.name,SIZE:.spec.capacity.storage,CLAIM:.spec.claimRef.name'
# → pvc-...   3Gi   data-db-0
```

Кластер **прямым текстом** говорит, что ему нужно, — он не сломался, он ждёт под. А том при этом **уже расширен**: `3Gi`. Расходится только то, что об этом знает PVC. Отсюда правило: **расширение тома — две операции**, и вторая делается нодой при монтировании.

### 2.2 Восстановление меньше снапшота: провизионер отказывает

```bash
kubectl -n case03 get volumesnapshot
# → db-backup   true   data-db-0   2Gi   csi-hostpath-snapclass

kubectl -n case03 describe pvc db-restore | sed -n '/^Events:/,$p'
```
```
Warning  ProvisioningFailed  error getting handle for DataSource Type
VolumeSnapshot by Name db-backup: requested volume size 1073741824 is less
than the size 2147483648 for the source snapshot db-backup
```

Буквально: `1073741824` = 1Gi (просят), `2147483648` = 2Gi (в снапшоте). Данные не уложить в том меньшего размера, и провизионер отказывает — **правильно отказывает**, иначе данные обрезались бы молча.

**Отдельный урок кейса: у висящего PVC причина только в событиях.** В самом объекте её нет:

```bash
kubectl -n case03 get pvc db-restore -o jsonpath='условия=[{.status.conditions}] фаза={.status.phase}{"\n"}'
# → условия=[] фаза=Pending
```

Сравните с `data-db-0` из 2.1, где причина лежала именно в условиях, — здесь так не получится: `get pvc` не показывает причину ни в каком виде — `Pending` и всё. Причина живёт **только в событиях**, а событие — не свойство объекта, а отдельная запись с ограниченным временем жизни: её надо успеть прочитать (`kubectl describe pvc` или `kubectl get events`). В проверочных прогонах `ProvisioningFailed` появлялось через ~1–3 секунды после создания PVC; сколько именно — зависит от того, прогрет ли контроллер, поэтому первую секунду-две в событиях может быть только `Normal` («Provisioning», «ждём том») — бодрая картина «работаем, ждите». **Не делай вывод по первому взгляду: смотри не на статус, а на события.**

## 3. Тупики: четыре шага «почти починил»

**Тупик 1 — правим StatefulSet.** «В шаблоне записан старый размер, поправим его».

```bash
kubectl -n case03 patch statefulset db --type=json \
  -p '[{"op":"replace","path":"/spec/volumeClaimTemplates/0/spec/resources/requests/storage","value":"3Gi"}]'
# → The StatefulSet "db" is invalid: spec.volumeClaimTemplates:
#   Invalid value: [{"name":"data","Spec":{...},"Status":{...}}]: field is immutable
```

`volumeClaimTemplates` неизменяем. И это не главное: даже если бы прошло, **существующие PVC не изменились бы** — шаблон описывает тома **новых** реплик, а `data-db-0` уже создан. Том остался прежним: `запрошено 3Gi, выдано 2Gi`. **Том в StatefulSet меняют руками. Всегда.**

**Тупик 2 — повторяем запрос на расширение.** «Значит, запрос не дошёл».

```bash
kubectl -n case03 patch pvc data-db-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}'
# → persistentvolumeclaim/data-db-0 patched (no change)
sleep 10
kubectl -n case03 get pvc data-db-0 \
  -o jsonpath='запрошено {.spec.resources.requests.storage}, выдано {.status.capacity.storage}{"\n"}'
# → запрошено 3Gi, выдано 2Gi
```

Ничего не изменилось — и не могло: запрос **уже принят** (см. `Resizing=True` в 2.1). Ждут не запроса, а монтирования. Повторный запрос ноду не приближает ни на секунду.

**Тупик 3 — дописать размер в висящий PVC.**

```bash
kubectl -n case03 patch pvc db-restore \
  -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
# → The PersistentVolumeClaim "db-restore" is invalid: spec: Forbidden:
#   spec is immutable after creation except resources.requests and
#   volumeAttributesClassName for bound claims
```

Исключение для `resources.requests` действует **только на привязанных** томах, а этот PVC не привязан (потому и висит) — править его нечем. **Ровно наоборот от интуиции:** у живого тома размер менять можно и нужно (шаг 1, пункт 5), у несостоявшегося — нельзя.

**Тупик 4 — пересоздать PVC.**

```bash
kubectl -n case03 delete pod db-restore-check --ignore-not-found
kubectl -n case03 delete pvc db-restore
kubectl -n case03 apply -f cases/03-storage/broken/restore.yaml
sleep 10
kubectl -n case03 get pvc db-restore
# → db-restore   Pending
```

Пересоздание объекта **не лечит ошибку в манифесте**. Пока в файле `1Gi`, PVC будет висеть сколько угодно раз. Порядок тоже важен: сначала под, потом PVC — пока под ссылается на PVC, срабатывает `kubernetes.io/pvc-protection` и PVC залипает в `Terminating`.

## 4. Решение

### 4.1 Расширение PVC: вернуть под на место

Фикс — ровно одно действие. Всё нужное уже сделано, не хватало ноды:

```bash
kubectl -n case03 scale statefulset db --replicas=1
kubectl -n case03 rollout status statefulset/db --timeout=180s
kubectl -n case03 wait --for=jsonpath='{.status.capacity.storage}'=3Gi pvc/data-db-0 --timeout=120s

# Проверка 1: PVC догнал том, а условия исчезли — не сменились на False, а пропали.
# jsonpath печатает только type и status, причину (`PodUsingPVC`) он не выводит —
# в этом и смысл: в списке осталось ОДНО условие вместо трёх.
kubectl -n case03 get pvc data-db-0 \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
# → Unused=False

# Проверка 2: данные на месте. Записей больше, чем было на шаге 2, и это
# нормально: база писала всё время, пока вы разбирались с томом
kubectl -n case03 exec db-0 -- sh -c 'wc -l < /data/records.txt; tail -2 /data/records.txt'
# → 14, order-0013, order-0014
```

`Resizing` и `FileSystemResizePending` пропали из списка целиком — признак завершённой операции. Расширение завершилось **только когда под снова запущен**: пока база стояла, том был расширен, а PVC — нет.

### 4.2 Восстановление из снапшота с размером >= снапшота

Разница между сломанным и починенным манифестом — одна строка:

```bash
diff <(grep -vE '^\s*#|^\s*$' cases/03-storage/broken/restore.yaml) \
     <(grep -vE '^\s*#|^\s*$' cases/03-storage/fixed/restore.yaml)
# → 10c10
#   <       storage: 1Gi
#   ---
#   >       storage: 2Gi
```

**Почему удаление PVC здесь безопасно.** В проде эта команда обычно означает потерю данных. Здесь том **так и не был создан**: провизионер отказал, PV не появился. Доказательство — у висящей заявки нет `volumeName`, и смотреть это надо **до** удаления, пока заявка ещё та самая, сломанная:

```bash
kubectl -n case03 get pvc db-restore -o jsonpath='{.spec.volumeName}{"\n"}'
# → пусто: тома за заявкой нет
kubectl -n case03 get pvc data-db-0 -o jsonpath='{.spec.volumeName}{"\n"}'
# → pvc-...   ← а вот это живой том
```

Применяем. Сначала под, потом PVC:

```bash
kubectl -n case03 delete pod db-restore-check --ignore-not-found
kubectl -n case03 delete pvc db-restore
kubectl -n case03 apply -f cases/03-storage/fixed/restore.yaml
kubectl -n case03 wait --for=jsonpath='{.status.phase}'=Bound pvc/db-restore --timeout=120s
kubectl -n case03 get pvc db-restore
# → db-restore   Bound   pvc-...   2Gi   RWO   csi-hostpath-sc
```

**Проверка 3 — что восстановилось:**

```bash
kubectl -n case03 wait --for=condition=Ready pod/db-restore-check --timeout=120s
kubectl -n case03 logs db-restore-check
```
```
восстановленный том, записей: 4
последние записи:
order-0002
order-0003
order-0004
проверка живости тома:
  запись в том прошла
```

**Проверка 4 — сравнение с живой базой** (и заодно размер тома глазами приложения):

```bash
kubectl -n case03 exec db-0 -- sh -c 'wc -l < /data/records.txt; df -h /data'
# → 20
#   Filesystem                Size      Used Available Use% Mounted on
#   /dev/sdd                250.9G     43.3G    194.8G  18% /data
```

В снапшоте 4 записи, в живой базе 20 — **восстановленная база отстаёт, и это не поломка**: снапшот фиксирует момент съёмки, а база писала дальше. Разница в 16 записей — точка восстановления. (Оба числа зависят от того, сколько база писала до и после съёмки; важно здесь не «сколько именно», а что восстановленное **меньше** живого.) А `df` показывает 250 гигабайт при запрошенных 3Gi, потому что `csi-hostpath` отдаёт поду **директорию на хосте**, а не блочное устройство: жёсткого лимита нет, `df` видит всю хостовую ФС. Кластер при этом честно расширяет том — колонка `CAPACITY` у PVC. **В прод это не переносится.**

## 5. Уборка

**Порядок обязателен: снапшот держит namespace.** Что будет, если цепочку не разобрать, — замерено на живом стенде:

| Что сделали | Что вышло |
|---|---|
| `delete ns`, бросив кейс невылеченным (`db-restore` так и остался `Pending`) | провисел в `Terminating` **~4 минуты**, потом всё-таки ушёл |
| снесли сам снапшот, пока `db-restore` ещё `Pending` | контроллер отложил удаление **навсегда**: `kubectl delete volumesnapshot` висит, снапшот на месте и через 6 минут |
| `delete ns` после уборки по порядку ниже | **~50 секунд**, без остатков |
| `delete ns` после раздела 4.2 (`db-restore` в `Bound`), без всякого порядка | те же **~50 секунд** |

Последняя строка объясняет, почему до читателя, который дошёл до конца, эта грабля не добирается: защита `volumesnapshot-as-source-protection` держится, только пока PVC, восстанавливающийся из снапшота, **не привязан**. Вылеченный `db-restore` её отпускает. А брошенный невылеченным (`Pending` навсегда) — держит снапшот, снапшот держит namespace.

Порядок, который снимает занятость по цепочке:

```bash
kubectl -n case03 delete pod db-restore-check --ignore-not-found   # под держит PVC
kubectl -n case03 delete pvc db-restore --ignore-not-found         # невылеченный PVC держит снапшот
kubectl -n case03 delete volumesnapshot db-backup --ignore-not-found
kubectl -n case03 get volumesnapshot                               # → No resources found in case03 namespace.
kubectl delete ns case03                                           # и только теперь
```

**Почему порядок именно такой.** `snapshot-controller` отказывается удалять снапшот, пока из него восстанавливают PVC, и вешает финализатор. Вот что он пишет в лог и в события (цитата из прогона):

```
checkandRemoveSnapshotFinalizersAndCheckandDeleteContent[case03/db-backup]:
  snapshot is being used to restore a PVC
Warning  SnapshotDeletePending  Snapshot is being used to restore a PVC
```

Дальше — просто цепочка зависимостей, и идти по ней надо с конца: под (`kubernetes.io/pvc-protection` не отдаёт PVC, пока на нём смонтирован под) → PVC (не отдаёт снапшот, пока из него восстанавливают) → снапшот (не отдаёт namespace, пока на нём финализатор) → namespace.

**Если namespace всё-таки завис** — вытащить его можно только снятием финализаторов руками. Проверено: после этого namespace уходит за ~15 секунд.

```bash
kubectl -n case03 patch volumesnapshot db-backup --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl patch volumesnapshotcontent "$(kubectl get volumesnapshotcontent -o name)" \
  --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl delete ns case03
```

Это тот же урок, что и весь кейс, только про удаление: **«удалить» — не одно действие, а цепочка зависимостей**. `StorageClass` и `VolumeSnapshotClass` при этом остаются намеренно — это инфраструктура стенда, а не реквизит кейса. Полный снос — `cluster/destroy.sh`.

## Словарь

| Термин | Что это на самом деле |
|---|---|
| **PVC** | Заявка приложения: «дайте том на 2Gi, ReadWriteOnce» |
| **PV** | Сам том, который реально существует. Отдельный объект; его создаёт кто-то в ответ на заявку |
| **StorageClass** | Кто и как выдаёт тома: драйвер и умеет ли он расширяться (`allowVolumeExpansion`) |
| **Provisioner** (`csi-provisioner`) | Компонент, который создаёт том по заявке. Это он отвечает «не могу» в событиях PVC |
| **CSI** | Плагин к хранилищу: EBS, Ceph, диск на хосте. У нас — `csi-hostpath` |
| **`volumeClaimTemplates`** | Шаблон заявки внутри StatefulSet. Kubernetes сам создаёт PVC на каждую реплику: `data-db-0`, … |
| **kubelet** | Агент на ноде. Именно он **растягивает файловую систему** при монтировании тома |
| **snapshot-controller** | Кластерный компонент, который отслеживает VolumeSnapshot и просит драйвер его исполнить |
| **`restoreSize`** | Размер тома **на момент съёмки**. Нижняя граница для восстановления |
| **RPO** | Точка восстановления: сколько данных вы потеряете при откате на снапшот |

## Почему именно так

**Почему восстановленная база отстаёт — это не поломка, а RPO.** `VolumeSnapshot` — это заказ, копию делает драйвер, а следит за исполнением `snapshot-controller`. Снимок фиксирует том в момент съёмки, а база пишет дальше: в снапшоте 4 записи, в живой базе — 20. Разница в 16 записей и есть точка восстановления. Ответ на вопрос «что поменять, чтобы разница была ноль»: в Kubernetes — ничего, это вопрос регламента: снапшоты снимают перед изменениями и знают, на какой момент откатываются. И то же самое про весь кейс: ни одна операция с хранилищем не жалуется громко — `get pvc` показывает бодрое `Bound`, снапшот — `READYTOUSE true`, а работа при этом не сделана. **Проверять надо не статус объекта, а то, ради чего он создан.**
