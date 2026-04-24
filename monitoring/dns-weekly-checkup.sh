#!/usr/bin/env bash
# dns-weekly-checkup.sh — Bilan hebdo monitoring DNS (AdGuard + Unbound si déployé)
# Cluster 1 Phase 1 — lancé manuellement 1x/semaine pendant 1 mois (condition Stéphane)
#
# Résume les 7 derniers jours de dns-deep-health.log :
#   - Nombre de runs, FAIL, SKIP par check
#   - Cache hit rate moyen si Unbound déployé
#   - Recursion latency avg si Unbound déployé
#   - Top FAILs
#
# Usage : ./dns-weekly-checkup.sh [--log chemin_log]
# Output : stdout + ~/logs/dns-weekly-report.log

set -uo pipefail
# Note : pas de -e pour éviter que grep -c avec 0 résultat stoppe le script

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEEP_HEALTH_LOG="${HOME}/logs/dns-deep-health.log"
WEEKLY_LOG="${HOME}/logs/dns-weekly-report.log"
DAYS=7

# Accepter un chemin de log alternatif (tests)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --log) DEEP_HEALTH_LOG="$2"; shift 2 ;;
        *) echo "Usage: $0 [--log chemin]" >&2; exit 1 ;;
    esac
done

mkdir -p "${HOME}/logs"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
CUTOFF_DATE=$(date -d "-${DAYS} days" '+%Y-%m-%d' 2>/dev/null \
    || date -v "-${DAYS}d" '+%Y-%m-%d' 2>/dev/null \
    || echo "0000-00-00")

# ---------------------------------------------------------------------------
# Fonctions
# ---------------------------------------------------------------------------

# Compte les lignes d'un string matchant un pattern
# Retourne toujours un entier sans newline parasite
count_in() {
    local haystack="$1"
    local pattern="$2"
    if [[ -z "$haystack" ]]; then
        printf '%s' "0"
        return
    fi
    local n
    n=$(echo "$haystack" | grep -c "$pattern" 2>/dev/null) || n=0
    printf '%s' "${n}"
}

# Moyenne d'un champ key=valeur dans les lignes matchées
avg_field() {
    local lines="$1"
    local key="$2"
    if [[ -z "$lines" ]]; then
        echo "N/A"
        return
    fi
    echo "$lines" | awk -v k="${key}=" '
        {
            for (i=1; i<=NF; i++) {
                if (index($i, k) == 1) {
                    val = substr($i, length(k)+1)
                    sum += val
                    cnt++
                }
            }
        }
        END {
            if (cnt > 0) {
                printf "%.3f\n", sum/cnt
            } else {
                print "N/A"
            }
        }
    '
}

# Filtre les lignes récentes (dans les DAYS derniers jours)
filter_recent() {
    local file="$1"
    awk -v cutoff="${CUTOFF_DATE}" '
        /^\[/ {
            line_date = substr($0, 2, 10)
            if (line_date >= cutoff) print
        }
    ' "${file}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Vérification du log source
# ---------------------------------------------------------------------------
REPORT=""
nl() { REPORT="${REPORT}${1}"$'\n'; }

if [[ ! -f "${DEEP_HEALTH_LOG}" ]]; then
    nl "[${TIMESTAMP}] WARN — log source absent: ${DEEP_HEALTH_LOG}"
    nl "Aucune donnée disponible. Lancer d'abord dns-deep-health.sh au moins une fois."
    printf '%s\n' "$REPORT" | tee -a "${WEEKLY_LOG}"
    exit 0
fi

RECENT=$(filter_recent "${DEEP_HEALTH_LOG}")
TOTAL_LINES=$(count_in "$RECENT" "check=")
SUMMARY_LINES=$(count_in "$RECENT" " summary ")

# ---------------------------------------------------------------------------
# En-tête rapport
# ---------------------------------------------------------------------------
nl "================================================================"
nl "BILAN DNS HEBDOMADAIRE — ${TIMESTAMP}"
nl "Periode analysee : ${DAYS} derniers jours (depuis ${CUTOFF_DATE})"
nl "Log source : ${DEEP_HEALTH_LOG}"
nl "================================================================"
nl ""

nl "## RESUME GLOBAL"
nl "Nombre de runs complets   : ${SUMMARY_LINES}"
nl "Lignes de check analysees : ${TOTAL_LINES}"
nl ""

if [[ "${TOTAL_LINES}" -eq 0 ]]; then
    nl "Aucune donnee dans la periode. Le script dns-deep-health.sh n'a peut-etre pas encore tourne."
    printf '%s\n' "$REPORT" | tee -a "${WEEKLY_LOG}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Stats par check
# ---------------------------------------------------------------------------
nl "## RESULTATS PAR CHECK"
nl ""

CHECKS=(
    "primary-adguard-internal"
    "primary-adguard-external"
    "secondary-adguard-internal"
    "secondary-adguard-external"
    "primary-unbound-loopback"
    "secondary-unbound-loopback"
    "primary-unbound-cache-hit"
    "primary-unbound-recursion-latency"
)

declare -a FAIL_SUMMARY
FAIL_SUMMARY=()

for check in "${CHECKS[@]}"; do
    check_lines=$(echo "$RECENT" | grep "check=${check} " || true)
    total_c=$(count_in "$check_lines" "check=${check}")
    ok_c=$(count_in "$check_lines" " result=OK")
    fail_c=$(count_in "$check_lines" " result=FAIL")
    skip_c=$(count_in "$check_lines" " result=SKIP")

    status_icon="  "
    [[ "${fail_c}" -gt 0 ]] && status_icon="!!"

    nl "  ${status_icon} ${check}"
    nl "      runs: ${total_c} | OK: ${ok_c} | FAIL: ${fail_c} | SKIP: ${skip_c}"

    # Latence moyenne pour les checks AdGuard
    if [[ "${check}" == *adguard* ]] && [[ -n "$check_lines" ]]; then
        avg_lat=$(avg_field "$check_lines" "latency")
        if [[ "$avg_lat" != "N/A" ]]; then
            nl "      latence avg (ms): ${avg_lat}"
        fi
    fi

    nl ""

    [[ "${fail_c}" -gt 0 ]] && FAIL_SUMMARY+=("${fail_c}x FAIL — ${check}")
done

# ---------------------------------------------------------------------------
# Stats Unbound cache hit rate (si déployé et des mesures OK existent)
# ---------------------------------------------------------------------------
unbound_cache_lines=$(echo "$RECENT" | grep "check=primary-unbound-cache-hit result=OK" || true)
unbound_cache_count=$(count_in "$unbound_cache_lines" "ratio=")

if [[ "${unbound_cache_count}" -gt 0 ]]; then
    nl "## UNBOUND — CACHE HIT RATE"
    avg_ratio=$(avg_field "$unbound_cache_lines" "ratio")
    nl "  Ratio moyen (${unbound_cache_count} mesures) : ${avg_ratio}"
    nl ""
fi

# ---------------------------------------------------------------------------
# Stats Unbound recursion latency (si déployé)
# ---------------------------------------------------------------------------
unbound_rec_lines=$(echo "$RECENT" | grep "check=primary-unbound-recursion-latency result=OK" || true)
unbound_rec_count=$(count_in "$unbound_rec_lines" "avg_ms=")

if [[ "${unbound_rec_count}" -gt 0 ]]; then
    nl "## UNBOUND — RECURSION LATENCY"
    avg_rec=$(avg_field "$unbound_rec_lines" "avg_ms")
    nl "  Latence recursion avg (${unbound_rec_count} mesures) : ${avg_rec}ms"
    nl ""
fi

# ---------------------------------------------------------------------------
# Top FAILs
# ---------------------------------------------------------------------------
if [[ ${#FAIL_SUMMARY[@]} -gt 0 ]]; then
    nl "## CHECKS EN ECHEC (a investiguer)"
    for f in "${FAIL_SUMMARY[@]}"; do
        nl "  - ${f}"
    done
    nl ""
    nl "Detail — derniers FAIL :"
    nl "  grep 'result=FAIL' ${DEEP_HEALTH_LOG} | tail -20"
else
    nl "## AUCUN ECHEC SUR LA PERIODE — DNS stable"
fi

nl ""
nl "================================================================"
nl "Rapport genere par dns-weekly-checkup.sh"
nl "Prochaine observation manuelle recommandee dans 7 jours."
nl "================================================================"

# ---------------------------------------------------------------------------
# Sortie
# ---------------------------------------------------------------------------
printf '%s\n' "$REPORT" | tee -a "${WEEKLY_LOG}"
