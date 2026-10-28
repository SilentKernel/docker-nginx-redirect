# docker-nginx-redirect

A very simple container to redirect HTTP traffic to another server, based on `nginx`

## Resources

- Image: `registry.developpeur-freelance.io/silent/nginx-redirect-docker` (our GitLab registry; `docker login registry.developpeur-freelance.io` with a
  deploy token that has `read_registry`). It is no longer published on Docker Hub.

## Configuration

### Environment variables

- `SERVER_REDIRECT` - server to redirect to, eg. `www.example.com`
- `SERVER_NAME` - optionally define the server name to listen on eg. `~^www.(?<subdomain>.+).example.com`
   - useful for capturing variable to use in server_redirect. 
- `SERVER_REDIRECT_PATH` - optionally define path to redirect all requests eg. `/landingpage`
   - if not set nginx var `$request_uri` is used
- `SERVER_REDIRECT_SCHEME` - optionally define scheme to redirect to 
   - if not set but X-Forwarded-Proto is send as request header with value 'https' this will be used. 
     In all other cases nginx var `$scheme` is used
- `SERVER_REDIRECT_CODE` - optionally define the http status code to use for redirection
   - if not set or not in list of allowed codes 301 is used as default
   - allowed Codes are: 301, 302, 303, 307, 308
 - `SERVER_REDIRECT_POST_CODE` - optionally define the http code to use for POST redirection
    - useful if client should not change the request method from POST to GET
    - if not set or not in allowed Codes `SERVER_REDIRECT_CODE` is used
    - so per default all requests will be redirected with the same status code
 - `SERVER_REDIRECT_PUT_PATCH_DELETE_CODE` - optionally define the http code to use for PUT, PATCH and DELETE redirection
    - useful if client should not change the request method from PUT, PATCH and DELETE to GET
    - if not set or not in allowed Codes `SERVER_REDIRECT_CODE` is used
    - so per default all requests will be redirected with the same status code
- `SERVER_ACCESS_LOG` - optionally define the location where nginx will write its access log
   - if not set /dev/stdout is used
- `SERVER_ERROR_LOG` - optionally define the location where nginx will write its error log
   - if not set /dev/stderr is used

See also `docker-compose.yml` file.

## Usage

With `docker-compose`

    docker-compose up -d
    
With `docker`    

    docker run -e SERVER_REDIRECT=www.example.com -p 8888:80 registry.developpeur-freelance.io/silent/nginx-redirect-docker
    docker run -e SERVER_REDIRECT=www.example.com -e SERVER_REDIRECT_PATH=/landingpage -p 8888:80 registry.developpeur-freelance.io/silent/nginx-redirect-docker
    docker run -e SERVER_REDIRECT=www.example.com -e SERVER_REDIRECT_PATH=/landingpage -e SERVER_REDIRECT_SCHEME=https -p 8888:80 registry.developpeur-freelance.io/silent/nginx-redirect-docker

## Healthcheck

The image has a `HEALTHCHECK`: healthy while nginx answers on `http://127.0.0.1/` (the redirect
itself counts), checked every second for the first 30 s, then every 10 s; unhealthy after 3 failures
in a row. While `/tmp/drain` exists it reports unhealthy on purpose, so that
`docker rollout --pre-stop-hook "touch /tmp/drain && sleep 35"` can take the old container out of
the proxy before stopping it. `docker ps` shows `(healthy)`. `tests/smoke.sh` checks the exact
configuration and its behaviour; `tests/negative.sh` proves a missing or broken healthcheck is refused.

## Nightly build (GitLab CI)

Rebuilt **every night** by GitLab CI (`.gitlab-ci.yml`, runner setup in
[`docs/runner.md`](docs/runner.md)) on the official Debian variant `nginx:1.30-trixie` (nginx.org's
signed packages, same base as `../nginx-s3-gateway-docker`), pulled fresh and pinned by digest, plus
`apt-get upgrade` for Debian security fixes. Every nginx 1.30.x fix reaches the moving tags without
editing this repo.

| Tag | Use |
|---|---|
| `1.30-trixie`, `latest` | moving — what deployments pull |
| `1.30.6-trixie` | latest build of that exact nginx |
| `1.30.6-trixie-YYYYMMDD` | never overwritten — for rollbacks |

The image used to be built on `nginx:1.30-alpine`: the `1.30-alpine`, `1.30.x-alpine` and
`1.30.x-alpine-YYYYMMDD` tags are no longer pushed, and the registry cleanup removes them. Move
deployments pinned to `1.30-alpine` to `1.30-trixie` (or `latest`). The entrypoint
now runs under Debian's `/bin/sh` (dash) with GNU coreutils instead of busybox; the environment
variables behave the same (`tests/smoke.sh`).

Published to `registry.developpeur-freelance.io/silent/nginx-redirect-docker` only (the Docker Hub
copy `silentk/nginx-redirect` is gone).

```bash
./build.sh                               # build + every gate, nothing pushed
./build.sh --push                        # same + push the four tags (clean git tree)
NGINX_BASE_TAG=1.30.6-trixie ./build.sh  # on a given official tag (rollback, reproduction)
```

`versions.env` holds the series (`NGINX_SERIES=1.30`), the security floor `MIN_NGINX_VERSION`, the
platform and the registry. Gates, in order (any failure: nothing pushed):

1. The official image ships a `1.30.x` nginx; the Dockerfile refuses a binary below
   `MIN_NGINX_VERSION` or different from the announced version.
2. With `--push`: never older than what `1.30-trixie` serves (its labels).
3. If nginx.org has a newer 1.30.x than the official image: ntfy alert, built anyway (Debian fixes).
4. `tests/smoke.sh`: every environment variable above, over HTTP (codes per method, invalid codes,
   path, scheme, `X-Forwarded-Proto`, `SERVER_NAME` capture, logs, missing `SERVER_REDIRECT`).
5. `tests/os-updates.sh` (shared with the other Debian bases, e.g. `../python-docker`): `apt-get
   update` in the candidate, and no update from Debian's archive (trixie, trixie-updates,
   trixie-security) may be pending; what only `dist-upgrade` would do is a warning.
6. `tests/negative.sh`: broken variants of the candidate are rejected by the smoke test, and an old
   trixie snapshot (`debian:trixie-20250811`, pinned by digest) by `tests/os-updates.sh`, which
   accepts the candidate.
7. `tests/scan.sh`: Trivy, pinned by digest; refuses a fixable CRITICAL the published image does not
   already have.
8. Push from the tested image, moving tags last; the registry must then serve exactly that image.

Offline tests: `tests/unit.sh` (scripts, and `tests/os-updates.sh` on captured apt outputs in
`tests/fixtures/apt/`) and `tests/guard.sh` (the floor refuses `nginx:1.30.5-trixie`).

On an nginx security release: nothing to do for the image (the next nightly, or "Run pipeline" on
`master`, picks it up once the official image ships it); raise `MIN_NGINX_VERSION` so nothing older
can be built. A new stable series (1.32) is never picked up automatically: change `NGINX_SERIES`.

---

Built by [dmstr](http://diemeisterei.de)
