#!/bin/bash
# Forward collector helper, installed by Terraform as /usr/local/bin/fwdcollector.
#
#   fwdcollector status        service, container and recent log lines
#   fwdcollector logs [-f]     docker logs for the collector
#   fwdcollector upgrade       pull the image; restart only if it changed
#   fwdcollector restart       restart the collector (also pulls)
#
# Used by systemd:
#   fwdcollector prepare       log in to quay.io, pull, write the env file
#   fwdcollector run           docker run in the foreground
set -euo pipefail

CONF=/etc/fwdcollector/fwdcollector.conf
LOG_DIR=/var/log/fwdcollector
RUN_DIR=/run/fwdcollector
ENV_FILE=$RUN_DIR/collector.env
NAME=fwdcollector
CONTAINER_UID=1000 # user "forward" inside the image

# shellcheck source=/dev/null
. "$CONF"
export AWS_REGION AWS_DEFAULT_REGION=$AWS_REGION

log() { echo "fwdcollector: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

secret_string() {
  aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text
}

pull() {
  local creds user pass
  creds=$(secret_string "$QUAY_SECRET_ARN") || die "cannot read quay.io credentials from $QUAY_SECRET_ARN"
  user=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])' <<<"$creds")
  pass=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])' <<<"$creds")
  # Keep the registry login in RAM only, for the length of the pull.
  local DOCKER_CONFIG rc=0
  DOCKER_CONFIG=$(mktemp -d -p /run fwdcollector-docker.XXXXXX)
  export DOCKER_CONFIG
  printf '%s' "$pass" | docker login quay.io -u "$user" --password-stdin >/dev/null 2>&1 \
    || { rm -rf "$DOCKER_CONFIG"; die "docker login to quay.io failed; check the quay.io credentials"; }
  docker pull --quiet "$IMAGE" >/dev/null || rc=$?
  rm -rf "$DOCKER_CONFIG"
  if [ $rc -ne 0 ]; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 || die "cannot pull $IMAGE and no local copy exists"
    log "WARNING: pull of $IMAGE failed; starting the copy already on disk"
  fi
}

cmd_prepare() {
  install -d -m 700 "$RUN_DIR"
  install -d -m 755 -o "$CONTAINER_UID" -g "$CONTAINER_UID" "$LOG_DIR"

  pull

  local token proxy_password=""
  token=$(secret_string "$TOKEN_SECRET_ARN") || die "cannot read the collector token from $TOKEN_SECRET_ARN"
  [ -n "$token" ] && [ "$token" != "None" ] && [[ "$token" == *:* ]] \
    || die "collector token secret is empty or not username:password; set it with: aws secretsmanager put-secret-value --secret-id $TOKEN_SECRET_ARN --secret-string 'USER:PASSWORD'"
  if [ -n "$PROXY_SECRET_ARN" ]; then
    proxy_password=$(secret_string "$PROXY_SECRET_ARN") || die "cannot read the proxy password"
  fi

  umask 077
  {
    echo "TOKEN=$token"
    echo "COLLECTOR_HEAP_SIZE=$HEAP_GB"
    echo "APP_HOST=$APP_HOST"
    if [ -n "$PROXY_HOST" ]; then
      echo "PROXY_HOST=$PROXY_HOST"
      echo "PROXY_PORT=$PROXY_PORT"
      echo "PROXY_USERNAME=$PROXY_USERNAME"
      echo "PROXY_PASSWORD=$proxy_password"
    fi
  } >"$ENV_FILE"

  docker rm -f "$NAME" >/dev/null 2>&1 || true
}

cmd_run() {
  local args=(
    --name "$NAME"
    --network host
    --env-file "$ENV_FILE"
    --mount "type=bind,src=$LOG_DIR,dst=/collector/logs"
  )
  if [ -n "$LOG_GROUP" ]; then
    args+=(
      --log-driver awslogs
      --log-opt "awslogs-region=$AWS_REGION"
      --log-opt "awslogs-group=$LOG_GROUP"
      --log-opt "awslogs-stream=$INSTANCE_ID"
      --log-opt mode=non-blocking
      --log-opt max-buffer-size=4m
    )
  fi
  exec docker run "${args[@]}" "$IMAGE"
}

running_image() { docker inspect -f '{{.Image}}' "$NAME" 2>/dev/null || true; }

cmd_upgrade() {
  local before after
  before=$(running_image)
  pull
  after=$(docker image inspect -f '{{.Id}}' "$IMAGE")
  if [ "$before" = "$after" ]; then
    log "$IMAGE is current ($after); nothing to do"
    return
  fi
  log "new image $after (was ${before:-none}); restarting"
  systemctl restart fwdcollector.service
  docker image prune -af >/dev/null || true # drop superseded tags too
}

cmd_status() {
  systemctl --no-pager status fwdcollector.service | head -5 || true
  echo
  docker ps -a --filter "name=^${NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  echo
  docker logs --tail 20 "$NAME" 2>&1 || true
}

case "${1:-status}" in
  prepare) cmd_prepare ;;
  run) cmd_run ;;
  upgrade) cmd_upgrade ;;
  restart) systemctl restart fwdcollector.service ;;
  status) cmd_status ;;
  logs) shift; docker logs "$@" "$NAME" ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
