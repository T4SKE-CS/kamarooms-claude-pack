#!/usr/bin/env bash
# b24.sh — обёртка над REST API Битрикс24 для навыка bitrix24-tasks (пакет kamarooms-pack).
# Работает на macOS, Linux и в Git Bash на Windows.
#
# Ключ (адрес входящего вебхука) берётся из защищённого хранилища и НИКОГДА не печатается:
#   1. переменная окружения B24_WEBHOOK — только для тестов ИТ;
#   2. macOS: Связка ключей, запись kama-b24-webhook
#      (создаётся командой: security add-generic-password -a "$USER" -s kama-b24-webhook -w);
#   3. Windows (Git Bash): файл %LOCALAPPDATA%\KamaRooms\b24-webhook.dat, зашифрованный DPAPI,
#      читается через powershell.exe (создаётся командой из памятки ИТ к лекции по Битрикс24);
#   4. Linux: файл ~/.config/kamarooms/b24-webhook с правами 600.
#
# Использование:
#   b24.sh where                 — какое хранилище используется и найден ли ключ (сам ключ не выводится)
#   b24.sh whoami                — метод profile: кто я в Битриксе; плюс адрес портала и ID пользователя
#   b24.sh scope                 — права (scope) ключа
#   b24.sh call <метод> [файл]   — вызвать метод REST; тело запроса — JSON из файла ("-" = stdin); без файла — GET
#   b24.sh link <ID задачи>      — ссылка на задачу в портале
#
# Разрешены только методы из списка ALLOWED: создание задач и чтение. Остальное — отказ.
# Снять ограничение может ИТ переменной B24_ALLOW_ANY=1 (в навыке не используется).
#
# Наблюдатели по умолчанию: defaults.env рядом со скриптом (B24_DEFAULT_AUDITORS, ID через пробел).
# Запрос tasks.task.add без них в AUDITORS отклоняется — правило отеля; исключение: ответственный из списка.
#
# Коды возврата: 0 — успех; 1 — ошибка использования или окружения; 2 — Битрикс вернул {"error":...};
#                3 — ключ не найден; 4 — сеть/curl.
set -euo pipefail

SERVICE="kama-b24-webhook"
ALLOWED="profile scope methods user.search user.get user.current user.fields tasks.task.add tasks.task.list tasks.task.get tasks.task.getFields task.checklistitem.add task.checklistitem.getlist sonet_group.get"

# Наблюдатели по умолчанию: переменная окружения (для тестов ИТ) имеет приоритет над defaults.env.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -z "${B24_DEFAULT_AUDITORS+x}" ] && [ -r "$SCRIPT_DIR/defaults.env" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/defaults.env"
fi
B24_DEFAULT_AUDITORS="${B24_DEFAULT_AUDITORS:-}"

# PowerShell-фрагмент для Windows: расшифровать DPAPI-файл и вывести ключ в stdout (его читает только этот скрипт).
PS_GET_KEY='$p = Join-Path $env:LOCALAPPDATA "KamaRooms\b24-webhook.dat"; if (-not (Test-Path $p)) { exit 3 }; $s = (Get-Content $p | Select-Object -First 1) | ConvertTo-SecureString; $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); try { [Console]::Out.Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }'

KEY=""; PORTAL=""; USER_ID=""

die() { local code=$1; shift; printf 'b24: %s\n' "$*" >&2; exit "$code"; }

usage() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
}

storage_name() {
  if [ -n "${B24_WEBHOOK:-}" ]; then echo "переменная окружения B24_WEBHOOK"; return; fi
  case "$(uname -s)" in
    Darwin) echo "Связка ключей macOS, запись $SERVICE" ;;
    MINGW*|MSYS*|CYGWIN*) echo 'Windows: %LOCALAPPDATA%\KamaRooms\b24-webhook.dat (DPAPI, через powershell.exe)' ;;
    *) echo "файл ${XDG_CONFIG_HOME:-$HOME/.config}/kamarooms/b24-webhook" ;;
  esac
}

read_key() {
  local key=""
  if [ -n "${B24_WEBHOOK:-}" ]; then
    key="$B24_WEBHOOK"
  else
    case "$(uname -s)" in
      Darwin)
        key=$(security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null) \
          || die 3 "ключ не найден в Связке ключей (запись $SERVICE). Сохраните его в своём Терминале: security add-generic-password -a \"\$USER\" -s $SERVICE -w" ;;
      MINGW*|MSYS*|CYGWIN*)
        key=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$PS_GET_KEY" 2>/dev/null | tr -d '\r') \
          || die 3 'ключ не найден: нет файла %LOCALAPPDATA%\KamaRooms\b24-webhook.dat, либо он создан под другим пользователем Windows. Сохраните ключ командой из памятки ИТ' ;;
      *)
        local f="${XDG_CONFIG_HOME:-$HOME/.config}/kamarooms/b24-webhook"
        [ -r "$f" ] || die 3 "ключ не найден: нет файла $f (одна строка с адресом вебхука, права 600)"
        key=$(cat "$f") ;;
    esac
  fi
  key=$(printf '%s' "$key" | tr -d '[:space:]')
  key="${key%/}"
  [ -n "$key" ] || die 3 "хранилище найдено, но ключ пустой"
  printf '%s' "$key" | grep -Eq '^https://[^/]+/rest/[0-9]+/[A-Za-z0-9]+$' \
    || die 1 "ключ имеет неожиданный вид: ожидается https://<портал>/rest/<ID>/<код>/ (сам ключ не показываю)"
  KEY="$key"
  PORTAL="${key%%/rest/*}"
  USER_ID=$(printf '%s' "$key" | sed -E 's#^https://[^/]+/rest/([0-9]+)/.*$#\1#')
}

# Заменяет ключ на <ключ> во всём, что уходит на экран (страховка на случай, если curl вернёт URL в тексте ошибки).
redact() {
  if [ -n "$KEY" ]; then sed "s#${KEY}#<ключ>#g"; else cat; fi
}

allowed_check() {
  [ "${B24_ALLOW_ANY:-0}" = "1" ] && return 0
  local m
  for m in $ALLOWED; do [ "$m" = "$1" ] && return 0; done
  die 1 "метод $1 не входит в разрешённый список навыка (только создание задач и чтение). Разрешены: $ALLOWED"
}

# Задача без наблюдателей по умолчанию не уходит: правило отеля — руководство и офис видят
# каждую задачу, поставленную через навык. Ответственный из списка наблюдателем не дублируется.
check_default_auditors() {
  local file="$1" payload arr resp missing="" id
  [ -n "$B24_DEFAULT_AUDITORS" ] || return 0
  payload=$(tr -d '\n\r' < "$file")
  arr=$(printf '%s' "$payload" | grep -Eo '"AUDITORS"[[:space:]]*:[[:space:]]*\[[^]]*\]' || true)
  resp=$(printf '%s' "$payload" | grep -Eo '"RESPONSIBLE_ID"[[:space:]]*:[[:space:]]*"?[0-9]+' | grep -Eo '[0-9]+$' || true)
  for id in $B24_DEFAULT_AUDITORS; do
    [ "$id" = "$resp" ] && continue
    printf '%s' "$arr" | grep -Eq "(\[|,|[[:space:]])\"?${id}\"?[[:space:]]*(,|\])" || missing="$missing $id"
  done
  [ -z "$missing" ] || die 1 "в задаче нет обязательных наблюдателей (AUDITORS):$missing. Правило отеля: эти ID добавляются в каждую задачу — дополни поле AUDITORS и повтори (список по умолчанию: $B24_DEFAULT_AUDITORS)"
}

call_method() {
  local method="$1" body="${2:-}"
  allowed_check "$method"
  local url="$KEY/$method.json"
  local err rc=0 out="" tmpbody=""
  if [ "$body" = "-" ]; then
    tmpbody=$(mktemp); cat > "$tmpbody"; body="$tmpbody"
  fi
  if [ -n "$body" ]; then
    [ -r "$body" ] || die 1 "файл с телом запроса не найден: $body"
    [ "$method" = "tasks.task.add" ] && check_default_auditors "$body"
  fi
  err=$(mktemp)
  if [ -n "$body" ]; then
    out=$(curl -sS --max-time 40 -H 'Content-Type: application/json' --data-binary "@$body" "$url" 2>"$err") || rc=$?
  else
    out=$(curl -sS --max-time 40 "$url" 2>"$err") || rc=$?
  fi
  [ -n "$tmpbody" ] && rm -f "$tmpbody"
  if [ "$rc" -ne 0 ]; then
    printf 'b24: сеть/curl (код %s): %s\n' "$rc" "$(redact <"$err")" >&2
    rm -f "$err"
    exit 4
  fi
  rm -f "$err"
  printf '%s\n' "$out" | redact
  if printf '%s' "$out" | grep -q '^{"error"'; then exit 2; fi
}

cmd="${1:-help}"
case "$cmd" in
  where)
    echo "хранилище: $(storage_name)"
    read_key
    echo "ключ найден; портал: $PORTAL; пользователь ID: $USER_ID"
    echo "наблюдатели по умолчанию (AUDITORS): ${B24_DEFAULT_AUDITORS:-не заданы}"
    ;;
  whoami)
    read_key
    call_method profile
    echo "portal: $PORTAL"
    echo "user_id: $USER_ID"
    ;;
  scope)
    read_key
    call_method scope
    ;;
  call)
    [ -n "${2:-}" ] || die 1 "укажите метод: call <метод> [файл.json]"
    read_key
    call_method "$2" "${3:-}"
    ;;
  link)
    [ -n "${2:-}" ] || die 1 "укажите ID задачи: link <ID>"
    printf '%s' "$2" | grep -Eq '^[0-9]+$' || die 1 "ID задачи — целое число"
    read_key
    printf '%s/company/personal/user/%s/tasks/task/view/%s/\n' "$PORTAL" "$USER_ID" "$2"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    die 1 "неизвестная команда: $cmd (where | whoami | scope | call <метод> [файл] | link <ID>)"
    ;;
esac
