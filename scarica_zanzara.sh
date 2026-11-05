#!/usr/bin/env bash
# Scarica gli MP3 de "La Zanzara" dal giorno successivo all'ultimo già presente
# (o da START_DATE se non ne trova), usando prima il feed RSS ufficiale.
# Salta sabati,domeniche e festività mobili (es. Pasquetta) se non usa il feed RSS.
# Requisiti: bash + awk + GNU date + wget

set -euo pipefail

# === Configurazione ===
BASE_URL="https://podcast-radio24.ilsole24ore.com/radio24_audio"
FEED_URL="https://www.radio24.ilsole24ore.com/podcast/lazanzara.xml"
SHOW_SLUG="lazanzara"
#START_DATE="2016-01-05" # Data originale di inizio dei podcast sul sito di radio24
START_DATE="2026-01-01" # Data iniziale usata se non trova episodi già scaricati
OUT_DIR="/mnt/user/Multimedia/Podcasts/La Zanzara" # Impostare path corretto
WAIT_SECONDS=1
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari"

# === Modalità di esecuzione ===
DRY_RUN=0   # 1 = non scarica episodi/non cancella/non sposta, mostra cosa farebbe
DEBUG=0     # 1 = output più verboso + trace
REPAIR_GAPS=0 # 1 = cerca anche le puntate mancanti prima dell'ultima presente

checked_count=0
downloaded_count=0
existing_count=0
missing_count=0
failed_count=0
planned_count=0
progress_active=0

usage() {
  cat <<'EOF'
Uso: scarica_zanzara.sh [--dry-run|-n] [--debug|-d] [--repair-gaps]
  --dry-run, -n   Simula le azioni sui file; scarica comunque il feed RSS
  --debug,   -d   Modalità verbosa (bash trace + wget non silenzioso)
  --repair-gaps   Cerca anche puntate mancanti tra START_DATE e l'ultima presente
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
  prefix="[RUN] $checked_count chk D:$downloaded_count OK:$existing_count M:$missing_count E:$failed_count P:$planned_count | "
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

log_info "Avvio: verifica requisiti"

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

# Festività a data mobile (Italia): al momento gestiamo Pasquetta (Lunedì dell'Angelo)
# Nota: Pasqua cade sempre di domenica, quindi è già saltata dal check weekend.
# Se vuoi aggiungere altre date mobili, vedi la funzione `is_movable_holiday`.

# Il loop delle date è cronologico: una cache scalare evita array associativi,
# non disponibili nella versione di Bash inclusa in macOS.
EASTER_CACHE_YEAR=""
EASTER_CACHE=""
EASTER_MONDAY_CACHE=""

# Calcola la data di Pasqua (calendario gregoriano) nel formato YYYY-MM-DD
# Algoritmo: Anonymous Gregorian algorithm
calc_easter() {
  local y=$1
  local a=$(( y % 19 ))
  local b=$(( y / 100 ))
  local c=$(( y % 100 ))
  local d=$(( b / 4 ))
  local e=$(( b % 4 ))
  local f=$(( (b + 8) / 25 ))
  local g=$(( (b - f + 1) / 3 ))
  local h=$(( (19*a + b - d - g + 15) % 30 ))
  local i=$(( c / 4 ))
  local k=$(( c % 4 ))
  local l=$(( (32 + 2*e + 2*i - h - k) % 7 ))
  local m=$(( (a + 11*h + 22*l) / 451 ))
  local month=$(( (h + l - 7*m + 114) / 31 ))
  local day=$(( ((h + l - 7*m + 114) % 31) + 1 ))
  printf "%04d-%02d-%02d" "$y" "$month" "$day"
}

# Ritorna 0 (true) se la data YYYY-MM-DD è una festività mobile da saltare
is_movable_holiday() {
  local yyyymmdd=$1
  local yyyy=${yyyymmdd:0:4}

  # Pasqua (domenica) è già coperta dal weekend, ma calcoliamola per Pasquetta
  if [[ "$EASTER_CACHE_YEAR" != "$yyyy" ]]; then
    EASTER_CACHE_YEAR="$yyyy"
    EASTER_CACHE="$(calc_easter "$yyyy")"
    EASTER_MONDAY_CACHE="$("$DATE_CMD" -d "$EASTER_CACHE +1 day" +%F)"
  fi

  # Pasquetta (Lunedì dell'Angelo)
  if [[ "$yyyymmdd" == "$EASTER_MONDAY_CACHE" ]]; then
    return 0
  fi

  return 1
}

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

# --- Weekend o festivo? ---
is_skip_day() {
  local dow=$1
  local yyyymmdd=$2

  # Weekend (GNU date: 1=lun ... 7=dom)
  if (( dow >= 6 )); then
    return 0
  fi

  # Festivi a data fissa (formato: MM-DD)
  # 01-01 Capodanno
  # 01-06 Epifania
  # 04-25 Festa della Liberazione
  # 05-01 Festa dei Lavoratori
  # 06-02 Festa della Repubblica
  # 08-15 Ferragosto
  # 11-01 Ognissanti
  # 12-08 Immacolata Concezione
  # 12-25 Natale
  # 12-26 Santo Stefano
  local md="${yyyymmdd:5:2}-${yyyymmdd:8:2}"

  case "$md" in
    01-01|01-06|04-25|05-01|06-02|08-15|11-01|12-08|12-25|12-26)
      return 0
      ;;
  esac

  # Festività a data mobile (es. Pasquetta)
  if is_movable_holiday "$yyyymmdd"; then
    return 0
  fi

  return 1
}

# Riprende dal giorno successivo all'ultimo episodio scaricato; se non ne trova,
# usa START_DATE come data iniziale.
last_downloaded_date=""
log_info "Scansione episodi locali..."
if [[ -d "$OUT_DIR" ]]; then
  while IFS= read -r -d '' downloaded_file; do
    [[ -s "$downloaded_file" ]] || continue
    file_name="${downloaded_file##*/}"
    downloaded_date="${file_name#La Zanzara - }"
    downloaded_date="${downloaded_date%.mp3}"

    if [[ "$downloaded_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
      && [[ "$("$DATE_CMD" -d "$downloaded_date" +%F 2>/dev/null || true)" == "$downloaded_date" ]] \
      && [[ -z "$last_downloaded_date" || "$downloaded_date" > "$last_downloaded_date" ]]; then
      last_downloaded_date="$downloaded_date"
    fi
  done < <(find "$OUT_DIR" -type f -name 'La Zanzara - ????-??-??.mp3' -print0)
fi

SCAN_START_DATE="$START_DATE"
if [[ -n "$last_downloaded_date" ]]; then
  resume_date="$("$DATE_CMD" -d "$last_downloaded_date +1 day" +%F)"
  if [[ "$REPAIR_GAPS" -eq 1 && "$START_DATE" < "$last_downloaded_date" ]]; then
    log_info "Ultimo $last_downloaded_date; controllo lacune da $START_DATE"
  else
    SCAN_START_DATE="$resume_date"
    log_info "Ultimo $last_downloaded_date; ripartenza da $SCAN_START_DATE"
  fi
else
  log_info "Nessun episodio presente; inizio da $START_DATE"
fi

# Riprende dal feed RSS per le puntate recenti; prima del limite dell'indice
# mantiene la ricerca giornaliera, così non si perdono puntate più vecchie.
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
      missing_count=$((missing_count + 1))
      log_progress "assente $yyyymmdd"
    else
      failed_count=$((failed_count + 1))
      log_error "Errore ($exit_code) su La Zanzara - ${yyyymmdd}.mp3 — continuo."
    fi
  elif [ ! -s "$tmp_path" ]; then
    run_cmd rm -f "$tmp_path"
    missing_count=$((missing_count + 1))
    log_progress "assente $yyyymmdd"
  else
    run_cmd mv -f "$tmp_path" "$file_path"
    downloaded_count=$((downloaded_count + 1))
    log_ok "OK: La Zanzara - ${yyyymmdd}.mp3"
  fi
}

feed_tmp="$(mktemp)"
index_raw="$(mktemp)"
index_tsv="$(mktemp)"
index_sorted="$(mktemp)"
trap 'rm -f "$feed_tmp" "$index_raw" "$index_tsv" "$index_sorted"' EXIT

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

oldest_index_date="$(head -n 1 "$index_sorted" | cut -f 1)"
today="$("$DATE_CMD" +%F)"
log_info "RSS dal $oldest_index_date; controllo da $SCAN_START_DATE"

if [[ "$REPAIR_GAPS" -eq 1 && -n "$last_downloaded_date" \
  && "$SCAN_START_DATE" < "$last_downloaded_date" ]]; then
  repair_date="$SCAN_START_DATE"
  while [[ "$repair_date" < "$last_downloaded_date" || "$repair_date" == "$last_downloaded_date" ]]; do
    indexed_url="$(awk -F '\t' -v target="$repair_date" '$1 == target { print $2; exit }' "$index_sorted")"
    if [[ -n "$indexed_url" ]]; then
      download_episode "$repair_date" "$indexed_url"
    else
      repair_dow="$("$DATE_CMD" -d "$repair_date" +%u)"
      if is_skip_day "$repair_dow" "$repair_date"; then
        checked_count=$((checked_count + 1))
        log_info "Salto (no programma): $repair_date"
      else
        repair_year="${repair_date:0:4}"
        repair_yymmdd="$("$DATE_CMD" -d "$repair_date" +%y%m%d)"
        repair_url="${BASE_URL}/${repair_year}/${repair_yymmdd}-${SHOW_SLUG}.mp3"
        download_episode "$repair_date" "$repair_url"
      fi
    fi
    repair_date="$("$DATE_CMD" -d "$repair_date +1 day" +%F)"
  done
fi

fallback_start_date="$SCAN_START_DATE"
if [[ "$REPAIR_GAPS" -eq 1 && -n "$last_downloaded_date" \
  && "$SCAN_START_DATE" < "$last_downloaded_date" ]]; then
  fallback_start_date="$resume_date"
fi

if [[ "$fallback_start_date" < "$oldest_index_date" ]]; then
  fallback_end="$("$DATE_CMD" -d "$oldest_index_date -1 day" +%F)"
  fallback_date="$fallback_start_date"

  while [[ "$fallback_date" < "$fallback_end" || "$fallback_date" == "$fallback_end" ]]; do
    yyyy="${fallback_date:0:4}"
    yymmdd="$("$DATE_CMD" -d "$fallback_date" +%y%m%d)"
    yyyymmdd="$fallback_date"
    dow="$("$DATE_CMD" -d "$fallback_date" +%u)"  # 1..7 (lun..dom)

    if is_skip_day "$dow" "$yyyymmdd"; then
      checked_count=$((checked_count + 1))
      log_info "Salto (no programma): $yyyymmdd"
    else
      url="${BASE_URL}/${yyyy}/${yymmdd}-${SHOW_SLUG}.mp3"
      download_episode "$yyyymmdd" "$url"
    fi
    fallback_date="$("$DATE_CMD" -d "$fallback_date +1 day" +%F)"
  done
fi

while IFS=$'\t' read -r yyyymmdd url; do
  if [[ "$yyyymmdd" < "$SCAN_START_DATE" || "$yyyymmdd" > "$today" ]]; then
    continue
  fi
  if [[ "$REPAIR_GAPS" -eq 1 && -n "$last_downloaded_date" \
    && "$SCAN_START_DATE" < "$last_downloaded_date" \
    && ( "$yyyymmdd" < "$last_downloaded_date" || "$yyyymmdd" == "$last_downloaded_date" ) ]]; then
    continue
  fi
  download_episode "$yyyymmdd" "$url"
done < "$index_sorted"

summary="Riepilogo: controllate=$checked_count, scaricate=$downloaded_count, presenti=$existing_count, assenti=$missing_count, errori=$failed_count, da_scaricare=$planned_count"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log_summary "$summary. Simulazione completata (il feed RSS è stato scaricato)."
elif [[ "$failed_count" -gt 0 ]]; then
  log_summary "$summary."
  log_error "Completato con $failed_count errore/i di download."
  exit 1
else
  log_summary "$summary. Fatto."
fi
