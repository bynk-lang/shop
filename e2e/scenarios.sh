#!/usr/bin/env bash
# End-to-end scenarios, run by bynk-lang/bynk-dev against the app served with
# `bynk dev`. BYNK_DEV_URL is the app's base URL. A failing command fails the
# run (the script runs under `bash -eo pipefail`).
#
# Replace these with scenarios for your own app. Assert on what a caller sees:
# status codes, bodies, and state carried between requests.
set -euo pipefail

url="${BYNK_DEV_URL:?run this through bynk-lang/bynk-dev}"

# Fetch a URL, print the body, and fail unless the status is the expected one.
expect_status() {
  local want="$1" method="$2" path="$3" body
  body=$(mktemp)
  got=$(curl -sS -X "$method" -o "$body" -w '%{http_code}' "$url$path")
  if [ "$got" != "$want" ]; then
    echo "::error::$method $path: expected $want, got $got: $(cat "$body")"
    exit 1
  fi
  cat "$body"
}

echo "a counter starts at zero"
test "$(expect_status 200 GET /counters/visits)" = 0

echo "each hit counts up, and the count is kept between requests"
test "$(expect_status 201 POST /counters/visits/hit)" = 1
test "$(expect_status 201 POST /counters/visits/hit)" = 2
test "$(expect_status 200 GET /counters/visits)" = 2

echo "counters are independent"
test "$(expect_status 200 GET /counters/other)" = 0
