#!/bin/bash
# ==============================================================================
# Nanit RTMP Stream Health Check
#
# Monitors go2rtc for active RTMP producers. If no producers are active for
# MAX_FAILURES consecutive checks, restarts the nanit container.
#
# This handles the "too many app connections" loop where nanit retries every
# 5 minutes but never recovers without a restart.
#
# Deploy to /opt/nanit/ on the PRIMARY container only.
# Run via systemd timer (nanit-healthcheck.timer) every 3 minutes.
# ==============================================================================

STATE_FILE="/tmp/nanit-healthcheck-failures"
MAX_FAILURES=2
LOG_FILE="/var/log/nanit-healthcheck.log"

log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") $1" >> "${LOG_FILE}"
}

# Query go2rtc API for active RTMP producers (cameras pushing streams)
ACTIVE=$(curl -s --max-time 5 http://127.0.0.1:1984/api/streams 2>/dev/null \
    | jq "[.[] | .producers[] | select(has(\"remote_addr\"))] | length" 2>/dev/null)

# If go2rtc API is unreachable, skip this check (go2rtc may be restarting)
if [[ -z "${ACTIVE}" || "${ACTIVE}" == "null" ]]; then
    log "WARNING: Could not query go2rtc API, skipping check"
    exit 0
fi

# Healthy: at least one active producer
if [[ "${ACTIVE}" -gt 0 ]]; then
    if [[ -f "${STATE_FILE}" ]]; then
        rm -f "${STATE_FILE}"
        log "OK: ${ACTIVE} active producer(s), recovered"
    fi
    exit 0
fi

# Unhealthy: no active producers — increment failure counter
FAILURES=0
if [[ -f "${STATE_FILE}" ]]; then
    FAILURES=$(cat "${STATE_FILE}" 2>/dev/null || echo 0)
fi
FAILURES=$((FAILURES + 1))
echo "${FAILURES}" > "${STATE_FILE}"
log "WARNING: No active RTMP producers (failure ${FAILURES}/${MAX_FAILURES})"

# After MAX_FAILURES consecutive failures, restart nanit
if [[ "${FAILURES}" -ge "${MAX_FAILURES}" ]]; then
    log "RESTARTING: nanit container after ${FAILURES} consecutive failures"
    cd /opt/nanit && docker compose up -d nanit >> "${LOG_FILE}" 2>&1
    rm -f "${STATE_FILE}"
fi
