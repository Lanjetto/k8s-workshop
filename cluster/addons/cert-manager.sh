#!/usr/bin/env bash
# cert-manager — выпуск TLS-сертификатов для кейса 2.
#
# ВАЖНЫЙ МОМЕНТ ДЛЯ ВОРКШОПА. cert-manager в kind не может пройти ACME
# (Let's Encrypt требует публичный DNS и доступный извне HTTP-01/DNS-01 —
# в локальном кластере этого нет). Поэтому используем self-signed CA:
# ClusterIssuer → CA-сертификат → им подписываются сертификаты Ingress'ов.
#
# Смысл кейса от этого не меняется: слушатели видят весь цикл
# Certificate → CertificateRequest → Secret → трафик по HTTPS.
# Разница только в том, что корень недоверенный — и это надо сказать вслух,
# иначе первый же вопрос «а почему браузер ругается» повиснет.
#
# Порядок важен: сначала CRD и поды, и только потом ClusterIssuer —
# иначе CRD ещё не зарегистрированы и apply упадёт.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CM_VERSION="${CM_VERSION:-v1.21.2}"
MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CM_VERSION}/cert-manager.yaml"

log "cert-manager ${CM_VERSION}"
kubectl apply -f "$MANIFEST" >/dev/null

log "ждём CRD"
kubectl wait --for=condition=established --timeout=120s \
  crd/certificates.cert-manager.io crd/issuers.cert-manager.io crd/clusterissuers.cert-manager.io >/dev/null

log "ждём поды (webhook должен быть живым, иначе следующая стадия упадёт)"
kubectl -n cert-manager wait --for=condition=available --timeout=300s \
  deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector

ok "cert-manager готов"
kubectl -n cert-manager get pods
