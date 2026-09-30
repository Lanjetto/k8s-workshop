# Кейс 1. Обновление приложений без даунтайма

**Namespace:** `case01`
**Что нужно из обвязки:** ничего сверх стенда, но минимум две воркер-ноды — на одной `drain` упирается в PDB и вторая половина кейса не показывает ничего.

**Файлы кейса:**

| Файл | Роль |
|---|---|
| `broken/app.yaml` | сломанное состояние: оба дефекта сразу |
| `fixed/app.yaml` | починка выката: стратегия + `readinessProbe` + `livenessProbe` |
| `fixed/pdb.yaml` | вторая часть кейса, к выкату отношения не имеет |
| `traffic-probe.yaml` | измерительный прибор: раз в секунду бьёт в сервис и печатает **только** отказы |

Все команды — из корня репозитория.

**Проблема.** Сервис из трёх подов теряет запросы во время выката. Поды `Running`, endpoints заполнены, снаружи всё зелёное — а клиенты получают `connection refused`.

**Почему это не выглядит как поломка.** В текущем состоянии дефекты не видны вообще: ничего не упало, ни события, ни красной строки. Они проявляются только в момент выката. Причин **две, и они независимы** — почти все называют одну.

**Суть кейса.** `maxUnavailable: 100%` без `readinessProbe` — не «медленный выкат», а гарантированный даунтайм, и лечится только обоими полями сразу. `PodDisruptionBudget` — отдельная история про обслуживание нод, к выкату он отношения не имеет.

---

## 1. Поднять сломанное состояние

```bash
kubectl create ns case01
kubectl apply -n case01 -f cases/01-rolling-update/broken/app.yaml
kubectl -n case01 rollout status deploy/web --timeout=180s
sleep 25          # приложение стартует 15с, readinessProbe нет — статус врёт
kubectl -n case01 get pods -o wide
# → три пода web-... в 1/1 Running на воркерах
```

Сначала убеждаемся, что приложение живо, и только потом включаем счётчик — иначе
холодный старт попадёт в отказы:

```bash
kubectl -n case01 apply -f cases/01-rolling-update/traffic-probe.yaml
kubectl -n case01 wait --for=condition=Ready pod/traffic-probe --timeout=120s
sleep 5
kubectl -n case01 logs traffic-probe | grep -c FAIL
# → 0

kubectl -n case01 exec deploy/web -- wget -q -O - http://web.case01.svc.cluster.local/
# → ok
```

Ожидаемый результат: прибор видит **здоровый** сервис, отказов ноль, сервис отвечает
по имени `web`, а не по поду — проверяем то, что видит клиент. Если тут не ноль —
кейс врёт, вести его нельзя: почти всегда приложение отдаёт `404`. **Вопрос в зал:**
«Сервис выглядит здоровым. Что случится, когда я его обновлю?»

---

## 2. Диагностика

### 2.1. Сколько именно теряется

```bash
kubectl -n case01 logs traffic-probe | grep -c FAIL
# → 0   (до выката)

kubectl -n case01 rollout restart deploy/web
kubectl -n case01 rollout status deploy/web --timeout=300s
sleep 25
kubectl -n case01 logs traffic-probe | grep -c FAIL
# → 15  (на проверенном прогоне)
```

`15` — порядок величины, а не константа: счётчик отмеряет время, которое приложение
поднимается, поэтому на другом прогоне сдвинется на секунду-две. Важно, что оно
**не ноль** на сломанном и **ровно ноль** на починенном.

**Почему `sleep 25`, а не 5.** `rollout status` на сломанном деплое возвращается
раньше, чем кончаются отказы: без `readinessProbe` поды рапортуют `Ready` через
секунду после старта контейнера, и контроллер считает выкат завершённым, пока
`httpd` ещё спит свои 15 секунд. С `sleep 5` счётчик покажет всего ~5 — это
не потери выката, а момент, в который его застали.

Прибор бьёт раз в секунду, поэтому одна строка `FAIL` — это примерно **секунда**
недоступности, и весь отсчёт `15` означает, что сервис лежал около 15 секунд
(ровно столько приложение поднимается).

### 2.2. Дефект первый: стратегия

```bash
kubectl -n case01 get deploy web -o jsonpath='maxUnavailable={.spec.strategy.rollingUpdate.maxUnavailable} maxSurge={.spec.strategy.rollingUpdate.maxSurge}{"\n"}'
```
```
maxUnavailable=100% maxSurge=0
```

**Вывод:** `maxUnavailable: 100%` читается как «разрешить снести до 100%», а на деле
это **приказ** снести всё сразу. `maxSurge: 0` добивает: перекрытия нет вообще.

### 2.3. Дефект второй: нет `readinessProbe`

```bash
kubectl -n case01 get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}{"\n"}'
# → (пусто)

kubectl -n case01 rollout restart deploy/web
sleep 5
kubectl -n case01 get pods -l app=web
# → три НОВЫХ пода уже 1/1 Running, хотя httpd ещё спит свои 15 секунд
#   (рядом всё ещё висят три СТАРЫХ пода в Terminating — см. ниже)

kubectl -n case01 exec deploy/web -- wget -q -O - --timeout=1 http://localhost:8080/
# → wget: can't connect to remote host (127.0.0.1): Connection refused
#   command terminated with exit code 1
```

**Пауза здесь обязательна, и вот почему.** Сразу после `rollout restart` новые поды
ещё `ContainerCreating`, а старые — живые и всё ещё `Running`: в первый момент
`kubectl exec deploy/web` выбирает под из старых, и вы получите бодрое `ok` вместо
отказа. Через ~5 секунд новые поды уже `Running`, старые ещё `Terminating` — и
`exec` бьёт в новый под, который в балансировке есть, а порт не слушает.

Отдельно обратите внимание на `Terminating` у старых подов: `maxUnavailable: 100%`
не убивает их мгновенно, а разом помечает на удаление, и они висят ещё до 30 секунд,
пока их не добьёт grace period. Из балансировки они при этом выпадают сразу — и
именно поэтому сервис и теряет трафик.

**Вывод:** под попадает в endpoints Service сразу после старта контейнера, трафик
льётся в порт, который никто не слушает. Дефекты работают в связке:
`maxUnavailable: 0` без `readinessProbe` бесполезен — новый под «готов» через секунду,
контроллер Deployment сносит старый, трафик идёт в мёртвый порт.

---

## 3. Тупики: что не помогает и почему

**Больше реплик** — не причина: три пода сносятся разом так же, как один, если стратегия это разрешает.

**`PodDisruptionBudget`** — самый частый ответ, и он неверный:

```bash
kubectl -n case01 apply -f cases/01-rolling-update/fixed/pdb.yaml
kubectl -n case01 rollout restart deploy/web && kubectl -n case01 rollout status deploy/web --timeout=300s
sleep 25 && kubectl -n case01 logs traffic-probe | grep -c FAIL
# → 14: потери те же, что и без PDB
```

PDB ограничивает **только добровольные вытеснения** — `drain`, обслуживание нод, автоскейлер. Rolling update делает сам контроллер Deployment, PDB в нём не участвует. **PDB оставляем применённым**: он нужен в 4.2, он просто не про выкат.

**`livenessProbe`** — не то: перезапускает зависший контейнер, а не убирает под из балансировки.

**Одна правка вместо двух** — `maxUnavailable: 0` без пробы:

```bash
kubectl -n case01 patch deploy web -p '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":0,"maxSurge":1}}}}'
kubectl -n case01 rollout restart deploy/web && kubectl -n case01 rollout status deploy/web --timeout=300s
sleep 25 && kubectl -n case01 logs traffic-probe | grep -c FAIL
# → 15: СТОЛЬКО ЖЕ. Правка стратегии не помогла вообще
```

Это и есть ловушка кейса: одна правка **не чинит ничего**.

Почему не помогает `maxUnavailable: 0`: он держит старый под до тех пор, пока новый
не станет `Ready`. Но без `readinessProbe` новый под становится `Ready` через секунду
после старта контейнера — то есть `maxUnavailable: 0` честно ждёт сигнала, которого
никто не подаёт. Замер по секундам: `EndpointSlice` не пустеет (3 адреса → 6 → 3),
но все «готовые» адреса — это новые поды, которые ещё спят; старые в это время уже
`Terminating` и из балансировки выпали. Отказ снова сплошной и снова ~15 секунд.

---

## 4. Решение

### 4.1. Выкат: стратегия **и** пробы

```bash
kubectl apply -n case01 -f cases/01-rolling-update/fixed/app.yaml
kubectl -n case01 rollout status deploy/web --timeout=300s
kubectl -n case01 get deploy web -o jsonpath='{.spec.strategy}{"\n"}'
# → {"rollingUpdate":{"maxSurge":1,"maxUnavailable":0},"type":"RollingUpdate"}
```

`jsonpath` отдаёт компактный JSON, а не YAML: ключи идут по алфавиту
(`maxSurge` раньше `maxUnavailable`) — читается как `maxSurge: 1`, `maxUnavailable: 0`.

Это тоже выкат, около минуты: поды меняются строго по одному, каждый стартует 15с.
Пересоздаём прибор, чтобы счётчик начался с нуля — без сброса не отличить «починка
работает» от «повезло». Дальше контрольный выкат — тот же сценарий, что давал
15 отказов:

```bash
kubectl -n case01 delete pod traffic-probe --ignore-not-found --wait=true
kubectl -n case01 apply -f cases/01-rolling-update/traffic-probe.yaml
kubectl -n case01 wait --for=condition=Ready pod/traffic-probe --timeout=120s
sleep 5 && kubectl -n case01 logs traffic-probe | grep -c FAIL
# → 0

kubectl -n case01 rollout restart deploy/web
kubectl -n case01 rollout status deploy/web --timeout=300s
sleep 5 && kubectl -n case01 logs traffic-probe | grep -c FAIL
# → 0, потерь нет
```

Проверка, что сервис жив, а не «просто не упал»:

```bash
kubectl -n case01 get deploy web
# → READY 3/3, UP-TO-DATE 3, AVAILABLE 3
kubectl -n case01 get endpointslice -l kubernetes.io/service-name=web
# → в ENDPOINTS три адреса
```

### 4.2. Обслуживание нод: PDB

```bash
kubectl -n case01 get pdb web
```
```
NAME   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
web    2               N/A               1                     ...
```

`minAvailable: 2` при `replicas: 3`: одновременно можно вытеснить не больше одного
пода. Пробуем обслужить ноду:

```bash
kubectl get nodes
# → workshop-control-plane, workshop-worker, workshop-worker2
```

Сначала смотрим, где стоят поды. Блокируется только та нода, где их **больше
одного** — нода с единственным подом уедет пустой, потому что одного вытеснения
PDB как раз разрешает (`ALLOWED DISRUPTIONS: 1`):

```bash
kubectl -n case01 get pods -l app=web -o wide
# → два пода web-... на одной воркер-ноде и один на другой
#   drain'им ту, где их ДВА
```

```bash
kubectl drain <нода-с-двумя-подами> --ignore-daemonsets --delete-emptydir-data --force --timeout=30s
```
```
node/<нода> cordoned
evicting pod case01/web-...
evicting pod case01/web-...
error when evicting pods/"web-..." -n "case01" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
...
error: unable to drain node "<нода>" due to error: [...], continuing command...
```

Первый под уезжает, второй — нет: `drain` завершается с ненулевым кодом и
перечисляет поды, которые вытеснить не дали.

`drain` выселяет с ноды **все** поды, не только поды кейса, — на стенде, где
рядом живут другие namespace, это стоит держать в голове.

**Что сказать:** вытеснение заблокировано намеренно — второй под с этой ноды выбить нельзя, иначе от сервиса останется один живой под. Оборотная сторона, иначе унесут в прод как «серебряную пулю»: слишком строгий PDB **блокирует обслуживание кластера**. Поставь `minAvailable` равным числу реплик — `drain` станет невозможен навсегда. `minAvailable: 2` при `replicas: 3` — баланс, а не «чем больше, тем лучше».

Возвращаем ноду в строй (`drain` её ещё и кордонирует):

```bash
kubectl uncordon <нода-с-двумя-подами>
kubectl get nodes
# → пометка SchedulingDisabled снята
```

---

## 5. Уборка

```bash
kubectl delete ns case01
```
```
namespace "case01" deleted
```

Если сносишь и сразу поднимаешь заново — **сначала пересоздай namespace**. `kubectl
delete ns` убирает объект сразу, вместе с ним уходят и поды, поэтому повторный
`apply -f` без `create ns` падает:

```bash
kubectl delete ns case01
kubectl apply -n case01 -f cases/01-rolling-update/broken/app.yaml
```
```
Error from server (NotFound): error when creating "cases/01-rolling-update/broken/app.yaml": namespaces "case01" not found
```

То есть цикл «снёс — поднял заново» начинается с `kubectl create ns case01`.

---

## Словарь

- **`maxUnavailable`** — сколько подов разрешено держать неготовыми во время выката: `100%` = «снести можно все».
- **`maxSurge`** — сколько подов сверх `replicas` разрешено создать на время выката: `0` = перекрытия не будет.
- **`readinessProbe`** — проверка готовности: пока не проходит, под **не попадает** в endpoints Service и трафика не получает.
- **`livenessProbe`** — проверка живости: не проходит — kubelet перезапускает контейнер, из балансировки не убирает.
- **endpoints / EndpointSlice** — адреса подов, которые реально стоят за Service. Пустой = трафик некуда направить.
- **PodDisruptionBudget (PDB)** — ограничение на **добровольные** вытеснения подов; к rolling update отношения не имеет.
- **вытеснение (eviction)** — вежливое удаление пода через API: добровольное (`drain`) или вынужденное (нода умерла). PDB видит только первое.
- **`drain`** — выселить все поды с ноды и пометить её `SchedulingDisabled`.
- **`uncordon`** — снять пометку и вернуть ноду в работу.

---

## Почему именно так

**Приложение спит 15 секунд** — иначе окно отказа было бы около секунды и кейс не читался бы с экрана.

**Прибор бьёт по имени сервиса, а не по поду** — проверяем то, что видит внешний клиент. И печатает только `FAIL`: иначе логи превращаются в простыню и момент отказа в них не разглядеть.

**Счётчик сбрасывается после починки** — переход из сломанного состояния в починенное тоже выкат, и он стоит отказов. Не сбросив их, увидим «0 потерь» на грязном счётчике и не отличим починку от везения.

**Прибор калибруется до эксперимента:** проверка «0 отказов на здоровом сервисе» существует потому, что `busybox httpd` на пустой директории отдаёт `404`, а `wget` на HTTP-ошибку возвращает ненулевой код — кейс уже один раз врал, показывая потери там, где их нет.

**`livenessProbe` здесь не про эту проблему**, но `initialDelaySeconds: 20` у неё обязателен: приложение стартует 15 секунд, и с меньшим значением kubelet начнёт убивать под в момент подъёма — `CrashLoopBackOff` на ровном месте.
