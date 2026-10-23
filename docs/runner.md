# Runner for nginx-redirect-docker

nginx-redirect-docker runs on the **same amd64 VM runner** as frankenphp-docker and the other base
images (`base-images-amd64`, shell executor, the VM's own Docker engine). The VM itself (packages,
classic image store, Ubuntu Pro, housekeeping) is described in `../frankenphp-docker/docs/runner.md`.
This file lists only what nginx-redirect-docker adds.

## 1. Outbound access (in addition to the PHP bases' list)

- `nginx.org` (download page: the latest 1.30.x release, for the freshness check)
- `dl-cdn.alpinelinux.org` (`apk upgrade` in the Dockerfile)
- Docker Hub (pulls only): `nginx:1.30-alpine`, `nginx:1.30.5-alpine` (guard test), `aquasec/trivy`
- Disk: negligible (~60 MB images).

## 2. GitLab settings (none are in the repo)

1. Project `silent/nginx-redirect-docker` > Settings > General > Visibility, project features,
   permissions > **CI/CD** on (our GitLab disables it on new projects).
2. The `base-images-amd64` runner > **add the tag `nginx-redirect-amd64`** (keep its other tags, "Run
   untagged jobs" stays off). Then the project > Settings > CI/CD > Runners > Project runners >
   **Enable for this project**.
3. **CI/CD > Variables** (protected, masked where secret):
   - `NTFY_TOPIC`: `gitlab-ci-alert-x564789`, the alerts topic of every project.
   - `NTFY_TOKEN`: ntfy access token, if the server requires one to publish.
   - (No Docker Hub variables: the image is published to our registry only.)
4. **Build > Pipeline schedules > New schedule**: `30 6 * * *`, timezone Europe/Paris, branch
   `master` (after python/node-docker at 06:00; `concurrent = 1` on the VM runs them one after the
   other anyway).
5. **Settings > Packages and registries > Cleanup policies**: **disabled**, as for the other bases.
   The admin script `~/Dropbox/Scripts/clean-registry.sh` cleans the registry: its `KEEP_REGEX` must
   protect the moving tags `1.30-alpine` and `latest` (`.*-alpine` is not in the PHP bases' list).
6. **Settings > Repository > Protected branches**: `master` protected (only maintainers push),
   since a push to `master` publishes the image, and the protected variables are only given to
   protected branches.

## 3. First run

Settings done, push `master`, then Build > Pipelines > **Run pipeline** on `master`. A run takes
2-3 minutes.
