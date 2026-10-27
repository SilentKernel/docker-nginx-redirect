#!/usr/bin/env bash
# Builds the nginx-redirect image (IMAGE in versions.env) for production (amd64), tests it, and
# pushes it to our registry only with --push (no Docker Hub copy).
#
#   ./build.sh            build + test
#   ./build.sh --push     build + test + push the four tags
#   NGINX_BASE_TAG=1.30.6-trixie ./build.sh   build on a given official tag (rollback, reproduction)
#
# The image starts FROM the official nginx:<series>-trixie (Debian, nginx.org's signed packages),
# pulled fresh and pinned by digest, then `apt-get upgrade` for Debian fixes. The Dockerfile refuses
# an nginx below MIN_NGINX_VERSION; --push refuses to publish an nginx older than the moving tag
# serves. An official image lagging behind nginx.org's latest <series>.x is reported (ntfy), not
# blocked: the Debian fixes still ship, the next night picks up the new nginx.
#
# Tags: <nginx>-trixie-YYYYMMDD (never overwritten, for rollbacks), <nginx>-trixie (latest build of
# that version), <series>-trixie and latest (moving, what deployments use). The former -alpine tags
# are no longer pushed, and the registry cleanup removes them.
#
# Before anything is pushed, the candidate must pass tests/smoke.sh (the redirect behaviour over
# HTTP), tests/os-updates.sh (no Debian update pending) and tests/negative.sh (the gates still catch
# broken images); tests/scan.sh refuses a new fixable CRITICAL CVE. The candidate lives under a private local name until the push: another build
# on the same Docker engine pulling the public tags cannot swap it, and after the push the registry
# must serve exactly the tested image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PUSH=0
for arg in "$@"; do
    case "$arg" in
        --push) PUSH=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

set -a
# shellcheck source=versions.env
. ./versions.env
set +a

if [ "$PUSH" = 1 ] && [ -d .git ] && [ -n "$(git status --porcelain)" ]; then
    echo "refusing to push from a dirty working tree: the pushed image would match no commit" >&2
    exit 1
fi
SOURCE_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo none)"

echo "==> resolving the latest nginx ${NGINX_SERIES}.x on nginx.org"
resolved="$("$ROOT/scripts/resolve-versions.sh")"
eval "$resolved"
echo "    nginx.org: ${NGINX_LATEST}"

# The official image: its digest (what we build FROM) and the nginx version it ships.
BASE_TAG="nginx:${NGINX_BASE_TAG:-${NGINX_SERIES}-trixie}"
echo "==> reading ${BASE_TAG}"
read -r BASE_DIGEST NGINX_VERSION < <(docker buildx imagetools inspect "$BASE_TAG" --format '{{json .}}' | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
image = d.get("image") or {}
if "config" not in image:   # multi-platform index: one entry per platform
    image = image[sys.argv[1]]
env = dict(e.split("=", 1) for e in image.get("config", {}).get("Env") or [])
print(d["manifest"]["digest"], env.get("NGINX_VERSION", "-"))
' "$PLATFORM") || { echo "cannot read ${BASE_TAG}" >&2; exit 1; }
[[ "$NGINX_VERSION" =~ ^${NGINX_SERIES//./\\.}\.[0-9]+$ ]] \
    || { echo "${BASE_TAG} ships nginx '${NGINX_VERSION}', not a ${NGINX_SERIES}.x release" >&2; exit 1; }
BASE_IMAGE="nginx@${BASE_DIGEST}"
echo "    ${BASE_TAG} = ${BASE_IMAGE}: nginx ${NGINX_VERSION}"
export NGINX_VERSION

TAG_VERSION="${IMAGE}:${NGINX_VERSION}-trixie"
DATE="$(date -u +%Y%m%d)"
TAG_DATED="${TAG_VERSION}-${DATE}"
TAG_MOVING="${IMAGE}:${NGINX_SERIES}-trixie"
TAG_LATEST="${IMAGE}:latest"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CANDIDATE="nginx-redirect-candidate:$(date -u +%Y%m%d%H%M%S)-$$"
trap 'docker image rm "$CANDIDATE" >/dev/null 2>&1 || true' EXIT

# What the moving tag serves today: "<nginx> <manifest digest>" from its labels, or "- -" if it was
# never pushed.
published_info() {
    local out
    if ! out="$(docker buildx imagetools inspect "$TAG_MOVING" --format '{{json .}}' 2>&1)"; then
        case "$out" in
            *"not found"*|*"NOT_FOUND"*|*"MANIFEST_UNKNOWN"*) echo "- -"; return 0 ;;
            *) echo "cannot read ${TAG_MOVING}: ${out}" >&2; return 1 ;;
        esac
    fi
    python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
image = d.get("image") or {}
if "config" not in image:   # multi-platform index: one entry per platform
    image = image.get(sys.argv[2]) or next(iter(image.values()))
labels = image.get("config", {}).get("Labels") or {}
print(labels.get("dev.nginx-redirect.nginx-version") or "-", d.get("manifest", {}).get("digest") or "-")
' "$out" "$PLATFORM"
}

PUBLISHED_NGINX="" PUBLISHED_DIGEST=""
if read -r PUBLISHED_NGINX PUBLISHED_DIGEST < <(published_info); then
    [ "$PUBLISHED_NGINX" = - ] && PUBLISHED_NGINX=""
    [ "$PUBLISHED_DIGEST" = - ] && PUBLISHED_DIGEST=""
    echo "==> ${TAG_MOVING} serves nginx ${PUBLISHED_NGINX:-none}"
elif [ "$PUSH" = 1 ]; then
    echo "cannot read the published version" >&2
    exit 1
else
    echo "==> cannot read ${TAG_MOVING} (not logged in?): no comparison with the published image"
fi
if [ "$PUSH" = 1 ]; then
    "$ROOT/scripts/version-compare.sh" "$PUBLISHED_NGINX" "$NGINX_VERSION" \
        || { echo "refusing to push nginx ${NGINX_VERSION}: ${TAG_MOVING} already serves ${PUBLISHED_NGINX}" >&2; exit 1; }
fi

if ! "$ROOT/scripts/version-compare.sh" "$NGINX_LATEST" "$NGINX_VERSION"; then
    echo "==> WARNING: ${BASE_TAG} ships nginx ${NGINX_VERSION}, nginx.org has ${NGINX_LATEST}"
    "$ROOT/scripts/notify.sh" high "warning,hourglass" \
        "nginx-redirect-docker: official image lags (nginx ${NGINX_VERSION} < ${NGINX_LATEST})" \
        "${BASE_TAG} still ships nginx ${NGINX_VERSION}; nginx.org released ${NGINX_LATEST}. Built anyway (Debian fixes). If ${NGINX_LATEST} is a security release, raise MIN_NGINX_VERSION to stop publishing older builds."
fi

echo "==> building on ${BASE_IMAGE} (nginx ${NGINX_VERSION}, floor ${MIN_NGINX_VERSION}), ${PLATFORM}"
# --pull refreshes the base; --no-cache so `apt-get upgrade` really fetches tonight's Debian fixes;
# --load puts the result in the local engine for the tests.
docker buildx build --pull --no-cache --load \
    --platform "$PLATFORM" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg NGINX_VERSION="$NGINX_VERSION" \
    --build-arg MIN_NGINX_VERSION="$MIN_NGINX_VERSION" \
    --label org.opencontainers.image.title=nginx-redirect \
    --label "org.opencontainers.image.description=HTTP redirect container on nginx ${NGINX_VERSION} (official trixie image + apt-get upgrade)" \
    --label "org.opencontainers.image.version=${NGINX_VERSION}-trixie" \
    --label "org.opencontainers.image.revision=${SOURCE_COMMIT}" \
    --label "org.opencontainers.image.created=${BUILD_DATE}" \
    --label "org.opencontainers.image.base.name=docker.io/library/${BASE_TAG}" \
    --label "org.opencontainers.image.base.digest=${BASE_DIGEST}" \
    --label "dev.nginx-redirect.nginx-version=${NGINX_VERSION}" \
    -t "$CANDIDATE" .

CANDIDATE_ID="$(docker image inspect -f '{{.Id}}' "$CANDIDATE")"
echo "==> candidate ${CANDIDATE} (${CANDIDATE_ID})"

echo "==> smoke test (redirect behaviour over HTTP)"
"$ROOT/tests/smoke.sh" "$CANDIDATE"
echo "==> Debian updates (none may be pending)"
"$ROOT/tests/os-updates.sh" "$CANDIDATE"
echo "==> negative tests (the gates catch broken images)"
"$ROOT/tests/negative.sh" "$CANDIDATE"
echo "==> vulnerability gate (no new fixable CRITICAL against the published image)"
"$ROOT/tests/scan.sh" "$CANDIDATE" ${PUBLISHED_DIGEST:+"${IMAGE}@${PUBLISHED_DIGEST}"}

# Every identifier of the image the registry serves for <tag> (index, platform manifest, config):
# the tested image ID must be one of them, whatever image store the local engine uses.
served_ids() {
    local tag="$1" top raw out child
    # {{json .Manifest}}, never {{.Manifest.Digest}}: older buildx versions print their
    # human-readable block for any format starting with {{.Manifest (served-ids.py --digest reads both)
    top="$(docker buildx imagetools inspect "$tag" --format '{{json .Manifest}}' | python3 -I "$ROOT/scripts/served-ids.py" --digest)" || return 1
    raw="$(docker buildx imagetools inspect "$tag" --raw)" || return 1
    out="$(python3 -I "$ROOT/scripts/served-ids.py" "$top" "$raw" "$PLATFORM")" || return 1
    if [[ "$out" == need-child\ * ]]; then
        child="$(docker buildx imagetools inspect "${tag%:*}@${out#need-child }" --raw)" || return 1
        out="$(python3 -I "$ROOT/scripts/served-ids.py" "$top" "$raw" "$PLATFORM" "$child")" || return 1
    fi
    printf '%s\n' "$out"
}

# Pushes <tag> from the tested image, then checks the registry serves exactly that image.
push_tested() {
    local tag="$1" ids
    docker tag "$CANDIDATE_ID" "$tag"
    docker push "$tag"
    ids="$(served_ids "$tag")" || { echo "cannot read ${tag} back from the registry" >&2; exit 1; }
    if ! grep -qxF "$CANDIDATE_ID" <<<"$ids"; then
        echo "registry serves $(tr '\n' ' ' <<<"$ids")for ${tag}, not the tested image ${CANDIDATE_ID}" >&2
        exit 1
    fi
    echo "ok   ${tag} is the tested image (${CANDIDATE_ID})"
}

if [ "$PUSH" = 1 ]; then
    echo "==> pushing ${TAG_DATED}, ${TAG_VERSION}, ${TAG_MOVING} and ${TAG_LATEST} (moving tags last)"
    push_tested "$TAG_DATED"
    push_tested "$TAG_VERSION"
    push_tested "$TAG_MOVING"
    push_tested "$TAG_LATEST"
    if [ "$PUBLISHED_NGINX" != "$NGINX_VERSION" ]; then
        "$ROOT/scripts/notify.sh" default "package,arrow_up" \
            "nginx-redirect: nginx ${NGINX_VERSION}" \
            "${TAG_MOVING} moved from nginx ${PUBLISHED_NGINX:-none} to ${NGINX_VERSION}. Redeploy the redirect containers to pick it up."
    fi
else
    docker tag "$CANDIDATE_ID" "$TAG_VERSION"
    docker tag "$CANDIDATE_ID" "$TAG_MOVING"
    echo "==> not pushed (run with --push); tagged locally: ${TAG_VERSION}, ${TAG_MOVING}"
fi
