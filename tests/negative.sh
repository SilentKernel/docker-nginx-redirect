#!/usr/bin/env bash
# Proves the smoke test and tests/os-updates.sh still catch a broken image (tests/guard.sh does the
# same for the nginx floor): tests/negative.sh <candidate>
# Builds small broken variants FROM the candidate and asserts that tests/smoke.sh rejects each one,
# for the expected reason. Exits non-zero if any broken variant gets through.
set -euo pipefail

CANDIDATE="${1:?usage: tests/negative.sh <candidate>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$ROOT/versions.env"
set +a

ID="nr-neg-$$-${RANDOM}"
VARIANTS=()
trap 'docker image rm -f ${VARIANTS[@]+"${VARIANTS[@]}"} >/dev/null 2>&1 || true' EXIT
FAILED=0

variant() {   # variant <name> <RUN instruction>: builds FROM the candidate into $VARIANT
    VARIANT="nginx-redirect-negative:${ID}-$1"
    VARIANTS+=("$VARIANT")
    printf 'FROM %s\nRUN %s\n' "$CANDIDATE" "$2" \
        | docker build -q --platform "$PLATFORM" -t "$VARIANT" - >/dev/null
}

expect_rejected() {   # expect_rejected <what> <expected output part> <command...>
    local what="$1" expected="$2" out
    shift 2
    if out="$("$@" 2>&1)"; then
        echo "FAIL $what: the gate let the broken image through" >&2
        FAILED=1
    elif [[ "$out" == *"$expected"* ]]; then
        echo "ok   $what"
    else
        printf '%s\n' "$out" | tail -5 >&2
        echo "FAIL $what: rejected, but not for the expected reason ($expected)" >&2
        FAILED=1
    fi
}

variant no-post-rule "sed -i '/request_method = POST/,/^    }\$/d' /etc/nginx/conf.d/default.conf"
expect_rejected "POST rule removed -> smoke.sh rejects it" \
    "POST with SERVER_REDIRECT_POST_CODE=307: got [302" "$ROOT/tests/smoke.sh" "$VARIANT"

variant no-forwarded-proto "sed -i 's/https https;/https http;/' /etc/nginx/conf.d/default.conf"
expect_rejected "X-Forwarded-Proto ignored -> smoke.sh rejects it" \
    "X-Forwarded-Proto: https: got [301 http://" "$ROOT/tests/smoke.sh" "$VARIANT"

variant any-code "sed -i \"s/'30\\[12378\\]\\$'/'[0-9]*'/g\" /run.sh"
expect_rejected "redirect code not validated -> smoke.sh rejects it" \
    "invalid SERVER_REDIRECT_CODE=200 falls back to 301: got [200" "$ROOT/tests/smoke.sh" "$VARIANT"

# A wrapper that still serves (exec of the real binary) but reports another version.
variant wrong-version "mkdir -p /usr/local/sbin && printf '#!/bin/sh\n[ \"\$1\" = -v ] && { echo \"nginx version: nginx/0.0.1\" >&2; exit 0; }\nexec /usr/sbin/nginx \"\$@\"\n' > /usr/local/sbin/nginx && chmod +x /usr/local/sbin/nginx"
expect_rejected "nginx binary not the expected version -> smoke.sh rejects it" \
    "nginx -v is [nginx version: nginx/0.0.1]" "$ROOT/tests/smoke.sh" "$VARIANT"

# Healthcheck: removed, retimed, or answering without looking at nginx. The curl wrappers lie only
# to the healthcheck (the one call with --max-time); smoke.sh's own requests get the real curl.
variant_lines() {   # variant_lines <name> <Dockerfile lines after FROM the candidate>: builds into $VARIANT
    VARIANT="nginx-redirect-negative:${ID}-$1"
    VARIANTS+=("$VARIANT")
    printf 'FROM %s\n%s\n' "$CANDIDATE" "$2" \
        | docker build -q --platform "$PLATFORM" -t "$VARIANT" - >/dev/null
}
variant_lines no-healthcheck "HEALTHCHECK NONE"
expect_rejected "HEALTHCHECK removed -> smoke.sh rejects it" \
    "no HEALTHCHECK in the image" "$ROOT/tests/smoke.sh" "$VARIANT"

variant_lines slow-healthcheck "HEALTHCHECK --interval=5m CMD curl -fsS -o /dev/null http://127.0.0.1/ || exit 1"
expect_rejected "HEALTHCHECK changed -> smoke.sh rejects it" \
    "HEALTHCHECK is [[CMD-SHELL curl" "$ROOT/tests/smoke.sh" "$VARIANT"

variant always-healthy "printf '#!/bin/sh\ncase \" \$* \" in *\" --max-time \"*) exit 0;; esac\nexec /usr/bin/curl \"\$@\"\n' > /usr/local/bin/curl && chmod +x /usr/local/bin/curl"
expect_rejected "healthcheck passing without nginx -> smoke.sh rejects it" \
    "healthy although nginx is not running" "$ROOT/tests/smoke.sh" "$VARIANT"

variant never-healthy "printf '#!/bin/sh\ncase \" \$* \" in *\" --max-time \"*) exit 7;; esac\nexec /usr/bin/curl \"\$@\"\n' > /usr/local/bin/curl && chmod +x /usr/local/bin/curl"
expect_rejected "healthcheck that never passes -> smoke.sh rejects it" \
    "never healthy with the image's own HEALTHCHECK" "$ROOT/tests/smoke.sh" "$VARIANT"

# Debian updates not applied: an old trixie snapshot (pinned by digest, so it always has pending
# updates) must be refused by tests/os-updates.sh, and the candidate accepted.
OLD_TRIXIE=debian:trixie-20250811@sha256:6d87375016340817ac2391e670971725a9981cfc24e221c47734681ed0f6c0f5
expect_rejected "Debian updates missing (trixie of 11 Aug 2025) -> os-updates.sh rejects it" "Debian update(s) missing" \
    "$ROOT/tests/os-updates.sh" "$OLD_TRIXIE"
if out="$("$ROOT/tests/os-updates.sh" "$CANDIDATE" 2>&1)"; then echo "ok   the candidate passes os-updates.sh"
else printf '%s\n' "$out" | tail -5 >&2; echo "FAIL the candidate itself is refused by os-updates.sh" >&2; FAILED=1; fi

if [ "$FAILED" = 0 ]; then echo "negative tests passed: every broken variant was rejected"; else exit 1; fi
