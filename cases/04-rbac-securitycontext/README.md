# Кейс 4. RBAC и SecurityContext: перевод сервиса с root на restricted

**Namespace:** `case04`
**Что нужно из обвязки:** ничего сверх стенда — кластерных объектов кейс не создаёт.

**Файлы кейса:**

| Файл | Роль |
|---|---|
| `broken/app.yaml` | всё приложение: ConfigMap с конфигом, ConfigMap со скриптом, PVC, Deployment, Service. «Сломанного» нет — есть «как написали по умолчанию» |
| `steps/1-declared.yaml`, `2-nonroot.yaml`, `3-fsgroup.yaml` | три тупика «почти починил»: четыре поля из отказа → плюс uid → плюс `fsGroup` (он же финальный профиль) |
| `fixed/app.yaml`, `fixed/rbac.yaml` | эталон: починенный Deployment целиком, плюс ServiceAccount `api` и `Role` под один ConfigMap |
| `badfix/default-view.yaml` | соблазн: выдать права учётке `default` |

Логика приложения лежит в ConfigMap `app-script`, поэтому `broken/`, `steps/` и `fixed/` отличаются только блоком `securityContext`.

**Проблема.** Сервис `api` отвечает по HTTP, пишет в свой том, читает фича-флаг из ConfigMap **через API кластера**. Работает он от `root` и ходит в API под учёткой `default`, у которой нет ни одного права. Потом namespace ужесточают до `restricted` — и обычная выкатка встаёт: новые поды отбивает политика, старые работают.

**Почему это не выглядит как поломка.** Под `Running`, сервис отвечает, ошибок никто не пишет. Единственный след второй половины — `CONFIG FAIL: HTTP 403` в логе приложения, и он там с самого начала; первая половина не проявляется вообще, пока namespace не ужесточат.

**Суть кейса.** Четыре дефекта, четыре слоя, у каждого свой проверяющий, и ни один не выглядит как «упало»: шаблон не нарушает политику — а под не стартует; права выданы — а не работают; сервис отвечает — а данных нет; выкат прошёл — а сняли защиту.

---

## 1. Поднять сломанное состояние

Начинаем не с поломки, а **с работающего сервиса**: под `restricted` сломанный шаблон не создал бы ни одного пода, и вместо «сервис работает, а выкат стоит» на экране была бы пустота.

```bash
# Сценарий идемпотентен: начинаем со сноса прошлого прогона — целиком, вместе с томом.
# Том пересобираем начисто намеренно: fsGroup меняет владельца каталога НА ХОСТЕ,
# и это переживает правки шаблона — на старом томе шаг 2.3 не воспроизвёлся бы.
kubectl delete ns case04 --ignore-not-found
kubectl wait --for=delete ns/case04 --timeout=120s

kubectl create ns case04
kubectl apply -n case04 -f cases/04-rbac-securitycontext/broken/app.yaml
kubectl -n case04 rollout status deploy/api --timeout=180s
```

Проверяем, что сервис работает: **`Running` — не доказательство ничего**, поэтому доказательств три.

```bash
kubectl -n case04 get pods -o wide
# → api-644c5b4b8c-... 1/1 Running (192.168.55.155, workshop-worker2)
#   api-644c5b4b8c-... 1/1 Running (192.168.55.167, workshop-worker2)
#   хвост имени и IP случайны, ноды выбирает планировщик — обе могут лечь на одну;
#   про хеш в середине имени — абзац про ReplicaSet ниже

# отвечает ли сервис: запрос по имени сервиса, а не по IP пода, и в ответе сразу uid и конфиг
kubectl -n case04 exec deploy/api -- wget -q -O - http://api.case04.svc.cluster.local/
# → api uid=0 — CONFIG FAIL: HTTP 403

# жив ли он, а не «висит»: счётчик записей в томе обязан вырасти
kubectl -n case04 exec deploy/api -- wc -l /data/events.log
# → 2 /data/events.log
sleep 7
kubectl -n case04 exec deploy/api -- wc -l /data/events.log
# → 8 /data/events.log      ← выросло. Точное число и шаг зависят от того, сколько
#                             под уже поработал и в какую фазу трёхсекундного цикла
#                             попал замер; доказательство — сам рост, а не величина
```

Ужесточаем namespace и катим обычную выкатку — ровно это делает любая правка шаблона:

```bash
kubectl label ns case04 pod-security.kubernetes.io/enforce=restricted
# → Warning: existing pods in namespace "case04" violate the new PodSecurity enforce level "restricted:latest"
# → Warning: api-644c5b4b8c-... (and 1 other pod): allowPrivilegeEscalation != false,
#     unrestricted capabilities, runAsNonRoot != true, seccompProfile
# → namespace/case04 labeled

kubectl -n case04 rollout restart deploy/api
# → Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false ...
# → deployment.apps/api restarted

kubectl -n case04 get deploy api
# → api    2/2     0            2           66s
kubectl -n case04 get rs
# → api-644c5b4b8c   2   2   2   67s     ← старый, живой
#   api-...          1   0   0   12s     ← новый ReplicaSet, подов ноль
```

Имя нового ReplicaSet каждый раз своё: `rollout restart` дописывает в шаблон пода аннотацию `kubectl.kubernetes.io/restartedAt` со временем, а имя RS — это хеш шаблона. Аннотация при этом **липкая**: `kubectl apply` её не снимает — её нет ни в файле, ни в прошлом applied-конфиге, а слияние убирает только то, что оно же и добавляло. Поэтому и RS из шагов 2.2, 2.3, 3.х каждый прогон получают новое имя. Устойчив ровно один хеш — `api-644c5b4b8c`: этот RS создан до первого `rollout restart`, от чистого шаблона. Дальше поды поэтому выбираются по состоянию, а не по имени.

Кластер сам перечислил, чем недоволен, — это и есть список задач. А ответ `restarted` — **успех**: Deployment изменился, а поды по нему создать нельзя. Ожидаемый результат — `deploy 2/2`, `UP-TO-DATE 0`, подов новой версии нет.

## 2. Диагностика

### 2.1. PSA: шаблон пода не соответствует профилю

Пода не существует, поэтому смотреть надо не на его статус, а на условия Deployment:

```bash
kubectl -n case04 get deploy api \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
# → Available=True MinimumReplicasAvailable
#   Progressing=True NewReplicaSetCreated
#   ReplicaFailure=True FailedCreate

kubectl -n case04 get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail -1
```
```
Error creating: pods "api-...-..." is forbidden: violates PodSecurity
"restricted:latest": allowPrivilegeEscalation != false (container "api" must set
securityContext.allowPrivilegeEscalation=false), unrestricted capabilities
(container "api" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "api" must set
securityContext.runAsNonRoot=true), seccompProfile (pod or container "api" must
set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Выше — столбец `MESSAGE` этой строки события (перед ним в выводе ещё время, тип, причина и объект); в тексте имя пода сокращено до `api-...-...`.

`Progressing=True` — не «всё хорошо», а «выкат идёт»; беда в `ReplicaFailure`. Под не «не запустился» — он **не создан**: у незапустившегося есть статус, события и логи, у несозданного нет ничего, и отказал не kubelet, а API-сервер. Deployment же создался потому, что у PSA две проверки: для контроллеров шаблон проверяется **предупреждением**, а отказ приходит при создании **пода**.

### 2.2. `runAsNonRoot` без `runAsUser`: admission проверил заявление, kubelet — образ

```bash
kubectl apply -n case04 -f cases/04-rbac-securitycontext/steps/1-declared.yaml
sleep 12
kubectl -n case04 get pods
# → api-...-...  0/1 CreateContainerConfigError   ← новый
#   api-644c5b4b8c-...  1/1 Running               (старые, их два)

# хвост имени пода случаен, поэтому берём под из состояния, а не набираем руками
POD=$(kubectl -n case04 get pods -l app=api \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' \
  | awk '$2=="CreateContainerConfigError"{print $1}')
kubectl -n case04 describe pod $POD | sed -n '/Events:/,$p'
# → Normal   Scheduled ... Successfully assigned case04/api-...-... to workshop-worker2
#   Normal   Pulled    ... Container image "busybox:1.37" already present on machine and can be accessed by the pod
#   Warning  Failed    ... spec.containers{api}: Error: container has runAsNonRoot and image will run as root
```

**Под появился** — политика пропустила, нарушений `restricted` больше нет, и он всё равно не работает. `Scheduled` и `Pulled` тут не для красоты: под **дошёл до ноды и образ был взят**, то есть отказал не вход в кластер, а запуск контейнера.

**Разошлись два проверяющих.** admission проверил **манифест**: «написано `runAsNonRoot: true` — проходи». kubelet проверил **образ**: «`busybox` не объявляет `USER`, значит стартует от root; а в манифесте написано, что от root нельзя. Отказываю». `runAsNonRoot` — заявление, `runAsUser` — факт.

Вернуть сломанное состояние — обычный `kubectl apply -n case04 -f cases/04-rbac-securitycontext/broken/app.yaml`: он **снимает** добавленные поля, три пути слияния знают, что было в прошлый раз.

### 2.3. Том принадлежит root: следствие перехода на uid 1001

```bash
kubectl apply -n case04 -f cases/04-rbac-securitycontext/steps/2-nonroot.yaml
sleep 15
kubectl -n case04 get pods
# → api-644c5b4b8c-...  1/1 Running           (старые, живы)
#   api-...-...         0/1 CrashLoopBackOff   ← новый: стартовал и падает

POD=$(kubectl -n case04 get pods -l app=api \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' \
  | awk '$2=="CrashLoopBackOff"{print $1}')
kubectl -n case04 logs $POD --tail=5
# → старт: uid=1001 gid=1001 groups=1001
#   /etc/app/run.sh: line 14: can't create /data/events.log: Permission denied
#   ПАДЕНИЕ: том /data недоступен на запись — uid=1001 gid=1001 groups=1001

kubectl -n case04 exec deploy/api -- ls -ld /data
# → drwxr-xr-x 2 root root 4096 ... /data

kubectl apply -n case04 -f cases/04-rbac-securitycontext/broken/app.yaml   # вернуть
```

Профиль в порядке, под стартовал, процесс идёт от `uid=1001` — и не может писать в свой же том. Причина не в политике и не в образе, а во **владельце файлов**: `runAsUser` и права на файлы не связаны никак, Kubernetes не «передаёт» процессу права владельца. Связывает их другое поле — `fsGroup`: при монтировании тома kubelet меняет группу-владельца тома на указанную. Ловится дефект **только в логе приложения** — ни в манифесте (там всё верно), ни в статусе пода его не видно.

### 2.4. Права выданы не тому

`403` — это ответ кластера, и кластер называет в нём, кому отказал. Спросим то же сами, от имени учётки пода:

```bash
kubectl -n case04 get configmap app-config --as=system:serviceaccount:case04:default
# → Error from server (Forbidden): configmaps "app-config" is forbidden:
#   User "system:serviceaccount:case04:default" cannot get resource "configmaps"
#   in API group "" in the namespace "case04"
```

Это **настоящий запрос**: отвечает тот же движок авторизации, что решает судьбу запроса приложения, и в ответе есть имя того, кем кластер нас увидел.

```bash
kubectl -n case04 get pod -l app=api -o jsonpath='{.items[*].spec.serviceAccountName}{"\n"}'
# → default default      ← в манифесте поля нет, его подставил кластер: по строке на под
kubectl -n case04 auth can-i --list -n case04 --as=system:serviceaccount:case04:default \
  | awk '$1 ~ /^[a-z]/ && $1 !~ /^(selfsubject|clustertrustbundles)/ {n++} END{print n+0}'
# → 0
```

Список при этом непустой: у любой учётки есть хвост системных разрешений (`selfsubjectaccessreviews`, `/healthz`, `/api/*`) — смотреть надо на строки с именами ресурсов.

**Идентичность и права — разные объекты.** Права выдаются субъекту (`RoleBinding` → `ServiceAccount`), а предъявляет их под, указанный в `serviceAccountName` его манифеста. Здесь эти двое разошлись.

## 3. Тупики: три шага «почти починил» плюс badfix

### 3.1. Шаг `sc`: политика довольна, под не запустился

`kubectl apply -n case04 -f cases/04-rbac-securitycontext/steps/1-declared.yaml` — четыре поля по букве отказа. Кластер пропускает под, kubelet отказывает: `CreateContainerConfigError`, событие `container has runAsNonRoot and image will run as root` (разбор в 2.2).

**Тупик** потому, что нарушений `restricted` в поде не осталось ни одного: отказать может не только admission, а проверяющих двое и смотрят они на разное.

### 3.2. Шаг `write`: под запустился, приложение упало

`kubectl apply -n case04 -f cases/04-rbac-securitycontext/steps/2-nonroot.yaml` — плюс конкретный uid. Процесс идёт от `uid=1001` и падает на своём же томе: `Permission denied` на `/data/events.log`, потому что каталог принадлежит `root` (разбор в 2.3).

**Тупик** потому, что профиль соблюдён, политика довольна, никто ничего не нарушает — и всё равно не работает. Причина уже третья и она ниже уровнем.

### 3.3. Шаг `rights`: права есть, прибор подтверждает, приложение всё ещё 403

```bash
kubectl apply -n case04 -f cases/04-rbac-securitycontext/fixed/rbac.yaml

kubectl -n case04 get configmap app-config --as=system:serviceaccount:case04:api
# → NAME         DATA   AGE
#   app-config   2      10m        ← запрос прошёл: право выдано

kubectl -n case04 logs deploy/api | grep CONFIG | tail -1
# → CONFIG FAIL: HTTP 403
#   (grep по CONFIG отсекает heartbeat, который раз в 10 записей сообщает то же
#    самое про канал конфига — «последняя строка про CONFIG» и есть состояние)

kubectl delete -n case04 -f cases/04-rbac-securitycontext/fixed/rbac.yaml   # вернуть
```

**Права выданы, прибор это подтверждает, и они не работают:** под ходит под учёткой `default`, а выданы права `api`. Проверять права надо **тем же запросом, который делает приложение**: правило ограничено `resourceNames`, поэтому `auth can-i` без имени объекта отвечает `no` там, где право есть. **Тупик** потому, что дефект не выдаёт себя ничем: правило в кластере есть, `get rolebinding` его показывает, `describe` молчит, ошибок нет — есть только трафик, который не идёт.

### 3.4. `badfix`: права тому, кто уже просит

```bash
kubectl apply -n case04 -f cases/04-rbac-securitycontext/badfix/default-view.yaml
sleep 4   # приложение спрашивает конфиг раз в 3 секунды — ждём его следующего запроса
kubectl -n case04 logs deploy/api | grep CONFIG | tail -1
# → CONFIG ok: конфиг прочитан из API
#   перезапуска не было: строка появилась в логе уже работающего пода, на его
#   следующем запросе — но именно запроса и надо подождать, мгновенно ничего не меняется

kubectl -n case04 auth can-i --list -n case04 --as=system:serviceaccount:case04:default \
  | awk '$1 ~ /^[a-z]/ && $1 !~ /^(selfsubject|clustertrustbundles)/ {n++} END{print n+0}'
# → 67            ← было 0
kubectl -n case04 auth can-i --list -n case04 --as=system:serviceaccount:case04:default | grep "pods/log"
# → pods/log   []   []   [get list watch]     ← логи ЛЮБОГО пода namespace-а

kubectl delete -n case04 -f cases/04-rbac-securitycontext/badfix/default-view.yaml   # вернуть: CONFIG снова FAIL
```

**Заработало, и перезапускать ничего не пришлось** — RBAC проверяется на каждом запросе, а не «при выдаче»: поэтому путь и выбирают, он быстрее правильного на один выкат и снаружи **неотличим от починки**. Нужное право было **ровно одно** — один ConfigMap по имени; стало 67, то есть весь обзор namespace-а. И это права не «сервиса», а `default` — любого пода namespace-а. Честности ради: секретов `view` не даёт (`auth can-i get secrets … --as=…:default` → `no`).

**Урок.** «Стало работать» — не критерий. Критерий — «работает то, что должно, и НЕ работает то, что не должно».

## 4. Решение

### 4.1. SecurityContext: профиль целиком

```bash
kubectl apply -n case04 -f cases/04-rbac-securitycontext/steps/3-fsgroup.yaml
kubectl -n case04 rollout status deploy/api --timeout=180s
```

Отличие от шага `write` — **одно поле**, `fsGroup`. Четыре поля из текста отказа закрывают требования политики; `fsGroup` там не упомянут, но без него не работает: именно он отдаёт процессу его том.

Видно прямо по каталогу: до фикса `ls -ld /data` отвечает `drwxr-xr-x 2 root root`, после — `drwxrwsr-x 2 root 1001` (группа-владелец сменилась на 1001, появился setgid). И это изменение остаётся **на хосте**: если потом применить шаблон без `fsGroup` на том же томе, приложение больше не упадёт — шаг 2.3 на старом томе не воспроизводится, поэтому раздел 1 и начинает со сноса namespace вместе с томом.

**Почему это до RBAC.** Пока шаблон нарушает `restricted`, новые поды **не создаются вообще**. Права можно применить и первыми, но проверить их будет не на чем: под, который мог бы прочитать конфиг, не появится.

Проверено на стенде: `fixed/rbac.yaml` плюс `set serviceaccount` на сломанном шаблоне дают новый ReplicaSet с нулём подов (`DESIRED 1, CURRENT 0, READY 0`), в условиях Deployment — `ReplicaFailure=True FailedCreate`, живые поды остаются под учёткой `default`, и в логе всё тот же `CONFIG FAIL: HTTP 403`. Права в кластере при этом уже лежат.

### 4.2. RBAC: одно право ровно под задачу

```bash
kubectl apply -n case04 -f cases/04-rbac-securitycontext/fixed/rbac.yaml
kubectl set serviceaccount -n case04 deploy/api api
kubectl -n case04 rollout status deploy/api --timeout=180s
kubectl apply -n case04 -f cases/04-rbac-securitycontext/fixed/app.yaml   # или оба фикса сразу
```

Вторая строка — вся починка второй половины: под начинает **предъявлять свою** учётку. `serviceAccountName` входит в шаблон пода, а шаблон неизменяем: правильный фикс всегда на один выкат медленнее неправильного.

**`-n case04` обязателен и в `set serviceaccount`.** Без него команда уходит в namespace из kubeconfig и целится в тамошний deployment `api`. На этом стенде такого нет, и она честно отвечает `Error from server (NotFound): deployments.apps "api" not found`. Но окажись рядом чужой `api` — ответ был бы бодрым `serviceaccount updated`, и починен был бы не тот объект. Это тот же дефект, о котором кейс: команда выполнена, адресат другой.

**Проверки.** Показания снимаем с конкретного пода: во время выката в namespace живут поды разных версий, часть уже удаляется, но всё ещё `Ready`. `$POD` — самый свежий под, который готов и не удаляется.

```bash
POD=$(kubectl -n case04 get pods -l app=api \
  -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{" "}{.metadata.name}{" "}{.status.containerStatuses[0].ready}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' \
  | sort | awk '$3=="true" && $4==""{print $2}' | tail -1)

kubectl -n case04 exec deploy/api -- id
# → uid=1001 gid=1001 groups=1001

kubectl -n case04 get pod $POD -o jsonpath='{.spec.securityContext}{"\n"}'
# → {"fsGroup":1001,"runAsGroup":1001,"runAsNonRoot":true,"runAsUser":1001,"seccompProfile":{"type":"RuntimeDefault"}}
kubectl -n case04 get pod $POD -o jsonpath='{.spec.containers[0].securityContext}{"\n"}'
# → {"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}
kubectl -n case04 get pod $POD -o jsonpath='{.spec.serviceAccountName}{"\n"}'
# → api

# под прошёл политику и не был отбит: в условиях Deployment больше нет ReplicaFailure
kubectl -n case04 get deploy api -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
# → Available=True MinimumReplicasAvailable
#   Progressing=True NewReplicaSetAvailable   ← было NewReplicaSetCreated

kubectl -n case04 exec deploy/api -- wget -q -O - http://api.case04.svc.cluster.local/
# → api uid=1001 — CONFIG ok: конфиг прочитан из API
kubectl -n case04 exec deploy/api -- wc -l /data/events.log
# → 142        ← запусти дважды с паузой: число растёт (ср. 2 → 8 в разделе 1)
sleep 7
kubectl -n case04 exec deploy/api -- wc -l /data/events.log
# → 155

kubectl -n case04 get configmap app-config --as=system:serviceaccount:case04:api
# → NAME         DATA   AGE
#   app-config   2      10m
kubectl -n case04 auth can-i delete pods -n case04 --as=system:serviceaccount:case04:api
# → no
kubectl -n case04 auth can-i --list -n case04 --as=system:serviceaccount:case04:api \
  | awk '$1 ~ /^[a-z]/ && $1 !~ /^(selfsubject|clustertrustbundles)/ {print}'
# → configmaps   []   [app-config]   [get]
kubectl -n case04 get configmap app-config --as=system:serviceaccount:case04:default
# → Forbidden
```

События `FailedCreate` из namespace никуда не делись: они живут около часа и остаются от прошлых попыток — судить по ним нельзя, надёжный признак один: пропавшее `ReplicaFailure`.

## 5. Уборка

```bash
kubectl delete ns case04
```

`kubectl delete ns` дожидается реального удаления, а не отдаёт управление сразу. Кластерных объектов кейс не создаёт: `ServiceAccount`, `Role` и `RoleBinding` уезжают вместе с namespace.

## Словарь

- **PSA (Pod Security Admission)** — встроенная в API-сервер проверка «приличный ли этот под», работает по метке на namespace.
- **`privileged` / `baseline` / `restricted`** — три профиля PSA: от «проверок нет» через «запрещены явные опасности» до «только non-root, без capabilities, с seccomp».
- **SecurityContext** — блок манифеста о том, от кого и с какими правами исполняется контейнер; бывает на уровне пода и на уровне контейнера.
- **`runAsNonRoot`** и **`runAsUser`** — заявление «не пускай от root» и uid, от которого процесс пойдёт на самом деле; заявление проверяет kubelet по образу.
- **`fsGroup`** — чьи файлы достанутся процессу: kubelet при монтировании тома меняет группу-владельца тома на это число.
- **ServiceAccount** — учётная запись, под которой под разговаривает с API-сервером; по умолчанию `default`, и прав у неё нет.
- **Role / RoleBinding** — что можно делать с ресурсами namespace / кому именно это можно.
- **`resourceNames`** — сужение правила до конкретного объекта по имени, самая узкая форма в RBAC; цена — `list` с ней не работает.
- **`kubectl auth can-i`** — вопрос «можно ли» без выполнения действия; с `--as=` и `--list` показывает, что разрешено чужой учётке.

## Почему именно так

**Почему «стало лучше» и «работает» — не одно и то же.** Все четыре дефекта кейса выглядят как «всё в порядке»: шаблон политику не нарушает — а под не стартует (отказал kubelet, не admission); профиль соблюдён, под стартовал — а приложение упало (том чужой); права выданы, прибор подтверждает — а приложение получает `403` (права не тому); «починили» одной командой, заработало без единого выката — а у учётки `default` стало 67 прав вместо одного (сняли защиту). Общее у них одно: делалось «то, что просят», а проверялось «то, что получилось». Поэтому в каждой проверке выше есть вторая половина: не «работает?», а «работает **именно так, как должно**?».

**Почему под не «не запустился», а «не создан».** У незапустившегося пода есть статус, события и логи — есть за что зацепиться. У несозданного нет ничего. Причина лежит на уровень выше, в условии Deployment: `ReplicaFailure=True FailedCreate`. Это то же иерархическое чтение, что у cert-manager в соседнем кейсе: верхний уровень показывает «в процессе» и тогда, когда процесс обречён, — `Progressing=True` не значит «хорошо».

**Почему проверка идёт реальным запросом, а не `auth can-i`.** `auth can-i` спрашивает «можно ли», ничего не делая, — и на правиле с `resourceNames` отвечает `no` там, где право есть (см. 3.3). Реальный запрос `kubectl get … --as=` отвечает от того же движка авторизации, который решает судьбу запроса приложения, и вместе с отказом называет того, кем кластер увидел просителя. Поэтому разрушительные глаголы (`delete pods`) проверяются через `auth can-i` — на сцене случайно удалённый под выглядит как поломка кейса, — а право на чтение проверяется настоящим чтением.

**Почему у приложения есть проба готовности.** `readinessProbe` — не украшение, а защита самого кейса. Без неё под, падающий сразу после старта, успевает побыть `Ready` доли секунды, выкат считает замену удачной и убивает старые поды — и вместо «сервис работает, а выкат стоит» на экране пустой Deployment. Файл `/www/healthz` приложение заводит **только после** того, как убедилось, что умеет писать в свой том: «готов» здесь означает «действительно работает».
