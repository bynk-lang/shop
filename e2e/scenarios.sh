#!/usr/bin/env bash
# End-to-end scenarios, run by bynk-lang/bynk-dev against the shop served with
# `bynk dev`: four Workers (inventory, payments, orders, ledger) wired by
# Service Bindings and events. A failing command fails the run.
#
# Environment from bynk-dev: BYNK_DEV_URL_SHOP_ORDERS, BYNK_DEV_URL_SHOP_LEDGER.
# AUTH_JWT_SECRET must match the secret passed to `bynk dev` (wrangler-args).
set -euo pipefail

orders="${BYNK_DEV_URL_SHOP_ORDERS:?run this through bynk-lang/bynk-dev}"
ledger="${BYNK_DEV_URL_SHOP_LEDGER:?run this through bynk-lang/bynk-dev}"
secret="${AUTH_JWT_SECRET:?set AUTH_JWT_SECRET}"

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

echo "alice places order o1 for 3 widgets: stock is reserved, the order is placed"
r=$(call "$alice" PUT "$orders/orders/o1" '{"sku":"widget","qty":3,"cents":2500}')
expect 201 placed "$r"
expect 200 7 "$(call "$admin" GET "$orders/stock/widget")"

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

echo "all scenarios passed"
