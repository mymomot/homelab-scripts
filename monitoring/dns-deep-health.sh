#!/usr/bin/env bash
# dns-deep-health.sh — Monitoring DNS approfondi (AdGuard + Unbound futur)
# Cluster 1 Phase 1 — préalable au déploiement Unbound (condition C6 council Art.15 bis)
#
# Checks (7 au total) :
#   1. Primary AdGuard :53 — résolution interne .lab
#   2. Primary AdGuard :53 — résolution externe (retry 10s pour warmup D5)
#   3. Secondary AdGuard llmcore :53 — résolution interne + externe
#   4. Primary Unbound :5335 loopback sur LXC 411 (SKIP si non déployé)
#   5. Secondary Unbound :5335 loopback sur llmcore (SKIP si non déployé)
#   6. Primary Unbound cache hit rate (SKIP si non déployé ou < 100 requêtes)
#   7. Primary Unbound recursion latency (SKIP si non déployé)
#
# Sortie : stdout structuré + ~/logs/dns-deep-health.log
# Exit   : 0 si tout OK ou SKIP, 1 si au moins un FAIL
# Alerte : Telegram uniquement sur FAIL, cap MAX_ALERTS_PER_DAY=3
#
# Idempotent — peut être lancé à tout moment sans side-effects.
# SKIP = Unbound absent (normal pendant phase déploiement).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LOG_FILE="${HOME}/logs/dns-deep-health.log"
ALERT_SCRIPT="${HOME}/.hubmq-agent/wrapper/send-telegram.sh"
TELEGRAM_CHAT_ID="1451527482"

PRIMARY_AG="192.168.10.11"
SECONDARY_AG="192.168.10.118"
INTERNAL_HOST="forgejo.lab.mymomot.ovh"
INTERNAL_PATTERN="^192\.168\.10\."
EXTERNAL_HOST="debian.org"

SSH_PRIMARY="motreffs@${PRIMARY_AG}"
SSH_SECONDARY="llmuser@${SECONDARY_AG}"

MAX_ALERTS_PER_DAY=3
ALERT_STATE_FILE="${HOME}/.cache/dns-health-alert-count"

# Seuils Unbound
CACHE_HIT_MIN_RATIO="0.60"   # alerte si < 60%
CACHE_MIN_QUERIES=100         # pas d'alerte avant 100 requêtes (cold start)
RECURSION_LATENCY_MAX_MS=500  # alerte si > 500ms

# ---------------------------------------------------------------------------
# Init
# ---------------------------------------------------------------------------
mkdir -p "${HOME}/logs"
mkdir -p "${HOME}/.cache"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
TOTAL=0
OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAIL_MESSAGES=()

# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------

# Mesure la latence d'une commande dig en ms
# Usage : measure_latency <result> → écrit dans LAST_LATENCY_MS
measure_latency() {
    local start_ns
    local end_ns
    start_ns=$(date +%s%N)
    eval "$1" > /dev/null 2>&1
    end_ns=$(date +%s%N)
    LAST_LATENCY_MS=$(( (end_ns - start_ns) / 1000000 ))
}

# Émet une ligne de log structurée
# Usage : log_check <check_name> <result> [key=val ...]
log_check() {
    local check="$1"
    local result="$2"
    shift 2
    local extras="${*}"
    local line="[${TIMESTAMP}] check=${check} result=${result}"
    [[ -n "$extras" ]] && line="${line} ${extras}"
    echo "$line" | tee -a "${LOG_FILE}"
}

# Incrémente compteurs et enregistre échec éventuel
record() {
    local result="$1"
    local check="$2"
    local msg="${3:-}"
    TOTAL=$(( TOTAL + 1 ))
    case "$result" in
        OK)   OK_COUNT=$(( OK_COUNT + 1 ))   ;;
        SKIP) SKIP_COUNT=$(( SKIP_COUNT + 1 )) ;;
        FAIL)
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            FAIL_MESSAGES+=("${check}: ${msg}")
            ;;
    esac
}

# Vérifie le cap d'alertes Telegram (rolling 24h via fichier d'état)
# Retourne 0 si sous le cap, 1 sinon
can_send_alert() {
    local now
    now=$(date +%s)
    local cutoff=$(( now - 86400 ))

    # Lire les timestamps existants, garder seulement ceux < 24h
    local fresh_timestamps=()
    if [[ -f "${ALERT_STATE_FILE}" ]]; then
        while IFS= read -r ts; do
            [[ -n "$ts" && "$ts" -gt "$cutoff" ]] && fresh_timestamps+=("$ts")
        done < "${ALERT_STATE_FILE}" 2>/dev/null || true
    fi

    if [[ ${#fresh_timestamps[@]} -lt ${MAX_ALERTS_PER_DAY} ]]; then
        # Écrire le nouveau timestamp + les anciens récents
        printf '%s\n' "${fresh_timestamps[@]}" "$now" > "${ALERT_STATE_FILE}"
        return 0
    fi
    return 1
}

# Envoie une alerte Telegram si cap non atteint
send_alert() {
    local msg="$1"
    if [[ ! -x "${ALERT_SCRIPT}" ]]; then
        echo "[${TIMESTAMP}] WARN — send-telegram.sh absent ou non exécutable" | tee -a "${LOG_FILE}"
        return
    fi
    if can_send_alert; then
        "${ALERT_SCRIPT}" "${TELEGRAM_CHAT_ID}" "${msg}" 2>/dev/null \
            || echo "[${TIMESTAMP}] WARN — envoi Telegram échoué" | tee -a "${LOG_FILE}"
    else
        echo "[${TIMESTAMP}] INFO — cap alertes/jour atteint (${MAX_ALERTS_PER_DAY}), alerte supprimée" | tee -a "${LOG_FILE}"
    fi
}

# ---------------------------------------------------------------------------
# Check 1 — Primary AdGuard :53 résolution interne
# ---------------------------------------------------------------------------
check_primary_internal() {
    local start_ns end_ns latency_ms
    start_ns=$(date +%s%N)
    local result
    result=$(dig @"${PRIMARY_AG}" "${INTERNAL_HOST}" +short +time=3 +tries=1 2>/dev/null || true)
    end_ns=$(date +%s%N)
    latency_ms=$(( (end_ns - start_ns) / 1000000 ))

    if echo "$result" | grep -qE "${INTERNAL_PATTERN}"; then
        log_check "primary-adguard-internal" "OK" "latency=${latency_ms}ms"
        record "OK" "primary-adguard-internal"
    else
        log_check "primary-adguard-internal" "FAIL" "latency=${latency_ms}ms got='${result}'"
        record "FAIL" "primary-adguard-internal" "résolution .lab KO (got: ${result:-vide})"
    fi
}

# ---------------------------------------------------------------------------
# Check 2 — Primary AdGuard :53 résolution externe (retry 10s comportement D5)
# ---------------------------------------------------------------------------
check_primary_external() {
    local start_ns end_ns latency_ms
    start_ns=$(date +%s%N)
    local resolved=0

    for t in 3 10; do
        local r
        r=$(dig @"${PRIMARY_AG}" "${EXTERNAL_HOST}" +short +time="$t" +tries=1 2>/dev/null || true)
        if echo "$r" | grep -qE "^[0-9]"; then
            resolved=1
            break
        fi
    done

    end_ns=$(date +%s%N)
    latency_ms=$(( (end_ns - start_ns) / 1000000 ))

    if [[ $resolved -eq 1 ]]; then
        log_check "primary-adguard-external" "OK" "latency=${latency_ms}ms"
        record "OK" "primary-adguard-external"
    else
        log_check "primary-adguard-external" "FAIL" "latency=${latency_ms}ms no-ip-resolved"
        record "FAIL" "primary-adguard-external" "résolution externe KO après retry 10s"
    fi
}

# ---------------------------------------------------------------------------
# Check 3a — Secondary AdGuard llmcore :53 résolution interne
# ---------------------------------------------------------------------------
check_secondary_internal() {
    local start_ns end_ns latency_ms
    start_ns=$(date +%s%N)
    local result
    result=$(dig @"${SECONDARY_AG}" "${INTERNAL_HOST}" +short +time=3 +tries=1 2>/dev/null || true)
    end_ns=$(date +%s%N)
    latency_ms=$(( (end_ns - start_ns) / 1000000 ))

    if echo "$result" | grep -qE "${INTERNAL_PATTERN}"; then
        log_check "secondary-adguard-internal" "OK" "latency=${latency_ms}ms"
        record "OK" "secondary-adguard-internal"
    else
        log_check "secondary-adguard-internal" "FAIL" "latency=${latency_ms}ms got='${result}'"
        record "FAIL" "secondary-adguard-internal" "résolution .lab KO sur llmcore (got: ${result:-vide})"
    fi
}

# ---------------------------------------------------------------------------
# Check 3b — Secondary AdGuard llmcore :53 résolution externe
# ---------------------------------------------------------------------------
check_secondary_external() {
    local start_ns end_ns latency_ms
    start_ns=$(date +%s%N)
    local resolved=0

    for t in 3 10; do
        local r
        r=$(dig @"${SECONDARY_AG}" "${EXTERNAL_HOST}" +short +time="$t" +tries=1 2>/dev/null || true)
        if echo "$r" | grep -qE "^[0-9]"; then
            resolved=1
            break
        fi
    done

    end_ns=$(date +%s%N)
    latency_ms=$(( (end_ns - start_ns) / 1000000 ))

    if [[ $resolved -eq 1 ]]; then
        log_check "secondary-adguard-external" "OK" "latency=${latency_ms}ms"
        record "OK" "secondary-adguard-external"
    else
        log_check "secondary-adguard-external" "FAIL" "latency=${latency_ms}ms no-ip-resolved"
        record "FAIL" "secondary-adguard-external" "résolution externe KO sur llmcore après retry 10s"
    fi
}

# ---------------------------------------------------------------------------
# Fonction commune — vérifier si Unbound est déployé sur un hôte distant
# Retourne "active", "inactive", "not-installed", ou "ssh-error"
# ---------------------------------------------------------------------------
unbound_state_remote() {
    local user_host="$1"
    # systemctl is-enabled retourne :
    #   "enabled"   (exit 0) → unité activée
    #   "disabled"  (exit 1) → unité présente mais non activée → SKIP
    #   "not-found" (exit 1) → paquet non installé → SKIP
    # On capture stdout uniquement, on ignore stderr et le code retour.
    local enabled_out
    enabled_out=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${user_host}" \
        "systemctl is-enabled unbound 2>/dev/null; true" 2>/dev/null) || {
        echo "ssh-error"
        return
    }
    # Si la commande SSH elle-même échoue (connexion refusée, timeout)
    # le || {} ci-dessus l'attrape. Si le retour est vide → ssh-error.
    if [[ -z "$enabled_out" ]]; then
        echo "ssh-error"
        return
    fi

    # disabled, not-found, static, masked = non déployé → SKIP
    case "$enabled_out" in
        disabled|not-found|static|masked|not-installed)
            echo "not-installed"
            return
            ;;
        enabled|enabled-runtime)
            # Unbound activé → vérifier s'il est actif
            local active
            active=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${user_host}" \
                "systemctl is-active unbound 2>/dev/null || echo inactive" 2>/dev/null) || {
                echo "ssh-error"
                return
            }
            echo "$active"
            ;;
        *)
            # État inconnu — traiter comme non déployé par précaution
            echo "not-installed"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Check 4 — Primary Unbound :5335 loopback sur LXC 411 (SKIP si absent)
# ---------------------------------------------------------------------------
check_primary_unbound() {
    local state
    state=$(unbound_state_remote "${SSH_PRIMARY}")

    case "$state" in
        "not-installed")
            log_check "primary-unbound-loopback" "SKIP" "reason=not-deployed"
            record "SKIP" "primary-unbound-loopback"
            return
            ;;
        "ssh-error")
            # SSH vers primary en échec = problème infrastructure, pas Unbound
            log_check "primary-unbound-loopback" "FAIL" "reason=ssh-unreachable host=${PRIMARY_AG}"
            record "FAIL" "primary-unbound-loopback" "SSH vers ${PRIMARY_AG} inaccessible"
            return
            ;;
        "active")
            # Unbound actif → tester la résolution sur :5335
            local result
            result=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_PRIMARY}" \
                "dig @127.0.0.1 -p 5335 ${EXTERNAL_HOST} +short +time=5 +tries=1 2>/dev/null" 2>/dev/null) || true
            if echo "$result" | grep -qE "^[0-9]"; then
                log_check "primary-unbound-loopback" "OK" "resolved=${result%%$'\n'*}"
                record "OK" "primary-unbound-loopback"
            else
                log_check "primary-unbound-loopback" "FAIL" "got='${result:-vide}'"
                record "FAIL" "primary-unbound-loopback" "Unbound actif mais résolution :5335 KO"
            fi
            ;;
        *)
            # inactive ou état inconnu
            log_check "primary-unbound-loopback" "FAIL" "systemd-state=${state}"
            record "FAIL" "primary-unbound-loopback" "Unbound déployé mais état=${state}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Check 5 — Secondary Unbound :5335 loopback sur llmcore (SKIP si absent)
# ---------------------------------------------------------------------------
check_secondary_unbound() {
    local state
    state=$(unbound_state_remote "${SSH_SECONDARY}")

    case "$state" in
        "not-installed")
            log_check "secondary-unbound-loopback" "SKIP" "reason=not-deployed"
            record "SKIP" "secondary-unbound-loopback"
            return
            ;;
        "ssh-error")
            log_check "secondary-unbound-loopback" "FAIL" "reason=ssh-unreachable host=${SECONDARY_AG}"
            record "FAIL" "secondary-unbound-loopback" "SSH vers ${SECONDARY_AG} inaccessible"
            return
            ;;
        "active")
            local result
            result=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_SECONDARY}" \
                "dig @127.0.0.1 -p 5335 ${EXTERNAL_HOST} +short +time=5 +tries=1 2>/dev/null" 2>/dev/null) || true
            if echo "$result" | grep -qE "^[0-9]"; then
                log_check "secondary-unbound-loopback" "OK" "resolved=${result%%$'\n'*}"
                record "OK" "secondary-unbound-loopback"
            else
                log_check "secondary-unbound-loopback" "FAIL" "got='${result:-vide}'"
                record "FAIL" "secondary-unbound-loopback" "Unbound actif mais résolution :5335 KO sur llmcore"
            fi
            ;;
        *)
            log_check "secondary-unbound-loopback" "FAIL" "systemd-state=${state}"
            record "FAIL" "secondary-unbound-loopback" "Unbound déployé sur llmcore mais état=${state}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Check 6 — Primary Unbound cache hit rate (SKIP si non déployé ou < 100 req)
# ---------------------------------------------------------------------------
check_primary_unbound_cache() {
    # Vérifier d'abord si Unbound est actif
    local state
    state=$(unbound_state_remote "${SSH_PRIMARY}")

    if [[ "$state" != "active" ]]; then
        log_check "primary-unbound-cache-hit" "SKIP" "reason=not-deployed"
        record "SKIP" "primary-unbound-cache-hit"
        return
    fi

    # Récupérer les stats via unbound-control
    local stats
    stats=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_PRIMARY}" \
        "sudo unbound-control stats_noreset 2>/dev/null" 2>/dev/null) || {
        log_check "primary-unbound-cache-hit" "SKIP" "reason=unbound-control-unavailable"
        record "SKIP" "primary-unbound-cache-hit"
        return
    }

    local cache_hits num_queries
    cache_hits=$(echo "$stats" | grep -E "^total\.num\.cachehits=" | cut -d= -f2 | tr -d ' ' || echo "0")
    num_queries=$(echo "$stats" | grep -E "^total\.num\.queries=" | cut -d= -f2 | tr -d ' ' || echo "0")

    # Valeurs par défaut si non trouvées
    cache_hits="${cache_hits:-0}"
    num_queries="${num_queries:-0}"

    # Éviter la division par zéro ou cold start
    if [[ "$num_queries" -lt "${CACHE_MIN_QUERIES}" ]]; then
        log_check "primary-unbound-cache-hit" "SKIP" \
            "reason=cold-start queries=${num_queries} min=${CACHE_MIN_QUERIES}"
        record "SKIP" "primary-unbound-cache-hit"
        return
    fi

    # Calcul ratio via awk (arithmétique flottante)
    local ratio
    ratio=$(awk "BEGIN { printf \"%.3f\", ${cache_hits} / ${num_queries} }")

    local ok
    ok=$(awk "BEGIN { print (${ratio} >= ${CACHE_HIT_MIN_RATIO}) ? \"yes\" : \"no\" }")

    if [[ "$ok" == "yes" ]]; then
        log_check "primary-unbound-cache-hit" "OK" \
            "ratio=${ratio} hits=${cache_hits} queries=${num_queries}"
        record "OK" "primary-unbound-cache-hit"
    else
        log_check "primary-unbound-cache-hit" "FAIL" \
            "ratio=${ratio} hits=${cache_hits} queries=${num_queries} min=${CACHE_HIT_MIN_RATIO}"
        record "FAIL" "primary-unbound-cache-hit" \
            "cache hit ratio ${ratio} < ${CACHE_HIT_MIN_RATIO} (${cache_hits}/${num_queries} requêtes)"
    fi
}

# ---------------------------------------------------------------------------
# Check 7 — Primary Unbound recursion latency (SKIP si non déployé)
#
# Seuil dynamique selon uptime Unbound :
#   uptime < 900s (15min) → 2000ms  (cold DoT warmup, pas d'alerte)
#   uptime ≥ 900s         → 500ms   (normal)
#
# Raison : juste après un redémarrage Unbound, les premières requêtes
# ouvrent des connexions DoT (TLS handshake ~100–200ms chacune).
# La moyenne de récursion peut dépasser 500ms pendant ~60s sans que
# ce soit un vrai problème. Le seuil 2000ms absorbe ce warmup sans
# masquer des vrais problèmes (>2s = Unbound en échec réel).
# ---------------------------------------------------------------------------
check_primary_unbound_recursion() {
    local state
    state=$(unbound_state_remote "${SSH_PRIMARY}")

    if [[ "$state" != "active" ]]; then
        log_check "primary-unbound-recursion-latency" "SKIP" "reason=not-deployed"
        record "SKIP" "primary-unbound-recursion-latency"
        return
    fi

    local stats
    stats=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_PRIMARY}" \
        "sudo unbound-control stats_noreset 2>/dev/null" 2>/dev/null) || {
        log_check "primary-unbound-recursion-latency" "SKIP" "reason=unbound-control-unavailable"
        record "SKIP" "primary-unbound-recursion-latency"
        return
    }

    # Récupérer l'uptime Unbound depuis unbound-control status
    local uptime_sec
    uptime_sec=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_PRIMARY}" \
        "sudo unbound-control status 2>/dev/null | grep -oP 'uptime:\s*\K[0-9]+'" 2>/dev/null) || true
    uptime_sec="${uptime_sec:-9999}"  # défaut conservateur si non lisible

    # Seuil dynamique : 2000ms warmup (<15min), 500ms normal (≥15min)
    local threshold warmup_active
    if [[ -n "$uptime_sec" && "$uptime_sec" =~ ^[0-9]+$ && "$uptime_sec" -lt 900 ]]; then
        threshold=2000
        warmup_active=true
    else
        threshold="${RECURSION_LATENCY_MAX_MS}"
        warmup_active=false
    fi

    # recursion.time.avg en secondes (ex: 0.023456)
    local avg_s
    avg_s=$(echo "$stats" | grep -E "^total\.recursion\.time\.avg=" | cut -d= -f2 | tr -d ' ' || echo "0")
    avg_s="${avg_s:-0}"

    # Convertir en ms
    local avg_ms
    avg_ms=$(awk "BEGIN { printf \"%d\", ${avg_s} * 1000 }")

    if [[ "$avg_ms" -le "${threshold}" ]]; then
        log_check "primary-unbound-recursion-latency" "OK" \
            "avg_ms=${avg_ms} threshold=${threshold}ms uptime=${uptime_sec}s warmup=${warmup_active}"
        record "OK" "primary-unbound-recursion-latency"
    elif [[ "${warmup_active}" == "true" ]]; then
        # Dépasse seuil warmup (2000ms) — Unbound en échec réel même à froid
        log_check "primary-unbound-recursion-latency" "FAIL" \
            "avg_ms=${avg_ms} threshold=${threshold}ms uptime=${uptime_sec}s reason=latency-spike-warmup"
        record "FAIL" "primary-unbound-recursion-latency" \
            "latence récursion ${avg_ms}ms > seuil warmup ${threshold}ms (uptime=${uptime_sec}s)"
    else
        log_check "primary-unbound-recursion-latency" "FAIL" \
            "avg_ms=${avg_ms} threshold=${threshold}ms uptime=${uptime_sec}s reason=latency-spike"
        record "FAIL" "primary-unbound-recursion-latency" \
            "latence récursion ${avg_ms}ms > seuil ${threshold}ms (uptime=${uptime_sec}s)"
    fi
}

# ---------------------------------------------------------------------------
# Exécution des checks
# ---------------------------------------------------------------------------
check_primary_internal
check_primary_external
check_secondary_internal
check_secondary_external
check_primary_unbound
check_secondary_unbound
check_primary_unbound_cache
check_primary_unbound_recursion

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------
EXIT_CODE=0
[[ $FAIL_COUNT -gt 0 ]] && EXIT_CODE=1

SUMMARY_LINE="[${TIMESTAMP}] summary total=${TOTAL} ok=${OK_COUNT} fail=${FAIL_COUNT} skip=${SKIP_COUNT} exit=${EXIT_CODE}"
echo "$SUMMARY_LINE" | tee -a "${LOG_FILE}"

# ---------------------------------------------------------------------------
# Alerte Telegram si FAIL
# ---------------------------------------------------------------------------
if [[ $FAIL_COUNT -gt 0 ]]; then
    ALERT_MSG="ALERTE DNS — ${FAIL_COUNT} check(s) en echec ($(hostname))

"
    for fm in "${FAIL_MESSAGES[@]}"; do
        ALERT_MSG="${ALERT_MSG}  - ${fm}
"
    done
    ALERT_MSG="${ALERT_MSG}
$(date '+%Y-%m-%d %H:%M:%S')"
    send_alert "$ALERT_MSG"
fi

exit "${EXIT_CODE}"
