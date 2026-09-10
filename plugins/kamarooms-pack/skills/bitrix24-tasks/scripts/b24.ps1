<#
b24.ps1 — обёртка над REST API Битрикс24 для навыка bitrix24-tasks (пакет kamarooms-pack).
Для Windows без Git Bash (инструмент PowerShell в Claude Code). Windows PowerShell 5.1 и новее.

Запуск:
  powershell -NoProfile -ExecutionPolicy Bypass -File b24.ps1 <команда> [аргументы]

Команды:
  where                 — какое хранилище используется и найден ли ключ (сам ключ не выводится)
  whoami                — метод profile: кто я в Битриксе; плюс адрес портала и ID пользователя
  scope                 — права (scope) ключа
  call <метод> [файл]   — вызвать метод REST; тело запроса — JSON из файла (UTF-8); без файла — GET
  link <ID задачи>      — ссылка на задачу в портале

Ключ (адрес входящего вебхука) берётся из защищённого хранилища и НИКОГДА не печатается:
  1. переменная окружения B24_WEBHOOK — только для тестов ИТ;
  2. файл %LOCALAPPDATA%\KamaRooms\b24-webhook.dat, зашифрованный DPAPI под текущего пользователя Windows.
     Создаётся командой из памятки ИТ к лекции по Битрикс24 (в отдельном окне PowerShell):
     $d="$env:LOCALAPPDATA\KamaRooms"; New-Item -ItemType Directory -Force $d | Out-Null;
     Read-Host "Вставьте адрес вебхука" -AsSecureString | ConvertFrom-SecureString | Set-Content "$d\b24-webhook.dat"

Разрешены только методы из списка $Allowed: создание задач и чтение. Остальное — отказ.
Снять ограничение может ИТ переменной B24_ALLOW_ANY=1 (в навыке не используется).

Наблюдатели по умолчанию (B24_DEFAULT_AUDITORS, ID через пробел) берутся из первого источника,
где список непуст: переменная окружения -> локальный файл машины
%LOCALAPPDATA%\KamaRooms\b24-defaults.env -> defaults.env рядом со скриптом.
В самом пакете список пуст: это внутренние ID отеля, а репозиторий публичный — файл заводит ИТ.
Запрос tasks.task.add без них в AUDITORS отклоняется — правило отеля; исключение: ответственный из списка.

Коды возврата: 0 — успех; 1 — ошибка использования или окружения; 2 — Битрикс вернул {"error":...};
               3 — ключ не найден; 4 — сеть.
#>
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1)][string]$Arg1,
  [Parameter(Position = 2)][string]$Arg2
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Allowed = @(
  'profile', 'scope', 'methods',
  'user.search', 'user.get', 'user.current', 'user.fields',
  'tasks.task.add', 'tasks.task.list', 'tasks.task.get', 'tasks.task.getFields',
  'task.checklistitem.add', 'task.checklistitem.getlist',
  'sonet_group.get'
)
$DatPath = Join-Path $env:LOCALAPPDATA 'KamaRooms\b24-webhook.dat'
$script:Key = ''; $script:Portal = ''; $script:UserId = ''

# Наблюдатели по умолчанию. Порядок источников — от частного к общему, побеждает первый непустой:
#   1) переменная окружения B24_DEFAULT_AUDITORS (тесты ИТ);
#   2) локальный файл машины — состав наблюдателей отеля, вне публичного репозитория;
#   3) defaults.env в пакете (по умолчанию пуст).
$LocalDefaultsPath = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'KamaRooms\b24-defaults.env' } else { '' }
$DefaultAuditors = @()
$AuditorsSource = 'не заданы'
if ($env:B24_DEFAULT_AUDITORS) {
  # Только цифры: пробелы, запятые и прочий мусор в список не попадают.
  $DefaultAuditors = @($env:B24_DEFAULT_AUDITORS -split '\s+' | Where-Object { $_ -match '^[0-9]+$' })
  if ($DefaultAuditors.Count -gt 0) { $AuditorsSource = 'переменная окружения B24_DEFAULT_AUDITORS' }
}
if ($DefaultAuditors.Count -eq 0) {
  foreach ($f in @($LocalDefaultsPath, (Join-Path $PSScriptRoot 'defaults.env'))) {
    if ($DefaultAuditors.Count -gt 0) { break }
    if (-not $f) { continue }
    if (-not (Test-Path $f)) { continue }
    # Берём ПОСЛЕДНЕЕ присваивание — так же, как b24.sh (sed | tail -n 1) и как принято в .env.
    # [string] на случай пустого файла: Get-Content -Raw возвращает $null, а Match($null) падает.
    $ms = [regex]::Matches([string](Get-Content $f -Raw -ErrorAction SilentlyContinue),
                           '(?m)^\s*(?:export\s+)?B24_DEFAULT_AUDITORS\s*=\s*"?([0-9\t ]*)"?\s*(?:#.*)?$')
    if ($ms.Count -gt 0) {
      $DefaultAuditors = @($ms[$ms.Count - 1].Groups[1].Value -split '\s+' | Where-Object { $_ -match '^[0-9]+$' })
      if ($DefaultAuditors.Count -gt 0) { $AuditorsSource = $f }
    }
  }
}

function Fail([int]$code, [string]$msg) {
  [Console]::Error.WriteLine("b24: $msg")
  exit $code
}

function Get-StorageName {
  if ($env:B24_WEBHOOK) { return 'переменная окружения B24_WEBHOOK' }
  return "файл $DatPath (DPAPI)"
}

function Read-Key {
  $k = ''
  if ($env:B24_WEBHOOK) {
    $k = $env:B24_WEBHOOK
  } else {
    if (-not (Test-Path $DatPath)) {
      Fail 3 "ключ не найден: нет файла $DatPath. Сохраните его в отдельном окне PowerShell командой из памятки ИТ"
    }
    try {
      $sec = (Get-Content $DatPath | Select-Object -First 1) | ConvertTo-SecureString
    } catch {
      Fail 3 "файл $DatPath не читается: он создан под другим пользователем Windows или повреждён"
    }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $k = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
  }
  $k = ($k -replace '\s', '').TrimEnd('/')
  if (-not $k) { Fail 3 'хранилище найдено, но ключ пустой' }
  $m = [regex]::Match($k, '^https://[^/]+/rest/(\d+)/[A-Za-z0-9]+$')
  if (-not $m.Success) { Fail 1 'ключ имеет неожиданный вид: ожидается https://<портал>/rest/<ID>/<код>/ (сам ключ не показываю)' }
  $script:Key = $k
  $script:UserId = $m.Groups[1].Value
  $script:Portal = $k.Substring(0, $k.IndexOf('/rest/'))
}

# Заменяет ключ на <ключ> во всём, что уходит на экран.
function Redact([string]$s) {
  if ($script:Key -and $s) { return $s.Replace($script:Key, '<ключ>') }
  return $s
}

# Задача без наблюдателей по умолчанию не уходит: правило отеля — руководство и офис видят
# каждую задачу, поставленную через навык. Ответственный из списка наблюдателем не дублируется.
function Test-DefaultAuditors([string]$file) {
  if ($DefaultAuditors.Count -eq 0) {
    Fail 1 ("не задан список обязательных наблюдателей, а без него правило отеля не выполняется. " +
            "Создайте файл $LocalDefaultsPath с одной строкой " +
            'B24_DEFAULT_AUDITORS="ID ID"' +
            " — состав выдаёт ИТ-отдел (it@kamarooms.org)")
  }
  $payload = (Get-Content $file -Raw -Encoding UTF8) -replace '[\r\n]', ''
  $arr = [regex]::Match($payload, '"AUDITORS"\s*:\s*\[[^\]]*\]').Value
  $resp = [regex]::Match($payload, '"RESPONSIBLE_ID"\s*:\s*"?(\d+)').Groups[1].Value
  $missing = @()
  foreach ($id in $DefaultAuditors) {
    if ($id -eq $resp) { continue }
    if ($arr -notmatch ('(\[|,|\s)"?' + [regex]::Escape($id) + '"?\s*(,|\])')) { $missing += $id }
  }
  if ($missing.Count -gt 0) {
    Fail 1 ("в задаче нет обязательных наблюдателей (AUDITORS): " + ($missing -join ' ') + ". Правило отеля: эти ID добавляются в каждую задачу — дополни поле AUDITORS и повтори (список по умолчанию: " + ($DefaultAuditors -join ' ') + ")")
  }
}

function Invoke-B24([string]$method, [string]$bodyFile) {
  if ($env:B24_ALLOW_ANY -ne '1' -and $Allowed -notcontains $method) {
    Fail 1 "метод $method не входит в разрешённый список навыка (только создание задач и чтение). Разрешены: $($Allowed -join ' ')"
  }
  if ($bodyFile -and -not (Test-Path $bodyFile)) { Fail 1 "файл с телом запроса не найден: $bodyFile" }
  if ($method -eq 'tasks.task.add' -and $bodyFile) { Test-DefaultAuditors $bodyFile }
  $url = "$($script:Key)/$method.json"
  $text = ''
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    # Родной curl.exe есть в Windows 10 1803+. stderr читаем как текст, чтобы не терять сообщение об ошибке.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      if ($bodyFile) {
        $out = & $curl.Source -sS --max-time 40 -H 'Content-Type: application/json' --data-binary "@$bodyFile" $url 2>&1
      } else {
        $out = & $curl.Source -sS --max-time 40 $url 2>&1
      }
      $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { Fail 4 ("сеть/curl (код $code): " + (Redact $text)) }
  } else {
    try {
      if ($bodyFile) {
        $bytes = [IO.File]::ReadAllBytes($bodyFile)
        $resp = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -UseBasicParsing -TimeoutSec 40
      } else {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 40
      }
      $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    } catch {
      $msg = $_.Exception.Message
      if ($_.Exception.Response) {
        try {
          $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream(), [Text.Encoding]::UTF8)
          $text = $sr.ReadToEnd()
        } catch {}
      }
      if (-not $text) { Fail 4 ('сеть: ' + (Redact $msg)) }
    }
  }
  Write-Output (Redact $text)
  if ($text -match '^\{"error"') { exit 2 }
}

switch ($Command) {
  'where' {
    Write-Output "хранилище: $(Get-StorageName)"
    Read-Key
    Write-Output "ключ найден; портал: $($script:Portal); пользователь ID: $($script:UserId)"
    $da = if ($DefaultAuditors.Count -gt 0) { $DefaultAuditors -join ' ' } else { 'не заданы' }
    Write-Output "наблюдатели по умолчанию (AUDITORS): $da"
    Write-Output "источник списка наблюдателей: $AuditorsSource"
  }
  'whoami' {
    Read-Key
    Invoke-B24 'profile' $null
    Write-Output "portal: $($script:Portal)"
    Write-Output "user_id: $($script:UserId)"
  }
  'scope' {
    Read-Key
    Invoke-B24 'scope' $null
  }
  'call' {
    if (-not $Arg1) { Fail 1 'укажите метод: call <метод> [файл.json]' }
    Read-Key
    Invoke-B24 $Arg1 $Arg2
  }
  'link' {
    if (-not $Arg1 -or $Arg1 -notmatch '^\d+$') { Fail 1 'укажите ID задачи (целое число): link <ID>' }
    Read-Key
    Write-Output "$($script:Portal)/company/personal/user/$($script:UserId)/tasks/task/view/$Arg1/"
  }
  default {
    Write-Output 'b24.ps1 — обёртка над REST API Битрикс24 для навыка bitrix24-tasks.'
    Write-Output 'Команды: where | whoami | scope | call <метод> [файл.json] | link <ID задачи>'
    Write-Output 'Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File b24.ps1 <команда> [аргументы]'
    Write-Output 'Ключ читается из %LOCALAPPDATA%\KamaRooms\b24-webhook.dat (DPAPI) и никогда не печатается.'
  }
}
