#!/bin/sh
# Скан репозитория на конфиденциальные данные (R4) перед каждым релизом.
# Ноль совпадений = зелёный статус (exit 0). Любое совпадение = exit 1.
# Разрешённое исключение: публичный контакт it@kamarooms.org.
set -u
cd "$(dirname "$0")/.." || exit 2

fail=0
report() {
  label="$1"; out="$2"
  if [ -n "$out" ]; then
    echo "== $label =="
    echo "$out"
    fail=1
  fi
}

# Исключаем сам этот скрипт (в нём шаблоны поиска), но НЕ каталоги с именем scripts:
# --exclude-dir сопоставляется с именем на любом уровне, и раньше из проверок молча выпадал
# plugins/kamarooms-pack/skills/bitrix24-tasks/scripts/ — ровно тот каталог, где лежали ID.
g() { grep -rInE "$1" --exclude-dir=.git --exclude=scan-secrets.sh . 2>/dev/null; }

report "IPv4-адреса"                    "$(g '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b')"
report "E-mail (кроме it@kamarooms.org)" "$(g '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | grep -v 'it@kamarooms.org')"
report "Телефоны"                       "$(g '\+7[0-9 ()-]{9,}|8 ?\(?9[0-9]{2}\)?[0-9 -]{7,}')"
report "Секреты (key=value)"            "$(g '(password|token|api[_-]?key|secret)[[:space:]]*[:=][[:space:]]*[^[:space:]]')"
report "Внутренние хосты/серийники"     "$(g '(192\.168|10\.[0-9]+\.|\.local\b|SEKRETAR|serial[[:space:]]*[:=])')"

# Внутренние идентификаторы Битрикс24 в пакете быть не должны: состав наблюдателей живёт
# в локальном файле на машине (~/.kamarooms/b24-defaults.env), а не в публичном репозитории.
report "Наблюдатели по умолчанию в пакете" \
  "$(grep -rInE '^[[:space:]]*B24_DEFAULT_AUDITORS[[:space:]]*=[[:space:]]*"?[0-9]' --exclude-dir=.git . 2>/dev/null)"

# Настоящие ID сотрудников. Ловим любую строку, где рядом со словом auditors/responsible/(ID
# стоит число из трёх и более цифр, в любом синтаксисе — JSON, bash, PowerShell. Условные числа
# примеров разрешены явным списком; чужой ID в этот список не попадёт, и скан загорится.
gi() { grep -rInEi "$1" --exclude-dir=.git --exclude=scan-secrets.sh . 2>/dev/null; }
report "ID сотрудников" \
  "$(gi '(auditors|responsible_id|\(id )[^0-9]{0,24}[0-9]{3,}' | grep -vE '\b(1001|1002|1234)\b')"

if [ "$fail" -eq 0 ]; then
  echo "OK: конфиденциальных данных не найдено (R4)"
fi
exit "$fail"
