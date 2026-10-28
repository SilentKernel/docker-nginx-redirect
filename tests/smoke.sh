#!/usr/bin/env bash
# Smoke test of a built nginx-redirect image: tests/smoke.sh <image>
# Every documented environment variable (README.md), each case in its own container, checked over
# HTTP from inside the container (status code + Location), then the HEALTHCHECK (configuration,
# healthy, /tmp/drain, unhealthy without nginx). Exits non-zero on the first failure.
set -euo pipefail

TARGET="${1:?usage: tests/smoke.sh <image>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$ROOT/versions.env"
set +a

# Expected version: what build.sh read from the official image (exported). Run on its own, the
# image's label says what it was built from; the checks below prove the binary matches it.
NGINX_VERSION="${NGINX_VERSION:-$(docker image inspect -f '{{ index .Config.Labels "dev.nginx-redirect.nginx-version" }}' "$TARGET")}"
[ -n "$NGINX_VERSION" ] || { echo "FAIL: no expected nginx version (env or label)" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

CONTAINERS=()
trap 'docker rm -f ${CONTAINERS[@]+"${CONTAINERS[@]}"} >/dev/null 2>&1 || true' EXIT

# start [docker run options...]: starts the image, waits until nginx answers; the id is in $CID.
start() {
    CID="$(docker run -d --platform "$PLATFORM" "$@" "$TARGET")"
    CONTAINERS+=("$CID")
    for _ in $(seq 1 50); do
        docker exec "$CID" curl -s -o /dev/null http://localhost/ 2>/dev/null && return 0
        if [ "$(docker inspect -f '{{.State.Running}}' "$CID")" != true ]; then
            docker logs "$CID" >&2
            fail "container exited ($*)"
        fi
        sleep 0.2
    done
    docker logs "$CID" >&2
    fail "nginx never answered ($*)"
}

# expect <description> <"code location"> [curl options...] <path>: one request inside $CID.
expect() {
    local what="$1" expected="$2" got
    shift 2
    got="$(docker exec "$CID" curl -s -o /dev/null -w '%{http_code} %header{location}' "$@")"
    [ "$got" = "$expected" ] || fail "${what}: got [${got}], expected [${expected}]"
    pass "${what}: ${got}"
}

# 1. Defaults: 301 for every method, to the same scheme + URI, X-Forwarded-Proto honoured.
start -e SERVER_REDIRECT=www.example.com
v="$(docker exec "$CID" nginx -v 2>&1)"
[ "$v" = "nginx version: nginx/${NGINX_VERSION}" ] || fail "nginx -v is [$v], expected nginx/${NGINX_VERSION}"
pass "$v"
docker exec "$CID" nginx -t >/dev/null 2>&1 || fail "nginx -t rejects the generated configuration"
pass "nginx -t accepts the generated configuration"
expect "GET keeps path and query" "301 http://www.example.com/foo/bar?x=1&y=2" "http://localhost/foo/bar?x=1&y=2"
expect "HEAD" "301 http://www.example.com/h" -I "http://localhost/h"
for m in POST PUT PATCH DELETE; do
    expect "$m defaults to SERVER_REDIRECT_CODE" "301 http://www.example.com/m" -X "$m" "http://localhost/m"
done
expect "X-Forwarded-Proto: https" "301 https://www.example.com/p" -H "X-Forwarded-Proto: https" "http://localhost/p"
expect "X-Forwarded-Proto: http" "301 http://www.example.com/p" -H "X-Forwarded-Proto: http" "http://localhost/p"
sleep 0.5
# Read into a variable, never piped into grep -q: grep exits on the first match, docker logs then dies
# of SIGPIPE and pipefail turns the match into a failure (and, under `!`, a hit into a pass).
logs="$(docker logs "$CID" 2>/dev/null)"
grep -q '"GET /foo/bar?x=1&y=2 HTTP/1.1" 301' <<<"$logs" \
    || fail "the access log of the GET request is not on stdout"
pass "access log on stdout"

# 2. Per-method codes.
start -e SERVER_REDIRECT=www.example.com -e SERVER_REDIRECT_CODE=302 \
    -e SERVER_REDIRECT_POST_CODE=307 -e SERVER_REDIRECT_PUT_PATCH_DELETE_CODE=308
expect "GET with SERVER_REDIRECT_CODE=302" "302 http://www.example.com/a" "http://localhost/a"
expect "POST with SERVER_REDIRECT_POST_CODE=307" "307 http://www.example.com/a" -X POST "http://localhost/a"
for m in PUT PATCH DELETE; do
    expect "$m with SERVER_REDIRECT_PUT_PATCH_DELETE_CODE=308" "308 http://www.example.com/a" -X "$m" "http://localhost/a"
done

# 3. Every allowed code, and invalid ones falling back.
for code in 303 307 308; do
    start -e SERVER_REDIRECT=www.example.com -e SERVER_REDIRECT_CODE="$code"
    expect "SERVER_REDIRECT_CODE=$code" "$code http://www.example.com/" "http://localhost/"
done
for code in 200 abc 3010 x301; do
    start -e SERVER_REDIRECT=www.example.com -e SERVER_REDIRECT_CODE="$code"
    expect "invalid SERVER_REDIRECT_CODE=$code falls back to 301" "301 http://www.example.com/" "http://localhost/"
done
start -e SERVER_REDIRECT=www.example.com -e SERVER_REDIRECT_CODE=302 \
    -e SERVER_REDIRECT_POST_CODE=999 -e SERVER_REDIRECT_PUT_PATCH_DELETE_CODE=200
expect "invalid POST code falls back to SERVER_REDIRECT_CODE" "302 http://www.example.com/" -X POST "http://localhost/"
expect "invalid PUT code falls back to SERVER_REDIRECT_CODE" "302 http://www.example.com/" -X PUT "http://localhost/"

# 4. Fixed path and scheme; the scheme wins over X-Forwarded-Proto.
start -e SERVER_REDIRECT=www.example.com -e SERVER_REDIRECT_PATH=/landingpage -e SERVER_REDIRECT_SCHEME=https
expect "SERVER_REDIRECT_PATH + SERVER_REDIRECT_SCHEME" "301 https://www.example.com/landingpage" "http://localhost/any/path?q=1"
expect "SERVER_REDIRECT_SCHEME wins over X-Forwarded-Proto" "301 https://www.example.com/landingpage" \
    -H "X-Forwarded-Proto: http" "http://localhost/x"

# 5. SERVER_NAME with a named capture used in SERVER_REDIRECT (README example).
start -e 'SERVER_NAME=~^www.(?<subdomain>.+).example.com' -e 'SERVER_REDIRECT=${subdomain}.example.org'
expect "SERVER_NAME capture in SERVER_REDIRECT" "301 http://shop.example.org/cart" \
    -H "Host: www.shop.example.com" "http://localhost/cart"

# 6. Log locations.
start -e SERVER_REDIRECT=www.example.com -e SERVER_ACCESS_LOG=/dev/null
expect "request with SERVER_ACCESS_LOG=/dev/null" "301 http://www.example.com/quiet" "http://localhost/quiet"
sleep 0.5
logs="$(docker logs "$CID" 2>/dev/null)"
! grep -q 'GET /quiet' <<<"$logs" || fail "SERVER_ACCESS_LOG=/dev/null still logs to stdout"
pass "SERVER_ACCESS_LOG=/dev/null silences the access log"

# 7. SERVER_REDIRECT is mandatory.
if out="$(docker run --rm --platform "$PLATFORM" "$TARGET" 2>&1)"; then
    fail "the container started without SERVER_REDIRECT"
fi
[[ "$out" == *"SERVER_REDIRECT is not set"* ]] || fail "no SERVER_REDIRECT: unexpected output [$out]"
pass "refuses to start without SERVER_REDIRECT"

# 8. Healthcheck (what docker rollout waits for): the exact configuration, healthy while nginx
#    answers, unhealthy while /tmp/drain exists, unhealthy when nginx does not run.
HC_EXPECTED='[CMD-SHELL test ! -f /tmp/drain && curl -fsS -o /dev/null --max-time 2 http://127.0.0.1/ || exit 1] 10s 3s 30s 1s 3'
hc="$(docker image inspect -f '{{with .Config.Healthcheck}}{{.Test}} {{.Interval}} {{.Timeout}} {{.StartPeriod}} {{.StartInterval}} {{.Retries}}{{else}}none{{end}}' "$TARGET")"
case "$hc" in none|"[NONE] "*) fail "no HEALTHCHECK in the image" ;; esac   # [NONE]: HEALTHCHECK NONE
[ "$hc" = "$HC_EXPECTED" ] || fail "HEALTHCHECK is [$hc], expected [$HC_EXPECTED]"
pass "HEALTHCHECK: /tmp/drain + curl http://127.0.0.1/, every 10s (1s while starting), 3 retries"

# wait_health <container> <status> <seconds>: until Docker reports that health status.
wait_health() {
    local cid="$1" want="$2" got=""
    for _ in $(seq 1 $(($3 * 2))); do
        got="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid")"
        [ "$got" = "$want" ] && return 0
        sleep 0.5
    done
    echo "health is [${got}] after $3 s, expected [${want}]; checks: $(docker inspect -f '{{with .State.Health}}{{json .Log}}{{end}}' "$cid" | tail -c 600)" >&2
    return 1
}

start -e SERVER_REDIRECT=www.example.com
wait_health "$CID" healthy 15 || fail "never healthy with the image's own HEALTHCHECK"
pass "healthy with the image's own HEALTHCHECK"

# The same command, checked every second and unhealthy at the first failure: the tests below take
# seconds instead of the 30 s the production timings need.
FAST=(--health-interval=1s --health-retries=1 --health-start-period=1ms)
start "${FAST[@]}" -e SERVER_REDIRECT=www.example.com
wait_health "$CID" healthy 10 || fail "never healthy (fast timings)"
docker exec "$CID" touch /tmp/drain
wait_health "$CID" unhealthy 10 || fail "still healthy with /tmp/drain: docker rollout could not drain it"
expect "still redirects while draining" "301 http://www.example.com/d" "http://localhost/d"
docker exec "$CID" rm /tmp/drain
wait_health "$CID" healthy 10 || fail "not healthy again once /tmp/drain is removed"
pass "/tmp/drain: unhealthy while it exists (nginx still serving), healthy again without it"

CID="$(docker run -d --platform "$PLATFORM" "${FAST[@]}" --entrypoint sleep "$TARGET" infinity)"
CONTAINERS+=("$CID")
wait_health "$CID" unhealthy 10 || fail "healthy although nginx is not running: the HEALTHCHECK does not test nginx"
pass "unhealthy when nginx does not run"

echo "all checks passed for $TARGET"
