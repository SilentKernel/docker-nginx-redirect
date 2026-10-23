#!/usr/bin/env bash
# Unit tests of the scripts in scripts/: offline, no Docker, a few seconds. Needs python3 and curl.
#   tests/unit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
FAILED=0

pass() { echo "ok   $*"; }
bad() { echo "FAIL $*" >&2; FAILED=1; }

expect_ok() {   # <name> <expected output> <command...>
    local name="$1" expected="$2" out
    shift 2
    if out="$("$@")" && [ "$out" = "$expected" ]; then pass "$name"; else bad "$name: got [$out]"; fi
}

expect_fail() {   # <name> <expected message part> <command...>
    local name="$1" msg="$2" out
    shift 2
    if out="$("$@")"; then bad "$name: succeeded with [$out]"
    elif [[ "$out" == *"$msg"* ]]; then pass "$name"
    else bad "$name: failed, but with [$out]"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; [ -z "${server_pid:-}" ] || kill "$server_pid" 2>/dev/null || true' EXIT

echo "--- resolve-versions.sh"
# Runs the resolver offline on a download page, with extra VAR=value assignments.
resolve() {
    env -i PATH="$PATH" NGINX_SERIES=1.30 NGINX_DOWNLOAD_HTML_FILE="$FIX/nginx-download.html" \
        "$@" "$ROOT/scripts/resolve-versions.sh" 2>&1
}
expect_ok "latest 1.30.x of the real nginx.org page (mainline 1.31.x and legacy 1.28.x ignored)" \
    "NGINX_LATEST=1.30.6" resolve
expect_ok "mainline series when asked" "NGINX_LATEST=1.31.8" resolve NGINX_SERIES=1.31
printf '<a href="/download/nginx-1.30.9.tar.gz">x</a> <a href="/download/nginx-1.30.10.tar.gz">y</a>
<a href="/download/nginx-1.30.2.tar.gz.asc">pgp</a> <a href="/download/nginx-1.300.1.tar.gz">z</a>' > "$tmp/many.html"
expect_ok "1.30.10 > 1.30.9 (numeric, not lexical); 1.300.x is not 1.30.x" \
    "NGINX_LATEST=1.30.10" resolve NGINX_DOWNLOAD_HTML_FILE="$tmp/many.html"
expect_fail "series absent from the page" "no nginx 1.29.x release" resolve NGINX_SERIES=1.29
echo '<html>maintenance</html>' > "$tmp/maint.html"
expect_fail "maintenance page" "no nginx 1.30.x release" resolve NGINX_DOWNLOAD_HTML_FILE="$tmp/maint.html"
: > "$tmp/empty.html"
expect_fail "empty answer" "no nginx 1.30.x release" resolve NGINX_DOWNLOAD_HTML_FILE="$tmp/empty.html"
expect_fail "NGINX_SERIES unset" "NGINX_SERIES is not set" \
    bash -c '"$@" 2>&1' _ env -i PATH="$PATH" NGINX_DOWNLOAD_HTML_FILE="$FIX/nginx-download.html" "$ROOT/scripts/resolve-versions.sh"

echo "--- version-compare.sh (no-downgrade, freshness)"
cmp() { "$ROOT/scripts/version-compare.sh" "$@" && echo allowed || echo refused; }
expect_ok "1.30.5 -> 1.30.6 allowed" allowed cmp 1.30.5 1.30.6
expect_ok "1.30.6 -> 1.30.5 refused" refused cmp 1.30.6 1.30.5
expect_ok "1.30.9 -> 1.30.10 allowed (numeric, not lexical)" allowed cmp 1.30.9 1.30.10
expect_ok "1.30.10 -> 1.30.9 refused (numeric, not lexical)" refused cmp 1.30.10 1.30.9
expect_ok "same version allowed (nightly rebuild with Alpine fixes)" allowed cmp 1.30.6 1.30.6
expect_ok "nothing published yet allowed" allowed cmp "" 1.30.6

echo "--- trivy-diff.py (vulnerability gate)"
vuln() { printf '{"VulnerabilityID": "%s", "PkgName": "%s", "Severity": "%s", "FixedVersion": "9"}' "$@"; }
printf '{"Results": [{"Vulnerabilities": [%s, %s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" "$(vuln CVE-2 curl HIGH)" > "$tmp/t-pub.json"
printf '{"Results": [{"Vulnerabilities": [%s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" > "$tmp/t-same.json"
printf '{"Results": [{"Vulnerabilities": [%s, %s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" "$(vuln CVE-3 libxml2 CRITICAL)" > "$tmp/t-new.json"
printf '{"Results": [{"Target": "x", "Vulnerabilities": null}]}' > "$tmp/t-clean.json"
td() { python3 -I "$ROOT/scripts/trivy-diff.py" "$@" 2>&1; }
expect_ok "a CRITICAL the published image already has: pass" \
    "$(printf '  info candidate: 1 fixable CRITICAL, 0 fixable HIGH\n  info 1 fixable HIGH/CRITICAL of the published image fixed by the candidate\n  ok   no fixable CRITICAL the published image does not already have')" \
    td "$tmp/t-same.json" "$tmp/t-pub.json"
expect_fail "a new fixable CRITICAL: refused" "CVE-3 in libxml2 (fixed in 9)" td "$tmp/t-new.json" "$tmp/t-pub.json"
expect_ok "clean candidate: pass" \
    "$(printf '  info candidate: 0 fixable CRITICAL, 0 fixable HIGH\n  info 2 fixable HIGH/CRITICAL of the published image fixed by the candidate\n  ok   no fixable CRITICAL the published image does not already have')" \
    td "$tmp/t-clean.json" "$tmp/t-pub.json"
expect_ok "nothing published yet: report only" \
    "$(printf '  info candidate: 2 fixable CRITICAL, 0 fixable HIGH\n  info no published image to compare with: report only')" \
    td "$tmp/t-new.json" ""

echo "--- served-ids.py (post-push check)"
ids() { python3 -I "$ROOT/scripts/served-ids.py" "$@" 2>&1; }
expect_ok "single manifest: top digest + config digest" "$(printf 'sha256:top\nsha256:cfg')" \
    ids sha256:top '{"config": {"digest": "sha256:cfg"}}' linux/amd64
expect_ok "index: asks for our platform's manifest" "need-child sha256:amd" \
    ids sha256:top '{"manifests": [{"digest": "sha256:arm", "platform": {"os": "linux", "architecture": "arm64"}}, {"digest": "sha256:amd", "platform": {"os": "linux", "architecture": "amd64"}}]}' linux/amd64
expect_ok "index + child: top, platform manifest, config" "$(printf 'sha256:top\nsha256:amd\nsha256:cfg')" \
    ids sha256:top '{"manifests": [{"digest": "sha256:amd", "platform": {"os": "linux", "architecture": "amd64"}}]}' linux/amd64 '{"config": {"digest": "sha256:cfg"}}'

echo "--- notify.sh"
expect_ok "no NTFY_TOPIC: skipped, exit 0" "notify: NTFY_TOPIC not set, skipped: t" \
    env -u NTFY_TOPIC "$ROOT/scripts/notify.sh" high warning t m

# A local ntfy stand-in that records each request as JSON lines.
port="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -I - "$port" "$tmp/requests.jsonl" <<'PY' &
import http.server, json, sys
port, log = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
server_pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break; sleep 0.1; done

# env -i: in CI, CI_PIPELINE_URL (and maybe NTFY_TOKEN) are already set and would leak in.
env -i PATH="$PATH" NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=nginx-test NTFY_TOKEN=tk_secret \
    CI_PIPELINE_URL=https://git.example/p/1 "$ROOT/scripts/notify.sh" urgent "rotating_light" "Build failed" "smoke test failed" >/dev/null
env -i PATH="$PATH" NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=nginx-test "$ROOT/scripts/notify.sh" default "" "No token" "plain" >/dev/null
if python3 -I - "$tmp/requests.jsonl" <<'PY'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert len(r) == 2, r
a, b = r
assert a["path"] == "/nginx-test", a
assert a["headers"]["Title"] == "Build failed" and a["headers"]["Priority"] == "urgent", a
assert a["headers"]["Tags"] == "rotating_light" and a["headers"]["Click"] == "https://git.example/p/1", a
assert a["headers"]["Authorization"] == "Bearer tk_secret" and a["body"] == "smoke test failed", a
assert "Authorization" not in b["headers"] and "Click" not in b["headers"] and b["body"] == "plain", b
PY
then pass "topic, title, priority, tags, click URL, bearer token and body sent; no token header without NTFY_TOKEN"
else bad "notify request content"; fi

kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=""
expect_ok "unreachable server: exit 0, error only logged" "" \
    env NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=t "$ROOT/scripts/notify.sh" high x t m

if [ "$FAILED" = 0 ]; then echo "all unit tests passed"; else echo "unit tests FAILED" >&2; exit 1; fi
