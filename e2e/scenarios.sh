#!/usr/bin/env bash
# End-to-end scenarios, run by bynk-lang/bynk-dev against the shop served with
# `bynk dev`: four Workers (inventory, payments, orders, ledger) wired by
# Service Bindings and events. A failing command fails the run.
#
# Environment from bynk-dev: BYNK_DEV_URL_SHOP_ORDERS, BYNK_DEV_URL_SHOP_LEDGER,
# BYNK_DEV_URL_SHOP_PAYMENTS, BYNK_DEV_URL_SHOP_INVENTORY. AUTH_JWT_SECRET and
# PAYMENTS_WEBHOOK_SECRET must match the values passed to `bynk dev`
# (wrangler-args), which must also set PAYMENTS_PROCESSOR:fake and pass
# --test-scheduled, so the sweeper can be run on demand.
set -euo pipefail

orders="${BYNK_DEV_URL_SHOP_ORDERS:?run this through bynk-lang/bynk-dev}"
ledger="${BYNK_DEV_URL_SHOP_LEDGER:?run this through bynk-lang/bynk-dev}"
payments="${BYNK_DEV_URL_SHOP_PAYMENTS:?run this through bynk-lang/bynk-dev}"
inventory="${BYNK_DEV_URL_SHOP_INVENTORY:?run this through bynk-lang/bynk-dev}"
secret="${AUTH_JWT_SECRET:?set AUTH_JWT_SECRET}"
whsecret="${PAYMENTS_WEBHOOK_SECRET:?set PAYMENTS_WEBHOOK_SECRET}"

b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# token <subject> [admin]: an HS256 bearer token, as the Customer and Admin
# actors verify it.
token() {
  local claims
  if [ "${2:-}" = admin ]; then
    claims="{\"sub\":\"$1\",\"admin\":true,\"exp\":4102444800}"
  else
    claims="{\"sub\":\"$1\",\"exp\":4102444800}"
  fi
  local h p s
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64)
  p=$(printf '%s' "$claims" | b64)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$secret" -binary | b64)
  printf '%s.%s.%s' "$h" "$p" "$s"
}

alice=$(token alice)
bob=$(token bob)
admin=$(token root admin)

# call <token|-> <method> <url> [json]: print "<status> <body>".
call() {
  local tok="$1" method="$2" url="$3" body="${4:-}" args=(-sS -X "$2" -w ' %{http_code}')
  [ "$tok" = - ] || args+=(-H "Authorization: Bearer $tok")
  [ -z "$body" ] || args+=(-H 'Content-Type: application/json' -d "$body")
  local out
  out=$(curl "${args[@]}" "$url")
  # curl appends " <status>"; reorder to "<status> <body>".
  printf '%s %s' "${out##* }" "${out% *}"
}

# expect <status> <body substring> <got>: fail with the response if it differs.
expect() {
  local want="$1" has="$2" got="$3"
  case "$got" in
    "$want "*"$has"*) return 0 ;;
  esac
  echo "::error::expected $want containing '$has', got: $got"
  exit 1
}

# The first call across a Service Binding fails until the binding has
# connected, so restock until it answers.
echo "warming up the bindings"
r=""
for _ in $(seq 1 30); do
  r=$(call "$admin" PUT "$orders/stock/warmup" '{"qty":1}') || true
  [ "${r%% *}" = 200 ] && break
  sleep 1
done
expect 200 1 "$r"

echo "authentication: no token is 401, a customer on an admin route is 403"
expect 401 "" "$(call - PUT "$orders/orders/x" '{"sku":"widget","qty":1,"cents":100}')"
expect 403 "" "$(call "$alice" PUT "$orders/stock/widget" '{"qty":10}')"

echo "an admin stocks 10 widgets"
expect 200 10 "$(call "$admin" PUT "$orders/stock/widget" '{"qty":10}')"

echo "anyone can see that widgets are in stock; only a customer sees how many"
r=$(call - GET "$orders/stock/widget")
expect 200 '{"kind":"InStock"}' "$r"
expect 200 '{"kind":"Left","count":10}' "$(call "$alice" GET "$orders/stock/widget")"

echo "alice places order o1 for 3 widgets: stock is reserved, the order is placed"
r=$(call "$alice" PUT "$orders/orders/o1" '{"sku":"widget","qty":3,"cents":2500}')
expect 201 placed "$r"
expect 200 7 "$(call "$admin" GET "$orders/stock/widget")"

echo "a zero quantity, an empty sku or a price over the limit is a 400, before any handler runs"
expect 400 '"path":"$.qty"' "$(call "$alice" PUT "$orders/orders/o9" '{"sku":"widget","qty":0,"cents":100}')"
expect 400 '"path":"$.sku"' "$(call "$alice" PUT "$orders/orders/o9" '{"sku":"","qty":1,"cents":100}')"
expect 400 '"path":"$.cents"' "$(call "$alice" PUT "$orders/orders/o9" '{"sku":"widget","qty":1,"cents":10000001}')"
expect 400 RefinementViolation "$(call "$admin" PUT "$orders/stock/widget" '{"qty":-5}')"
expect 200 7 "$(call "$admin" GET "$orders/stock/widget")"
expect 404 "" "$(call "$alice" GET "$orders/orders/o9")"

echo "an order whose total is over 100,000.00 is a 422, and reserves nothing"
expect 422 "100,000.00" "$(call "$alice" PUT "$orders/orders/o8" '{"sku":"widget","qty":1000,"cents":20000}')"
expect 200 7 "$(call "$admin" GET "$orders/stock/widget")"
expect 404 "" "$(call "$alice" GET "$orders/orders/o8")"

echo "placing the same id again is refused, and changes nothing"
expect 409 decided "$(call "$alice" PUT "$orders/orders/o1" '{"sku":"widget","qty":1,"cents":100}')"
expect 200 7 "$(call "$admin" GET "$orders/stock/widget")"

echo "an order belongs to its customer"
expect 200 alice "$(call "$alice" GET "$orders/orders/o1")"
expect 404 "" "$(call "$bob" GET "$orders/orders/o1")"

echo "more than is in stock is refused, and the stock invariant holds"
expect 409 "out of stock" "$(call "$alice" PUT "$orders/orders/o2" '{"sku":"widget","qty":100,"cents":100}')"
expect 200 7 "$(call "$admin" GET "$orders/stock/widget")"

echo "a declined payment releases the stock it reserved"
expect 422 declined "$(call "$alice" PUT "$orders/orders/o3" '{"sku":"widget","qty":2,"cents":200000}')"
expect 200 7 "$(call "$admin" GET "$orders/stock/widget")"

echo "bob places order o4 for 2 widgets"
expect 201 placed "$(call "$bob" PUT "$orders/orders/o4" '{"sku":"widget","qty":2,"cents":1000}')"
expect 200 5 "$(call "$admin" GET "$orders/stock/widget")"

echo "alice cancels o1: the stock comes back, and a second cancel is refused"
expect 200 cancelled "$(call "$alice" POST "$orders/orders/o1/cancel")"
expect 200 8 "$(call "$admin" GET "$orders/stock/widget")"
expect 409 "" "$(call "$alice" POST "$orders/orders/o1/cancel")"

echo "the ledger, fed by events, ends with one standing order (o4)"
# Events are delivered asynchronously, so poll for the settled totals.
want='1 2 1000'
got=""
r=""
for _ in $(seq 1 20); do
  r=$(call "$admin" GET "$ledger/totals") || true
  body="${r#* }"
  got=$(python3 -c 'import json,sys; t=json.loads(sys.argv[1]); print(t["orders"],t["units"],t["cents"])' "$body" 2>/dev/null || true)
  [ "$got" = "$want" ] && break
  sleep 1
done
if [ "$got" != "$want" ]; then
  echo "::error::ledger totals (orders units cents): expected '$want', got '$got' from: $r"
  exit 1
fi

# notify <json> [timestamp] [signature]: POST a webhook notice to payments as
# the processor sends it, signed over "<timestamp>.<body>" unless a signature
# is given; print "<status> <body>".
notify() {
  local body="$1" ts="${2:-$(date +%s)}" sig="${3:-}"
  [ -n "$sig" ] || sig=$(printf '%s.%s' "$ts" "$body" | openssl dgst -sha256 -hmac "$whsecret" -r | cut -d' ' -f1)
  local out
  out=$(curl -sS -X POST -w ' %{http_code}' "$payments/webhooks/processor" \
    -H 'Content-Type: application/json' \
    -H "X-Processor-Timestamp: $ts" -H "X-Processor-Signature: sha256=$sig" -d "$body")
  printf '%s %s' "${out##* }" "${out% *}"
}

# The fake processor's authorisation id for o4 is "fake_o4".
captured='{"id":"evt_1","event":"payment.captured","payment":"fake_o4"}'

echo "the processor's webhook: an unsigned or forged notice is 401"
expect 401 "" "$(call - POST "$payments/webhooks/processor" "$captured")"
expect 401 "" "$(notify "$captured" "$(date +%s)" deadbeef)"

echo "a correctly signed notice from ten minutes ago is refused: the replay window is five"
expect 401 "" "$(notify "$captured" "$(( $(date +%s) - 600 ))")"

echo "a signed capture moves o4's payment on, and the same notice again changes nothing"
expect 200 captured "$(notify "$captured")"
expect 200 captured "$(notify "$captured")"

echo "a refund follows a capture; a second capture does not"
expect 200 refunded "$(notify '{"id":"evt_2","event":"payment.refunded","payment":"fake_o4"}')"
expect 409 "" "$(notify '{"id":"evt_3","event":"payment.captured","payment":"fake_o4"}')"

echo "a notice for a payment the shop never took is refused"
expect 409 "" "$(notify '{"id":"evt_4","event":"payment.captured","payment":"auth_unknown"}')"

echo "the stale-reservation sweeper runs an hour from now, and leaves settled stock alone"
# Every hold so far was committed or released, so there is nothing to sweep.
at=$(( ($(date +%s) + 3600) * 1000 ))
r=$(curl -sS -w ' %{http_code}' "$inventory/__scheduled?cron=*/5+*+*+*+*&time=$at")
expect 200 "" "${r##* } ${r% *}"
expect 200 8 "$(call "$admin" GET "$orders/stock/widget")"

echo "all scenarios passed"
