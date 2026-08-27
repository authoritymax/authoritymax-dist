#!/usr/bin/env bash

# Deploy the current main revision. Installed as /usr/local/bin/deploy-main, which is the exact
# command CI's deploy-production job runs over SSH — the SSH key needs no shell access beyond it.
#
# Fast-forward only, and never on a dirty tree: a deploy must reproduce a commit that exists on the
# remote, not whatever happens to be sitting on the box.
#
# Works from either checkout: the private source repository, which builds the images, or the public
# distribution repository, which has no application source and deploys the published ones.

set -Eeuo pipefail

DEPLOY_DIR="${AUTHORITYMAX_DEPLOY_DIR:-/srv/authoritymax}"
COMPOSE_FILE="infra/compose/docker-compose.prod.yml"

cd "${DEPLOY_DIR}"

if command -v flock >/dev/null 2>&1; then
  exec 9>"${TMPDIR:-/tmp}/authoritymax-deploy.lock"
  if ! flock -n 9; then
    echo "Another deploy is already running" >&2
    exit 1
  fi
fi

# SOURCE_COMMIT is written only by the sync into the distribution repository, which carries the
# operator files but no application source.
if [[ -f SOURCE_COMMIT ]]; then
  IS_DIST=1
else
  IS_DIST=0
fi

# A distribution checkout is a working directory: .env, data/, and logs live beside the tracked
# files. Its .gitignore covers the expected ones, but an operator's own files must not block a
# deploy either, so only tracked changes count there. A source checkout stays strict — untracked
# files enter the Docker build context and would change what gets built.
status_args=(--porcelain)
if [[ "${IS_DIST}" -eq 1 ]]; then
  status_args+=(--untracked-files=no)
fi
if [[ -n "$(git status "${status_args[@]}")" ]]; then
  echo "Refusing to deploy: ${DEPLOY_DIR} has uncommitted changes to tracked files" >&2
  exit 1
fi

git pull --ff-only

if [[ ! -f .env ]]; then
  echo "Refusing to deploy: ${DEPLOY_DIR}/.env is missing" >&2
  exit 1
fi

# Read a value without sourcing .env — that file is data, not shell. Last assignment wins, the
# same way the file's readers treat it.
env_value() {
  local value
  value="$(sed -n "s/^$1=//p" .env | tail -n 1)"
  value="${value%$'\r'}"
  printf '%s' "${value//[\"\' 	]/}"
}

host="$(env_value AUTHORITYMAX_HOST)"
if [[ ! "${host}" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Refusing to deploy: set AUTHORITYMAX_HOST to the public hostname in ${DEPLOY_DIR}/.env" >&2
  exit 1
fi

GIT_SHA="$(git rev-parse HEAD)"
export GIT_SHA

compose=(docker compose --env-file .env -f "${COMPOSE_FILE}")

# A distribution checkout has no application source to build from, so it deploys the published
# images. A source checkout builds as before.
if [[ "${IS_DIST}" -eq 0 ]]; then
  # --pull missing keeps the deploy on the images just built while still fetching the ones nothing
  # builds: postgres and caddy are digest-pinned upstream images, and --pull never fails a first
  # deployment on them. --wait fails the deploy when a service never reaches a healthy state.
  "${compose[@]}" up -d --wait --pull missing --build api worker web
else
  tag="$(env_value AUTHORITYMAX_IMAGE_TAG)"
  if [[ -z "${tag}" || "${tag}" == "local" ]]; then
    echo "Refusing to deploy: AUTHORITYMAX_IMAGE_TAG=${tag:-<unset>} has no published image." >&2
    echo "Set AUTHORITYMAX_IMAGE_TAG=latest (or a release tag) in ${DEPLOY_DIR}/.env." >&2
    exit 1
  fi
  "${compose[@]}" pull api worker web
  "${compose[@]}" up -d --wait --pull missing api worker web
fi

curl --fail --silent --show-error --max-time 30 "https://${host}/health"
echo
echo "Deployed ${GIT_SHA} to https://${host}"
