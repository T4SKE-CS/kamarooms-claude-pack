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

g() { grep -rInE "$1" --exclude-dir=.git --exclude-dir=scripts . 2>/dev/null; }

report "IPv4-адреса"                    "$(g '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b')"
report "E-mail (кроме it@kamarooms.org)" "$(g '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | grep -v 'it@kamarooms.org')"
report "Телефоны"                       "$(g '\+7[0-9 ()-]{9,}|8 ?\(?9[0-9]{2}\)?[0-9 -]{7,}')"
report "Секреты (key=value)"            "$(g '(password|token|api[_-]?key|secret)[[:space:]]*[:=][[:space:]]*[^[:space:]]')"
report "Внутренние хосты/серийники"     "$(g '(192\.168|10\.[0-9]+\.|\.local\b|SEKRETAR|serial[[:space:]]*[:=])')"

if [ "$fail" -eq 0 ]; then
  echo "OK: конфиденциальных данных не найдено (R4)"
fi
exit "$fail"
