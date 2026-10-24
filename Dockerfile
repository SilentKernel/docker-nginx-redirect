# syntax=docker/dockerfile:1
# nginx-redirect: the official nginx Debian (trixie) image + run.sh/default.conf. Built by build.sh,
# which pins BASE_IMAGE to the digest of nginx:<series>-trixie it just pulled and reads its
# NGINX_VERSION.
ARG BASE_IMAGE=nginx:1.30-trixie
FROM ${BASE_IMAGE}

ARG NGINX_VERSION
ARG MIN_NGINX_VERSION

# Debian security fixes without waiting for the official image to be rebuilt; never cached (build.sh
# builds with --no-cache), tests/os-updates.sh then checks none is left. The official image installs
# nginx from nginx.org and removes nginx.org's apt source afterwards: only Debian's sources
# (/etc/apt/sources.list.d/debian.sources) remain, so this cannot move nginx (Debian's own nginx is
# older, and apt does not downgrade). Should nginx.org's source come back, the version check below
# refuses an nginx other than the one build.sh expects.
RUN set -eu; \
    apt-get update -o APT::Update::Error-Mode=any; \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::=--force-confold; \
    rm -rf /var/lib/apt/lists/*

# Refuse to produce a vulnerable image: the nginx binary must be the version build.sh expects and
# not below the floor (versions.env).
RUN set -eu; \
    test -n "${NGINX_VERSION}" && test -n "${MIN_NGINX_VERSION}"; \
    actual="$(nginx -v 2>&1 | sed -n 's|^nginx version: nginx/||p')"; \
    echo "nginx ${actual} expected=${NGINX_VERSION} required>=${MIN_NGINX_VERSION}"; \
    [ "${actual}" = "${NGINX_VERSION}" ] || { echo "nginx is ${actual}, not ${NGINX_VERSION}" >&2; exit 1; }; \
    lowest="$(printf '%s\n%s\n' "${actual}" "${MIN_NGINX_VERSION}" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"; \
    if [ "${lowest}" != "${MIN_NGINX_VERSION}" ]; then \
        echo "nginx ${actual} is older than ${MIN_NGINX_VERSION}: refusing to build a vulnerable image" >&2; \
        exit 1; \
    fi

COPY run.sh /run.sh
COPY default.conf /etc/nginx/conf.d/default.conf

RUN chmod +x /run.sh

CMD ["/run.sh"]
