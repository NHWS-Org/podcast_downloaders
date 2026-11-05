#!/usr/bin/env bash
# Scarica gli MP3 de "La Zanzara" dal giorno successivo all'ultimo già presente
# (o da START_DATE se non ne trova), usando prima il feed RSS ufficiale.
# Mantiene un archivio delle puntate note per evitare tentativi storici ripetuti.
# Requisiti: bash + awk + GNU date + wget

set -euo pipefail

# === Configurazione ===
BASE_URL="https://podcast-radio24.ilsole24ore.com/radio24_audio"
FEED_URL="https://www.radio24.ilsole24ore.com/podcast/lazanzara.xml"
SHOW_SLUG="lazanzara"
#START_DATE="2016-01-05" # Data originale di inizio dei podcast sul sito di radio24
START_DATE="2026-01-01" # Data iniziale usata se non trova episodi già scaricati
OUT_DIR="/mnt/user/Multimedia/Podcasts/La Zanzara" # Impostare path corretto
HISTORY_FILE="${OUT_DIR}/zanzara_feed_history.tsv"
WAIT_SECONDS=1
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari"

# === Modalità di esecuzione ===
DRY_RUN=0   # 1 = non scarica episodi/non cancella/non sposta, mostra cosa farebbe
DEBUG=0     # 1 = output più verboso + trace
REPAIR_GAPS=0 # 1 = cerca anche le puntate mancanti prima dell'ultima presente

checked_count=0
downloaded_count=0
existing_count=0
unavailable_count=0
failed_count=0
planned_count=0
progress_active=0
active_year=""

usage() {
  cat <<'EOF'
Uso: scarica_zanzara.sh [--dry-run|-n] [--debug|-d] [--repair-gaps]
  --dry-run, -n   Simula le azioni sui file; scarica comunque il feed RSS
  --debug,   -d   Modalità verbosa (bash trace + wget non silenzioso)
  --repair-gaps   Ricontrolla tutte le date da START_DATE a oggi, anno per anno
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -d|--debug)
      DEBUG=1
      shift
      ;;
    --repair-gaps)
      REPAIR_GAPS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Argomento non riconosciuto: $1" >&2
      usage
      exit 2
      ;;
  esac
done

printf '[INFO ] Avvio: verifica requisiti e ricerca episodi locali...\n'

# === Colori log ===
if [[ -t 1 && -t 2 ]]; then
  CLR_RESET=$'\033[0m'
  CLR_RED=$'\033[31m'
  CLR_GREEN=$'\033[32m'
  CLR_YELLOW=$'\033[33m'
  CLR_BLUE=$'\033[36m'
  CLR_PURPLE=$'\033[35m'
else
  CLR_RESET=""
  CLR_RED=""
  CLR_GREEN=""
  CLR_YELLOW=""
  CLR_BLUE=""
  CLR_PURPLE=""
fi

log_line() {
  local level=$1
  local color=$2
  local message=$3
  local timestamp
  timestamp="$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S%z')"
  if [[ "$level" == "WARN" || "$level" == "ERR" ]]; then
    printf '%b[%-5s]%b %s %s\n' "$color" "$level" "$CLR_RESET" "$timestamp" "$message" >&2
  else
    printf '%b[%-5s]%b %s %s\n' "$color" "$level" "$CLR_RESET" "$timestamp" "$message"
  fi
}

finish_progress() {
  if [[ "$progress_active" -eq 1 ]]; then
    printf '\n'
    progress_active=0
  fi
}

log_progress() {
  [[ -t 1 ]] || return 0

  local message=$1
  local columns=""
  local max_width
  local prefix
  local progress

  if command -v tput >/dev/null 2>&1; then
    columns="$(tput cols 2>/dev/null || true)"
  fi
  if [[ ! "$columns" =~ ^[0-9]+$ ]] || [[ "$columns" -le 0 ]]; then
    if [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]] && [[ "$COLUMNS" -gt 0 ]]; then
      columns=$COLUMNS
    else
      columns=80
    fi
  fi

  max_width=$((columns - 1))
  (( max_width > 0 )) || max_width=1
  prefix="[RUN${active_year:+ $active_year}] $checked_count chk D:$downloaded_count OK:$existing_count ND:$unavailable_count E:$failed_count P:$planned_count | "
  if (( ${#prefix} >= max_width )); then
    progress="${prefix:0:max_width}"
  else
    progress="$prefix${message:0:max_width-${#prefix}}"
  fi

  printf '\r\033[K%s' "$progress"
  progress_active=1
}

log_info()   { log_progress "$*"; }
log_ok()     { log_progress "$*"; }
log_warn()  { finish_progress; log_line WARN "$CLR_YELLOW" "$*"; }
log_error() { finish_progress; log_line ERR "$CLR_RED" "$*"; }
log_summary() { finish_progress; log_line INFO "$CLR_BLUE" "$*"; }

run_cmd() {
  # Wrapper per supportare dry-run
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local exit_code=0
  "$@" || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    log_error "Comando fallito ($exit_code): $*"
    return "$exit_code"
  fi
}

# Trace bash in debug
if [[ "$DEBUG" -eq 1 ]]; then
  set -x
fi

# Usa GNU date sia come `date` sia come `gdate` (tipico su macOS con coreutils).
DATE_CMD=""
for date_candidate in date gdate; do
  if command -v "$date_candidate" >/dev/null 2>&1; then
    date_probe="$("$date_candidate" -d "2000-01-01" +%F 2>/dev/null || true)"
    if [[ "$date_probe" == "2000-01-01" ]]; then
      DATE_CMD="$(command -v "$date_candidate")"
      break
    fi
  fi
done
if [[ -z "$DATE_CMD" ]]; then
  echo "Errore: GNU date non trovato (su macOS installare coreutils)." >&2
  exit 1
fi

# In debug non usiamo --quiet per vedere eventuali errori HTTP
WGET_QUIET_OPT="--quiet"
if [[ "$DEBUG" -eq 1 ]]; then
  WGET_QUIET_OPT=""
fi

# === Controlli preliminari ===
command -v wget >/dev/null || { log_error "wget non trovato."; exit 1; }
if ! normalized_start_date="$("$DATE_CMD" -d "$START_DATE" +%F 2>/dev/null)" \
  || [[ "$normalized_start_date" != "$START_DATE" ]]; then
  log_error "START_DATE non valida (formato richiesto YYYY-MM-DD): $START_DATE"
  exit 2
fi
run_cmd mkdir -p "$OUT_DIR"
if [[ "$DRY_RUN" -eq 0 && ! -w "$OUT_DIR" ]]; then
  log_error "La directory di destinazione non è scrivibile: $OUT_DIR"
  exit 1
fi

feed_tmp="$(mktemp)"
index_raw="$(mktemp)"
index_tsv="$(mktemp)"
index_sorted="$(mktemp)"
local_episodes="$(mktemp)"
old_history="$(mktemp)"
history_sorted="$(mktemp)"
history_updates="$(mktemp)"
history_merged="$(mktemp)"
history_stage=""
trap 'rm -f "$feed_tmp" "$index_raw" "$index_tsv" "$index_sorted" "$local_episodes" "$old_history" "$history_sorted" "$history_updates" "$history_merged"; [[ -z "$history_stage" ]] || rm -f "$history_stage"' EXIT

# Registra le puntate presenti nei file locali e trova la data dell'ultima.
scan_local_directory() {
  local directory=$1
  local downloaded_file file_name downloaded_date year yymmdd
  [[ -d "$directory" ]] || return 0
  for downloaded_file in "$directory"/La\ Zanzara\ -\ ????-??-??.mp3; do
    [[ -f "$downloaded_file" && -s "$downloaded_file" ]] || continue
    file_name="${downloaded_file##*/}"
    downloaded_date="${file_name#La Zanzara - }"
    downloaded_date="${downloaded_date%.mp3}"

    if [[ "$downloaded_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
      && [[ "$("$DATE_CMD" -d "$downloaded_date" +%F 2>/dev/null || true)" == "$downloaded_date" ]]; then
      year="${downloaded_date:0:4}"
      yymmdd="${downloaded_date:2:2}${downloaded_date:5:2}${downloaded_date:8:2}"
      printf '%s\t%s/%s/%s-%s.mp3\t1\n' \
        "$downloaded_date" "$BASE_URL" "$year" "$yymmdd" "$SHOW_SLUG" >> "$local_episodes"
      if [[ -z "$last_downloaded_date" || "$downloaded_date" > "$last_downloaded_date" ]]; then
        last_downloaded_date="$downloaded_date"
      fi
    fi
  done
}

last_downloaded_date=""
SCAN_START_DATE="$START_DATE"
log_info "Scansione episodi locali..."
scan_local_directory "$OUT_DIR"
if [[ -d "$OUT_DIR" ]]; then
  for year_directory in "$OUT_DIR"/[0-9][0-9][0-9][0-9]; do
    [[ -d "$year_directory" ]] || continue
    directory_year="${year_directory##*/}"
    [[ "$directory_year" =~ ^[0-9]{4}$ ]] || continue
    if [[ "$REPAIR_GAPS" -eq 0 ]]; then
      log_info "Ricerca ultimo episodio: $directory_year"
    fi
    scan_local_directory "$year_directory"
  done
fi

if [[ "$REPAIR_GAPS" -eq 0 ]]; then
  if [[ -n "$last_downloaded_date" ]]; then
    SCAN_START_DATE="$("$DATE_CMD" -d "$last_downloaded_date +1 day" +%F)"
    log_info "Ultimo $last_downloaded_date; ripartenza da $SCAN_START_DATE"
  else
    log_info "Nessun episodio presente; inizio da $START_DATE"
  fi
fi

# Scarica episodi noti dal feed corrente o dall'archivio storico.
download_episode() {
  local yyyymmdd=$1
  local url=$2
  local yyyy="${yyyymmdd:0:4}"
  local year_dir="${OUT_DIR}/${yyyy}"
  local file_path="${year_dir}/La Zanzara - ${yyyymmdd}.mp3"
  local tmp_path="${file_path}.tmp"
  local exit_code=0

  checked_count=$((checked_count + 1))
  log_progress "Controllo puntata $yyyymmdd"
  run_cmd mkdir -p "$year_dir"

  if [ -f "$file_path" ] && [ ! -s "$file_path" ]; then
    log_warn "Presente ma vuoto (0 byte): La Zanzara - ${yyyymmdd}.mp3 — riscarico."
    run_cmd rm -f "$file_path"
  fi

  if [ -s "$file_path" ]; then
    existing_count=$((existing_count + 1))
    log_progress "Gia presente $yyyymmdd"
    return
  fi

  log_info "Download $yyyymmdd"
  run_cmd rm -f "$tmp_path"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    planned_count=$((planned_count + 1))
    log_progress "dry-run $yyyymmdd"
    return
  fi

  # shellcheck disable=SC2086
  wget \
    ${WGET_QUIET_OPT} \
    --tries=3 \
    --timeout=30 \
    --wait="$WAIT_SECONDS" \
    --random-wait \
    --user-agent="$USER_AGENT" \
    --output-document="$tmp_path" \
    "$url" || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    run_cmd rm -f "$tmp_path"
    if [ "$exit_code" -eq 8 ]; then
      unavailable_count=$((unavailable_count + 1))
      log_progress "non disponibile $yyyymmdd"
    else
      failed_count=$((failed_count + 1))
      log_error "Errore ($exit_code) su La Zanzara - ${yyyymmdd}.mp3 — continuo."
    fi
  elif [ ! -s "$tmp_path" ]; then
    run_cmd rm -f "$tmp_path"
    unavailable_count=$((unavailable_count + 1))
    log_progress "non disponibile $yyyymmdd"
  else
    run_cmd mv -f "$tmp_path" "$file_path"
    downloaded_count=$((downloaded_count + 1))
    if ! printf '%s\t%s\t1\n' "$yyyymmdd" "$url" >> "$history_updates"; then
      log_error "Impossibile registrare La Zanzara - ${yyyymmdd}.mp3 nell'archivio temporaneo."
      exit 1
    fi
    log_ok "OK: La Zanzara - ${yyyymmdd}.mp3"
  fi
}

log_info "Scarico indice RSS"
# shellcheck disable=SC2086
if ! wget \
  ${WGET_QUIET_OPT} \
  --tries=3 \
  --timeout=30 \
  --user-agent="$USER_AGENT" \
  --output-document="$feed_tmp" \
  "$FEED_URL"; then
  log_error "Impossibile scaricare l'indice RSS."
  exit 1
fi

if ! awk '
  {
    xml = xml $0 "\n"
  }
  END {
    if (xml !~ /<rss([[:space:]>])/ || xml !~ /<\/rss[[:space:]]*>/) {
      exit 1
    }

    while (match(xml, /<item([[:space:]][^>]*)?>/)) {
      item_count++
      xml = substr(xml, RSTART + RLENGTH)
      if (!match(xml, /<\/item[[:space:]]*>/)) {
        exit 1
      }

      item = substr(xml, 1, RSTART - 1)
      xml = substr(xml, RSTART + RLENGTH)

      if (!match(item, /<pubDate[[:space:]]*>/)) {
        exit 1
      }
      item = substr(item, RSTART + RLENGTH)
      if (!match(item, /<\/pubDate[[:space:]]*>/)) {
        exit 1
      }
      pub_date = substr(item, 1, RSTART - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", pub_date)
      if (pub_date == "") {
        exit 1
      }

      if (!match(item, /<enclosure[[:space:]][^>]*>/)) {
        exit 1
      }
      enclosure = substr(item, RSTART, RLENGTH)
      if (match(enclosure, /[[:space:]]url[[:space:]]*=[[:space:]]*"/)) {
        enclosure = substr(enclosure, RSTART + RLENGTH)
        if (!match(enclosure, /"/)) {
          exit 1
        }
      } else if (match(enclosure, /[[:space:]]url[[:space:]]*=[[:space:]]*\047/)) {
        enclosure = substr(enclosure, RSTART + RLENGTH)
        if (!match(enclosure, /\047/)) {
          exit 1
        }
      } else {
        exit 1
      }
      media_url = substr(enclosure, 1, RSTART - 1)
      if (media_url == "" || media_url ~ /[[:space:]]/) {
        exit 1
      }

      print pub_date "\t" media_url
      parsed_count++
    }

    if (item_count == 0 || parsed_count != item_count) {
      exit 1
    }
  }
' "$feed_tmp" > "$index_raw"
then
  log_error "Impossibile leggere un feed RSS completo e valido con awk."
  exit 1
fi

while IFS=$'\t' read -r published_at media_url; do
  if ! published_date="$("$DATE_CMD" -d "$published_at" +%F 2>/dev/null)"; then
    log_error "Data non valida nell'indice RSS: $published_at"
    exit 1
  fi

  media_url="${media_url//&amp;/&}"
  if [[ "$media_url" != https://podcast-radio24.ilsole24ore.com/radio24_audio/* ]]; then
    log_error "URL MP3 non valido nell'indice RSS: $media_url"
    exit 1
  fi
  printf '%s\t%s\n' "$published_date" "$media_url" >> "$index_tsv"
done < "$index_raw"

if ! sort -t $'\t' -k1,1 "$index_tsv" > "$index_sorted"; then
  log_error "Impossibile ordinare le puntate dell'indice RSS."
  exit 1
fi

if [[ -f "$HISTORY_FILE" ]]; then
  if ! awk -F '\t' '
    NF != 3 || $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ \
      || $2 !~ /^https:\/\/podcast-radio24\.ilsole24ore\.com\/radio24_audio\// \
      || $3 !~ /^[01]$/ { exit 1 }
  ' "$HISTORY_FILE"; then
    log_error "Archivio storico non valido: $HISTORY_FILE"
    exit 1
  fi
  while IFS=$'\t' read -r history_date history_url history_downloaded; do
    if ! normalized_history_date="$("$DATE_CMD" -d "$history_date" +%F 2>/dev/null)" \
      || [[ "$normalized_history_date" != "$history_date" ]]; then
      log_error "Data non valida nell'archivio storico: $history_date"
      exit 1
    fi
  done < "$HISTORY_FILE"
  if ! cp "$HISTORY_FILE" "$old_history"; then
    log_error "Impossibile leggere l'archivio storico: $HISTORY_FILE"
    exit 1
  fi
fi

if ! awk -F '\t' '
  FILENAME == ARGV[1] {
    if ($3 == "1") {
      old_url[$1] = $2
      downloaded[$1] = 1
    }
    next
  }
  FILENAME == ARGV[2] {
    local_url[$1] = $2
    downloaded[$1] = 1
    next
  }
  FILENAME == ARGV[3] {
    current_url[$1] = $2
    next
  }
  END {
    for (date in current_url) {
      status = (date in downloaded) ? 1 : 0
      print date "\t" current_url[date] "\t" status
    }
    for (date in downloaded) {
      if (!(date in current_url)) {
        url = (date in local_url) ? local_url[date] : old_url[date]
        print date "\t" url "\t1"
      }
    }
  }
' "$old_history" "$local_episodes" "$index_sorted" | sort -t $'\t' -k1,1 > "$history_sorted"; then
  log_error "Impossibile aggiornare l'archivio storico."
  exit 1
fi

persist_history() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  history_stage="$(mktemp "${OUT_DIR}/.zanzara-history.XXXXXX")"
  if ! cp "$history_sorted" "$history_stage"; then
    log_error "Impossibile preparare l'archivio storico: $HISTORY_FILE"
    return 1
  fi
  if ! mv -f "$history_stage" "$HISTORY_FILE"; then
    log_error "Impossibile salvare l'archivio storico: $HISTORY_FILE"
    return 1
  fi
  history_stage=""
}

if ! persist_history; then
  exit 1
fi

oldest_index_date="$(head -n 1 "$index_sorted" | cut -f 1)"
today="$("$DATE_CMD" +%F)"
log_info "RSS dal $oldest_index_date; controllo da $SCAN_START_DATE"

total_checked=0
total_downloaded=0
total_existing=0
total_unavailable=0
total_failed=0
total_planned=0

year_cursor="${SCAN_START_DATE:0:4}"
last_scan_year="${today:0:4}"
while [[ "$year_cursor" -le "$last_scan_year" ]]; do
  active_year="$year_cursor"
  checked_count=0
  downloaded_count=0
  existing_count=0
  unavailable_count=0
  failed_count=0
  planned_count=0

  log_progress "Scansione cartella $active_year..."

  while IFS=$'\t' read -r episode_date episode_url episode_downloaded; do
    [[ "${episode_date:0:4}" == "$active_year" ]] || continue
    [[ "$episode_date" < "$SCAN_START_DATE" ]] && continue
    [[ "$episode_date" > "$today" ]] && continue
    download_episode "$episode_date" "$episode_url"
  done < "$history_sorted"

  log_summary "Anno $active_year: controllate=$checked_count, scaricate=$downloaded_count, presenti=$existing_count, non_disponibili=$unavailable_count, errori=$failed_count, da_scaricare=$planned_count."
  total_checked=$((total_checked + checked_count))
  total_downloaded=$((total_downloaded + downloaded_count))
  total_existing=$((total_existing + existing_count))
  total_unavailable=$((total_unavailable + unavailable_count))
  total_failed=$((total_failed + failed_count))
  total_planned=$((total_planned + planned_count))

  if [[ "$year_cursor" == "$last_scan_year" ]]; then
    break
  fi
  year_cursor="$("$DATE_CMD" -d "$active_year-12-31 +1 day" +%Y)"
done

if [[ -s "$history_updates" ]]; then
  if ! awk -F '\t' '
    FILENAME == ARGV[1] {
      urls[$1] = $2
      status[$1] = $3
      next
    }
    FILENAME == ARGV[2] {
      urls[$1] = $2
      status[$1] = "1"
      next
    }
    END {
      for (date in urls) {
        print date "\t" urls[date] "\t" status[date]
      }
    }
  ' "$history_sorted" "$history_updates" | sort -t $'\t' -k1,1 > "$history_merged"; then
    log_error "Impossibile aggiornare le puntate scaricate nell'archivio storico."
    exit 1
  fi
  mv -f "$history_merged" "$history_sorted"
  if ! persist_history; then
    exit 1
  fi
fi

active_year=""
summary="Riepilogo totale: controllate=$total_checked, scaricate=$total_downloaded, presenti=$total_existing, non_disponibili=$total_unavailable, errori=$total_failed, da_scaricare=$total_planned"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log_summary "$summary. Simulazione completata (il feed RSS è stato scaricato)."
elif [[ "$total_failed" -gt 0 ]]; then
  log_summary "$summary."
  log_error "Completato con $total_failed errore/i di download."
  exit 1
else
  log_summary "$summary. Fatto."
fi
