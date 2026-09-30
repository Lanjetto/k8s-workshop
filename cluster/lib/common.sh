#!/usr/bin/env bash
# Общие помощники для скриптов стенда. Подключается через `source`.
# Не запускать напрямую.

set -euo pipefail

export PATH="$HOME/bin:$PATH"

CLUSTER_NAME="${CLUSTER_NAME:-workshop}"

# Цвета только если вывод — терминал (в логах CI/пайпах не мусорим escape-кодами).
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_RST=''
fi

log()  { printf '%s==>%s %s\n' "$C_DIM" "$C_RST" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
die()  { printf '%s error%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 1; }
