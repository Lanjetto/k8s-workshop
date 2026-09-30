# Кейс 2. Сетевая безопасность: NetworkPolicy, Ingress, TLS

**Namespace:** `case02` (+ `ingress-nginx` — там живёт прибор)
**Что нужно из обвязки:** Calico (kindnet не энфорсит NetworkPolicy), ingress-nginx, cert-manager

**Файлы кейса:**

| Файл | Роль |
|---|---|
| `broken/app.yaml` | приложение: `api` + `db` + сервисы. **Здесь не сломано ничего** |
| `broken/netpol.yaml` | сломанная политика: `default-deny` + одно правило из четырёх |
| `broken/ingress.yaml` | вход: Ingress + `Certificate` с чужим `issuerRef` |
| `fixed/netpol-dns.yaml` | фикс сети, правило 1: вылечить имена |
| `fixed/netpol-ingress-api.yaml` | фикс сети, правило 2: впустить контроллер |
| `fixed/netpol-db-ingress.yaml` | фикс сети, правило 3: второй замок на `db` |
| `fixed/certificate.yaml` | фикс TLS: правильный подписант |
| `issuer.yaml` | self-signed CA для cert-manager — инфраструктура, не реквизит |
| `probe.yaml` | измерительный прибор: двусторонний, живёт в namespace `ingress-nginx` |

Все команды — из корня репозитория. Манифесты кейса не содержат поля `namespace`, поэтому всё, что адресовано приложению, накатывается с явным `-n case02`: namespace в вашем kubeconfig-контексте может быть любым, и без `-n` объект молча уедет в `default`. Исключение — `issuer.yaml`: его `ClusterIssuer` кластерный, а `Certificate` CA несёт свой namespace в самом файле.

**Проблема.** `api` не ходит в `db`, сайт `shop.workshop.local` снаружи не открывается, сертификат не выпускается. **Почему это не выглядит как поломка:** оба пода `1/1 Running`, рестартов нет, событий об ошибке нет. `api` отвечает, `db` отвечает, `httpd` слушает — не упало ничего, просто трафик не идёт.

**Суть кейса.** Сетевую сегментацию включили и бросили: `default-deny` накатан, а правил к нему написано одно из четырёх. `NetworkPolicy` ничего не запрещает — она **перестаёт разрешать**, и искать надо отсутствующее, а не сломанное: в кластере нет объекта, который можно найти. Главный вывод: «стало работать» — **не критерий**. Критерий — «работает то, что должно, и НЕ работает то, что не должно». Проверка второй половины — отдельная команда, и без неё «снёс политику» неотличимо от починки.

---

## 1. Поднять сломанное состояние

Раздел начинается со сноса прошлого прогона, и это не ритуал. `kubectl apply` накатывает только то, что перечислено в манифестах, и ничего не удаляет: оставшиеся от прошлого раза `allow-dns`, `allow-ingress-to-api` и `allow-db-from-api` переживут накат `broken/netpol.yaml`, и обещанное «сломанное» состояние окажется уже починенным. Проверено: без этих трёх строк повторный прогон даёт `unchanged` на оба объекта `broken/netpol.yaml`, вход остаётся открытым, и весь кейс разваливается.

```bash
kubectl delete ns case02 --ignore-not-found
kubectl wait --for=delete namespace/case02 --timeout=120s
kubectl create ns case02 --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f cases/02-network-security/issuer.yaml
kubectl wait --for=condition=Ready certificate/workshop-ca -n cert-manager --timeout=120s
kubectl get clusterissuer
# → workshop-ca и workshop-selfsigned, оба True
kubectl apply -n case02 -f cases/02-network-security/broken/app.yaml
kubectl -n case02 rollout status deploy/api
kubectl -n case02 rollout status deploy/db
```

**Пауза 10 секунд** между `app.yaml` и `netpol.yaml` обязательна. В поде `api` крутится цикл, который раз в секунду проверяет канал до `db`; пауза отделяет появление подов от наката политики, чтобы у `db` было время поднять `httpd`, а канал — отработать вхолостую. Накати политику сразу — первая же итерация попадёт в зазор вместо того, чтобы пройти молча.

Чистого старта лога пауза, однако, **не гарантирует**, и обещать этого не надо: проверено на стенде — первая строка всё равно оказывается про **другой** дефект, только по бытовой причине (см. разбор ниже). Диагноз ставится по окну после наката политики, а не по первой строке.

```bash
sleep 10
kubectl apply -n case02 -f cases/02-network-security/broken/netpol.yaml
kubectl apply -n case02 -f cases/02-network-security/broken/ingress.yaml
kubectl apply -n ingress-nginx -f cases/02-network-security/probe.yaml
```

Ожидаемый результат — сломано ровно то, что заложено: поды живы, прибор откалиброван, вход снаружи закрыт.

```bash
kubectl -n case02 get pods -o wide
# → api-6f5d96476c-xxxxx и db-5cf78689cc-xxxxx — оба 1/1 Running, 0 рестартов
#   (хвост имени пода случайный, устойчивы только хеши ReplicaSet)
kubectl -n ingress-nginx logs net-probe --tail=50 | grep SELF
# → SELF ok: DNS снаружи case02 живой — прибору можно верить
kubectl -n case02 logs deploy/api --since=30s
# → FAIL ...  DNS: db.case02.svc.cluster.local не резолвится
#   (окно может захватить и строки, накопившиеся ДО наката политики, —
#    в том числе стартовый артефакт; диагноз ставят по строкам про DNS)
kubectl -n ingress-nginx logs net-probe --tail=50 | grep 'вход'
# → !!! ...  вход  api: НЕДОСТУПЕН (нет ответа)
```

`SELF ok` — калибровка: в namespace `ingress-nginx` политик нет, поэтому DNS там обязан работать. Сломан он даже здесь — виноват стенд, а не кейс, и все дальнейшие отказы врут.

**Не берите первую строку лога за диагноз.** Проверено на стенде: `kubectl -n case02 logs deploy/api` (без окна) открывается строкой `api -> db: имя резолвится, соединение НЕ проходит` — и это **не** дефект политики, а бытовой артефакт старта. `api` поднялся на секунду раньше `db`, `httpd` у соседа ещё не слушал, `wget` честно не дождался и записал отказ. Через секунду канал молча заработал, и лишь потом накат политики сменил причину отказа на `DNS:`. Пауза в 10 секунд этот артефакт не убирает. Поэтому состояние читают **окном** (`--since`), а не первой строкой: окно, взятое после наката политики, содержит только `DNS:` — как в блоке выше. Кто берёт первую строку за диагноз, получает не тот дефект и разбирает кейс не с того конца.

---

## 2. Диагностика

### 2.1 DNS-egress отсутствует

Лог `api` печатает **только отказы**, поэтому свежая улика в нём есть всегда:

```bash
kubectl -n case02 logs deploy/api --since=20s
# → FAIL 18:40:13  DNS: db.case02.svc.cluster.local не резолвится
#   FAIL 18:40:16  DNS: db.case02.svc.cluster.local не резолвится
kubectl -n case02 exec deploy/api -- nslookup db.case02.svc.cluster.local
# → ;; connection timed out; no servers could be reached
#   (висит ~5 секунд и падает — DNS закрыт)
```

Отказ не «соединение не проходит», а «имени нет». `default-deny` закрыл `egress` целиком, и DNS-запрос в `kube-system` ушёл в никуда вместе со всем остальным. Лечится это не правилом про базу: строки в логе идут раз в 3 секунды, а не раз в секунду, потому что Calico гасит заблокированный трафик молчанием (`DROP`) и каждая попытка сначала ждёт свой таймаут.

**Правило чтения логов.** Состояние канала читается **окном времени** (`--since`), а не хвостом (`--tail`). Лог `api` печатает только отказы: после починки новых строк в нём не появится вообще, и хвост покажет **старые** — «починилось» на экране выглядит ровно как «всё ещё сломано». Счётчик за окно говорит «за последние N секунд отказов не было»; хвост не говорит ничего. Ловушка того же рода: `grep "ДОСТУПЕН"` совпадёт внутри `НЕДОСТУПЕН` и покрасит **сломанный** вход в зелёный — паттерн нужен полный, `"api: ДОСТУПЕН"`.

### 2.2 ingress от ingress-nginx отсутствует

```bash
curl -k --resolve shop.workshop.local:443:127.0.0.1 https://shop.workshop.local/
# → <html><head><title>504 Gateway Time-out</title></head> ...
curl -sk --resolve shop.workshop.local:443:127.0.0.1 -o /dev/null -w '%{http_code} %{time_total}\n' https://shop.workshop.local/
# → 504 3.00xxxx
```

`504` — «шлюз не дождался бэкенда». Сервер жив, приложение живо, endpoints у сервиса есть — трафик до пода просто не доходит. `503` был бы, если бы endpoints не было; здесь они есть, под жив и в балансировке. Три секунды вместо минуты — таймауты nginx уменьшены в манифесте: `proxy-connect-timeout` и `proxy-read-timeout` стоят в 3с вместо дефолтных 60с, а `proxy-next-upstream-tries: 1` убирает две лишние попытки. Кто посередине:

```bash
kubectl -n ingress-nginx get pods
```

Контроллер `ingress-nginx` живёт в **другом** namespace. Для пода `api` он такой же чужак, как кто угодно из интернета: политика не знает слов «доверенная сеть», она знает namespace и лейблы. Без явного правила контроллер отсекается наравне со всеми.

### 2.3 У правила api -> db нет ingress на приёмнике

```bash
kubectl -n case02 get networkpolicy \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.policyTypes}{"\n"}{end}'
# → allow-api-to-db   ["Egress"]
#   default-deny      ["Ingress","Egress"]
```

Правило `allow-api-to-db` описывает **одну** сторону соединения. `NetworkPolicy` — двойной замок: разрешение нужно и у источника (`egress`), и у приёмника (`ingress`). Правило на одной стороне не работает и **ничем себя не выдаёт**: объект в кластере есть, `kubectl get netpol` его показывает, `describe` молчит. Ни ошибки, ни события, ни условия — есть только трафик, который не идёт. `-o yaml` здесь не бери: он вываливает `last-applied-configuration` цельной JSON-строкой, и найти в ней нужное невозможно.

### 2.4 Certificate ссылается на несуществующий letsencrypt-prod

```bash
kubectl -n case02 get certificate
# → shop-tls   False   shop-tls   28s
kubectl -n case02 describe certificate shop-tls
# → Normal  Issuing     Issuing certificate as Secret does not exist
#   Normal  Generated   Stored new private key in temporary Secret resource "shop-tls-xxxxx"
#   Normal  Requested   Created new CertificateRequest resource "shop-tls-1"
```

`READY: False` и **ни слова о причине**. `describe` показывает три события, и все три `Normal` — читается как «работает, выпускает, подожди». Ждать можно вечно. Причина на уровень глубже:

```bash
kubectl -n case02 get certificaterequest
# → shop-tls-1   True   —   False   letsencrypt-prod   149s
kubectl -n case02 describe certificaterequest | grep -m1 IssuerNotFound
# → Normal  IssuerNotFound  ...  Referenced "ClusterIssuer" not found: clusterissuer.cert-manager.io "letsencrypt-prod" not found
```

`grep` здесь не для красоты: голый `describe certificaterequest` печатает **11** строк событий и вдобавок вываливает base64 CSR. Событие `IssuerNotFound` повторяется по разу на каждый известный cert-manager тип подписанта (`-acme`, `-ca`, `-selfsigned`, `-vault`, `-venafi`), и рядом лежат пять `WaitingForApproval` — то есть причина закопана в однообразном шуме, который читается как «идёт работа».

`letsencrypt-prod` нет и в списке живых подписантов (`kubectl get clusterissuer` — только `workshop-ca` и `workshop-selfsigned`, оба `True`), и быть не может: см. «Почему именно так». У cert-manager диагностика иерархическая: `Certificate` → `CertificateRequest` → `Secret`, и верхний уровень показывает «в процессе» даже тогда, когда процесс обречён. Чей сертификат при этом реально отдаётся снаружи:

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername shop.workshop.local 2>/dev/null | openssl x509 -noout -subject -issuer
# → subject и issuer = O = Acme Co, CN = Kubernetes Ingress Controller Fake Certificate
```

Главный симптом всей TLS-части: сайт открывается, ошибок нет — а сертификат чужой. `ingress-nginx` при отсутствии секрета молча подставляет заглушку, поэтому в TLS нельзя верить факту «сайт открылся»: надо смотреть, **чей** сертификат отдаётся.

---

## 3. Тупики: три шага «почти починил»

### 3.1 `dns` — отказов столько же, изменился только текст

```bash
kubectl -n case02 logs deploy/api --tail=1
# → FAIL 18:40:13  DNS: db.case02.svc.cluster.local не резолвится
kubectl apply -n case02 -f cases/02-network-security/fixed/netpol-dns.yaml
sleep 16
kubectl -n case02 logs deploy/api --tail=3
# → FAIL 18:40:34  api -> db: имя резолвится, соединение НЕ проходит
#   FAIL 18:40:37  api -> db: имя резолвится, соединение НЕ проходит
```

Отказов ни на один меньше. Изменилась только их **причина**: это два разных дефекта, и один не лечит другой. Первый текст говорит «нет правила про DNS», второй — «нет правила на трафик». Возврат: `kubectl delete -n case02 -f cases/02-network-security/fixed/netpol-dns.yaml`

### 3.2 `half` — разрешение есть, трафик не идёт

Применяем весь фикс сети, **кроме** правила `ingress` на `db`:

```bash
kubectl apply -n case02 -f cases/02-network-security/fixed/netpol-dns.yaml
kubectl apply -n case02 -f cases/02-network-security/fixed/netpol-ingress-api.yaml
kubectl apply -n case02 -f cases/02-network-security/fixed/netpol-db-ingress.yaml
kubectl delete networkpolicy -n case02 allow-db-from-api
sleep 18
kubectl -n ingress-nginx logs net-probe --since=60s
# → ok ...  вход  api: ДОСТУПЕН
kubectl -n case02 logs deploy/api --since=12s
# → FAIL ...  api -> db: имя резолвится, соединение НЕ проходит
```

Вход открылся, а `api` до `db` так и не дошёл — **хотя разрешение в кластере есть**:

```bash
kubectl -n case02 get networkpolicy allow-api-to-db -o yaml
# → policyTypes: [Egress], egress.to: podSelector app=db, порт 8080
```

Правило на месте, описывает ровно то, что нужно, и не работает. Это двойной замок из 2.3, показанный руками. Возврат: `kubectl delete networkpolicy -n case02 allow-dns allow-ingress-to-api`

### 3.3 `badfix` — «снести политику»

Самый частый «фикс» такой аварии в реальности:

```bash
kubectl delete networkpolicy -n case02 default-deny
sleep 18
kubectl -n ingress-nginx logs net-probe --since=45s
# → ok  ...  вход  api: ДОСТУПЕН
#   !!! ...  утечка  db: ДОСТУПНА СНАРУЖИ — политика дырявая
kubectl -n ingress-nginx exec net-probe -- wget -q -O- http://db.case02.svc.cluster.local/
# → db ok
```

Заработало. И заметить подвох, кроме прибора, нечем: сайт открывается, ошибок нет, все довольны. Внутренняя база отдаёт содержимое кому угодно из кластера. Это не починка, а снятие защиты — и **снаружи эти два состояния неотличимы**. Возврат: `kubectl apply -n case02 -f cases/02-network-security/broken/netpol.yaml`

---

## 4. Решение

### 4.1 Сеть: три правила, которых не хватало

```bash
kubectl apply -n case02 -f cases/02-network-security/fixed/netpol-dns.yaml
kubectl apply -n case02 -f cases/02-network-security/fixed/netpol-ingress-api.yaml
kubectl apply -n case02 -f cases/02-network-security/fixed/netpol-db-ingress.yaml
sleep 18
```

Проверяем **оба** канала. Второй — не формальность:

```bash
kubectl -n ingress-nginx logs net-probe --since=60s
# → ok  ...  вход  api: ДОСТУПЕН
#   ok  ...  утечка  db: закрыта снаружи — правильно, это внутренний сервис
kubectl -n case02 logs deploy/api --since=15s
# → пусто: за последние 15 секунд отказов не было
curl -sk --resolve shop.workshop.local:443:127.0.0.1 -o /dev/null \
  -w '%{http_code}\n' https://shop.workshop.local/
# → 200   (сертификат пока заглушка — это чинится в 4.2, поэтому -k)
```

Три правила, ничего лишнего: конкретный источник, конкретный порт.

### 4.2 TLS: Certificate на свой CA

```bash
kubectl apply -n case02 -f cases/02-network-security/fixed/certificate.yaml
kubectl -n case02 wait --for=condition=Ready certificate/shop-tls --timeout=150s
kubectl -n case02 get certificate
# → shop-tls   True   shop-tls   113s
kubectl -n case02 get certificaterequest && kubectl -n case02 get secret shop-tls
# → CR дошёл до Ready, Secret shop-tls создан
```

Через 10–15 секунд — `ingress-nginx` пересобирает конфиг не мгновенно:

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername shop.workshop.local 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName
# → subject=CN = shop.workshop.local
#   issuer=CN = workshop-ca
#   X509v3 Subject Alternative Name:
#       DNS:shop.workshop.local
```

И самая честная проверка — `curl` **без** `-k`, с нашим корнем в доверенных:

```bash
kubectl -n cert-manager get secret workshop-ca-secret -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/workshop-ca.crt
curl -s --cacert /tmp/workshop-ca.crt --resolve shop.workshop.local:443:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://shop.workshop.local/
# → 200
```

`curl`, которому предъявили корень, не спрашивает браузер и не верит на слово.

---

## 5. Уборка

```bash
kubectl delete ns case02
kubectl -n ingress-nginx delete pod net-probe
```

`ClusterIssuer workshop-ca` и его CA в namespace `cert-manager` остаются намеренно: это кластерная инфраструктура, а не реквизит кейса. Снос `case02` их не трогает, следующий прогон начинается с готового подписанта.

---

## Словарь

**NetworkPolicy** — объект, который разрешает трафик между подами по лейблам и namespace. Не запрещает, а **перестаёт разрешать**: всё, что не разрешено явно, отбрасывается.
**ingress / egress** — две стороны одного соединения: `egress` у источника, `ingress` у приёмника. В `spec.policyTypes` перечислено, какие стороны правило описывает.
**Двойной замок** — следствие предыдущего: разрешение нужно с обеих сторон. Правило на одной стороне не работает и молчит об этом.
**CNI** — плагин, который эту политику исполняет. Здесь Calico; `kindnet` (дефолт kind) NetworkPolicy не энфорсит. Заблокированный трафик Calico гасит молчанием (`DROP`), поэтому отказ выглядит как зависание, а не как быстрая ошибка.
**Ingress-контроллер** — принимает трафик снаружи и раздаёт по Ingress-объектам. Здесь `ingress-nginx`, живёт в своём namespace.
**ClusterIssuer** — подписант сертификатов в cert-manager. Кластерный объект; cert-manager не создаёт его сам и не падает, если его нет, — он ждёт подписанта, а не подставляет своего.
**Self-signed CA / ACME** — свой удостоверяющий центр, подписавший сам себя (корень недоверенный), против протокола Let's Encrypt, который требует, чтобы CA дотянулся до твоего домена, — в kind это недостижимо.
**SNI** — имя хоста, которое клиент называет при TLS-рукопожатии. `openssl s_client -servername` подставляет его вручную, иначе nginx отдаст сертификат по умолчанию.

---

## Почему именно так

**Самоподписанный CA, а не Let's Encrypt.** ACME требует, чтобы удостоверяющий центр дотянулся до твоего домена (HTTP-01/DNS-01), а локальный кластер интернету не виден и публичного DNS не имеет. «Поставить Let's Encrypt» — первое, что хочется сделать, и первое, что здесь не работает. Смысл кейса от подмены не меняется: виден весь цикл `Certificate → CertificateRequest → Secret → трафик по HTTPS`. Разница ровно в одном — корень недоверенный, и это надо сказать вслух, иначе вопрос «а почему браузер ругается» повиснет.

**Issuer заводит кейс, а не кластер.** `issuer.yaml` применяется вместе с кейсом и переживает его снос: `ClusterIssuer` кластерный, его CA лежит в namespace `cert-manager`, который кейс не трогает, — следующий прогон не начинается с выпуска корня заново. А если положить `Certificate` CA рядом с приложением, секрет с корневым ключом окажется в namespace, который сносится вместе с кейсом.

**Прибор живёт в namespace `ingress-nginx`.** Он измеряет вход, а вход — это то, что видит чужак снаружи `case02`. В ровно таком положении находится контроллер, и прибор встаёт в его позицию: мерить надо с той стороны, с которой смотрит клиент. Прибор двусторонний: `вход api` должен открыться, `утечка db` — остаться закрытой. Без второй строки «снести политику» выглядело бы успешной починкой. Печатает он только **переходы** состояния, поэтому последняя строка про канал и есть его текущее состояние.

**`namespaceSelector` без `podSelector` — осознанный компромисс.** Точное правило впускало бы один под контроллера по лейблу, но тогда прибор не попал бы под измеряемое правило. Впускается весь namespace; в проде сузь до лейбла пода. И помни: `podSelector` **внутри** того же элемента `from`, что и `namespaceSelector`, — это И; в разных элементах — ИЛИ, и правило тихо станет «впустить такой под из любого namespace». Порты в правилах — порты **пода** (`8080`), а не сервиса (`80`): политика работает после DNAT от `kube-proxy`, и `80` здесь — классическая ошибка «правило есть, а не работает».

**`commonName` в `Certificate` задан ради читаемости.** Без него сертификат опознаётся только по SAN (`dnsNames`), и строка `subject` в `openssl x509` остаётся пустой — на сцене выглядит как недоделка. На доверие не влияет: браузеры давно смотрят в SAN.
