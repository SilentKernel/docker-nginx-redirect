# syntax=docker/dockerfile:1
# nginx-redirect: the official nginx alpine image + run.sh/default.conf. Built by build.sh, which
# pins BASE_IMAGE to the digest of nginx:<series>-alpine it just pulled and reads its NGINX_VERSION.
ARG BASE_IMAGE=nginx:1.30-alpine
FROM ${BASE_IMAGE}

ARG NGINX_VERSION
ARG MIN_NGINX_VERSION

# Alpine security fixes without waiting for the official image to be rebuilt.
RUN apk upgrade --no-cache

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
