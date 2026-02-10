#!/usr/bin/env bash
set -euo pipefail
echo "RUNNING NEW SCRIPT ✅ $(date)";
BASE="${BASE:-http://localhost}"

# Flags
VERBOSE=0
SLOW=0
SHOW_BODY=0

for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    -s|--slow) SLOW=1 ;;
    --show-body) VERBOSE=1; SHOW_BODY=1 ;;
  esac
done

# Rates
BAD_REQUEST_RATE="${BAD_REQUEST_RATE:-12}"
ONBOARD_RATE="${ONBOARD_RATE:-30}"
CREDIT_RATE="${CREDIT_RATE:-40}"
CREATE_PRODUCT_RATE="${CREATE_PRODUCT_RATE:-20}"
ASSIGN_PRODUCT_RATE="${ASSIGN_PRODUCT_RATE:-40}"
READS_RATE="${READS_RATE:-70}"

# Colors
if [[ -n "${NO_COLOR:-}" ]]; then
  C_RESET=""; C_GREEN=""; C_RED=""; C_GRAY=""
else
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_GRAY=$'\033[90m'
fi

# Timing (portable)
now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
    return
  fi
  echo $(( $(date +%s) * 1000 ))
}

LAST_CALL_MS=0
rate_limit() {
  [[ "${SLOW}" == "1" ]] || return 0
  local now; now="$(now_ms)"
  if [[ "${LAST_CALL_MS}" -ne 0 ]]; then
    local elapsed=$(( now - LAST_CALL_MS ))
    if (( elapsed < 1000 )); then
      sleep "$(awk -v ms=$((1000 - elapsed)) 'BEGIN{printf "%.3f", ms/1000}')"
    fi
  fi
  LAST_CALL_MS="$(now_ms)"
}

# Helpers
rand_email() { echo "demo$((RANDOM % 100000))@example.com"; }

rand_amount() {
  local a=(5 10 20 50 75 100 150 250 500)
  echo "${a[$((RANDOM % ${#a[@]}))]}"
}

rand_category() {
  local c=(plan sku service benefit addon)
  echo "${c[$((RANDOM % ${#c[@]}))]}"
}

extract_id() {
  echo "$1" | sed -nE 's/.*"([a-zA-Z]*Id|id)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' | head -n 1
}

maybe_bad() {
  [[ $((RANDOM % 100)) -lt "${BAD_REQUEST_RATE}" ]]
}

print_line() {
  local method="$1" path="$2" status="$3" ms="$4"
  if [[ "${status}" =~ ^2 ]]; then
    printf "%s✓%s %s %s (%sms)\n" "${C_GREEN}" "${C_RESET}" "${method}" "${path}" "${ms}" >&2
  else
    printf "%s✗%s %s %s (%s, %sms)\n" "${C_RED}" "${C_RESET}" "${method}" "${path}" "${status}" "${ms}" >&2
  fi
}


detail() {
  [[ "${VERBOSE}" == "1" ]] && echo "    $*" >&2
}

request() {
  local method="$1" path="$2" good_payload="${3:-}" bad_payload="${4:-}"

  rate_limit

  local payload=""
  if [[ -n "${good_payload}" ]]; then
    payload="${good_payload}"
    if maybe_bad && [[ -n "${bad_payload}" ]]; then
      payload="${bad_payload}"
    fi
  fi

  local resp status secs body
  resp="$(curl -sS -X "${method}" "${BASE}${path}" \
    -H 'content-type: application/json' \
    ${payload:+-d "${payload}"} \
    -w $'\n__STATUS__:%{http_code}\n__TIME__:%{time_total}\n' \
    || true)"

  status="$(echo "${resp}" | sed -nE 's/^__STATUS__:(.*)$/\1/p' | tail -n 1)"
  secs="$(echo "${resp}" | sed -nE 's/^__TIME__:(.*)$/\1/p' | tail -n 1)"
  body="$(echo "${resp}" | sed '/^__STATUS__:/,$d')"

  [[ -z "${status}" ]] && status="000"
  [[ -z "${secs}" ]] && secs="0"

  local ms
  ms="$(awk -v s="${secs}" 'BEGIN{printf "%.1f", s*1000}')"

  print_line "${method}" "${path}" "${status}" "${ms}"

  if [[ "${VERBOSE}" == "1" && -n "${payload}" ]]; then
    detail "payload: ${payload}"
  fi

  if [[ "${VERBOSE}" == "1" && "${SHOW_BODY}" == "1" && ! "${status}" =~ ^2 ]]; then
    local snippet
    snippet="$(echo "${body}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | head -c 140)"
    [[ -n "${snippet}" ]] && detail "body: ${snippet}"
  fi

  echo "${body}"
}

# Header
echo "🚦 Traffic generator"
echo "Base: ${BASE}"
[[ "${VERBOSE}" == "1" ]] && echo "Verbose: ON"
[[ "${SLOW}" == "1" ]] && echo "Slow mode: ON (≈1 req/sec)"
echo "BadReqRate: ${BAD_REQUEST_RATE}%"
echo
trap 'echo; echo "Stopping."; exit 0' INT

PRODUCT_IDS=()

while true; do
  email="$(rand_email)"
  amt="$(rand_amount)"
  category="$(rand_category)"

  user_resp="$(request POST /identity/users \
    "{\"name\":\"Demo User\",\"email\":\"${email}\"}" \
    "{\"name\":\"Demo User\"}")"
  user_id="$(extract_id "${user_resp}")"

  account_resp="$(request POST /accounts/accounts \
    "{\"userId\":\"${user_id}\",\"type\":\"standard\"}" \
    "{\"type\":\"standard\"}")"
  account_id="$(extract_id "${account_resp}")"

  if [[ $((RANDOM % 100)) -lt "${ONBOARD_RATE}" ]]; then
    request POST /accounts/accounts/onboard \
      "{\"email\":\"${email}\",\"initialCredit\":${amt}}" \
      "{\"initialCredit\":${amt}}" >/dev/null
  fi

  if [[ -n "${account_id}" && $((RANDOM % 100)) -lt "${CREDIT_RATE}" ]]; then
    request POST "/accounts/accounts/${account_id}/credit" \
      "{\"amount\":${amt}}" \
      "{\"amount\":-1}" >/dev/null
  fi

  if [[ $((RANDOM % 100)) -lt "${CREATE_PRODUCT_RATE}" ]]; then
    prod_resp="$(request POST /catalog/products \
      "{\"name\":\"${category}-$(rand_amount)\",\"price\":${amt},\"category\":\"${category}\"}" \
      "{\"name\":\"${category}-$(rand_amount)\",\"price\":${amt}}")"
    prod_id="$(extract_id "${prod_resp}")"
    [[ -n "${prod_id}" ]] && PRODUCT_IDS+=("${prod_id}")
  fi

  if [[ -n "${account_id}" && "${#PRODUCT_IDS[@]}" -gt 0 && $((RANDOM % 100)) -lt "${ASSIGN_PRODUCT_RATE}" ]]; then
    pid="${PRODUCT_IDS[$((RANDOM % ${#PRODUCT_IDS[@]}))]}"
    request POST "/catalog/products/${pid}/assign" \
      "{\"accountId\":\"${account_id}\"}" \
      "{}" >/dev/null
  fi

  if [[ $((RANDOM % 100)) -lt "${READS_RATE}" ]]; then
    request GET "/accounts/accounts/${account_id}" >/dev/null
    request GET "/catalog/products?category=${category}" >/dev/null
    request GET "/identity/users?email=${email}" >/dev/null
    maybe_bad && request GET "/accounts/accounts/not-a-real-id" >/dev/null
  fi
done
