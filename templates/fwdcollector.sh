#!/bin/bash
# Forward collector helper, installed by Terraform as /usr/local/bin/fwdcollector.
#
#   fwdcollector status        service, container and recent log lines
#   fwdcollector logs [-f]     docker logs for the collector
#   fwdcollector upgrade       pull the image; restart only if it changed
#   fwdcollector restart       restart the collector (also pulls)
#   fwdcollector backup-key    copy customer_key.pb to Secrets Manager (runs on a timer)
#
# Used by systemd:
#   fwdcollector prepare       log in to quay.io, pull, restore the key, write the env file
#   fwdcollector run           docker run in the foreground
set -euo pipefail

CONF=/etc/fwdcollector/fwdcollector.conf
STATE_DIR=/var/lib/fwdcollector
KEY_FILE=$STATE_DIR/customer_key.pb
KEY_MARK=$STATE_DIR/customer_key.sha256
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

# Prints the base64 key backup, nothing if no backup exists yet, and fails on
# any other error so a transient fault never starts the collector without its key.
key_backup_b64() {
  local out
  if out=$(aws secretsmanager get-secret-value --secret-id "$KEY_SECRET_ARN" \
      --query SecretBinary --output text 2>&1); then
    [ "$out" = "None" ] || printf '%s' "$out"
  elif grep -q ResourceNotFoundException <<<"$out"; then
    :
  else
    die "reading the key backup failed: $out"
  fi
}

install_key() { # install_key <file>
  install -D -m 600 -o "$CONTAINER_UID" -g "$CONTAINER_UID" "$1" "$KEY_FILE"
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
  install -d -m 700 "$STATE_DIR"
  install -d -m 700 "$RUN_DIR"
  install -d -m 755 -o "$CONTAINER_UID" -g "$CONTAINER_UID" "$LOG_DIR"

  pull

  if [ ! -s "$KEY_FILE" ]; then
    local b64
    b64=$(key_backup_b64)
    if [ -n "$b64" ]; then
      base64 -d <<<"$b64" >"$RUN_DIR/key.restore"
      install_key "$RUN_DIR/key.restore"
      rm -f "$RUN_DIR/key.restore"
      sha256sum "$KEY_FILE" | cut -d' ' -f1 >"$KEY_MARK" # already backed up
      log "restored customer_key.pb from Secrets Manager"
    else
      log "no encryption key yet; the collector will create one and fwdcollector-key-backup will save it"
    fi
  fi

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
  if [ -s "$KEY_FILE" ]; then
    args+=(--mount "type=bind,src=$KEY_FILE,dst=/collector/private/customer_key.pb")
  fi
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

cmd_backup_key() {
  if [ ! -s "$KEY_FILE" ]; then
    docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true || exit 0
    local tmp=$RUN_DIR/key.capture
    if ! docker cp "$NAME:/collector/private/customer_key.pb" "$tmp" >/dev/null 2>&1 || [ ! -s "$tmp" ]; then
      rm -f "$tmp"
      exit 0 # not generated yet
    fi
    install_key "$tmp"
    rm -f "$tmp"
    log "captured customer_key.pb from the container; it is mounted from the next start"
  fi

  local local_sum
  local_sum=$(sha256sum "$KEY_FILE" | cut -d' ' -f1)
  [ -f "$KEY_MARK" ] && [ "$(cat "$KEY_MARK")" = "$local_sum" ] && exit 0

  local b64
  b64=$(key_backup_b64)
  if [ -z "$b64" ]; then
    aws secretsmanager put-secret-value --secret-id "$KEY_SECRET_ARN" \
      --secret-binary "fileb://$KEY_FILE" >/dev/null
    log "backed up customer_key.pb to Secrets Manager"
  elif [ "$(base64 -d <<<"$b64" | sha256sum | cut -d' ' -f1)" != "$local_sum" ]; then
    die "local customer_key.pb differs from the Secrets Manager backup; not overwriting. Resolve by hand."
  fi
  echo "$local_sum" >"$KEY_MARK"
}

running_image() { docker inspect -f '{{.Image}}' "$NAME" 2>/dev/null || true; }

cmd_upgrade() {
  "$0" backup-key || true
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
  if [ -s "$KEY_FILE" ]; then
    echo "encryption key: present$([ -f "$KEY_MARK" ] && echo ', backed up to Secrets Manager')"
  else
    echo "encryption key: not created yet"
  fi
  echo
  docker logs --tail 20 "$NAME" 2>&1 || true
}

case "${1:-status}" in
  prepare) cmd_prepare ;;
  run) cmd_run ;;
  backup-key) cmd_backup_key ;;
  upgrade) cmd_upgrade ;;
  restart) systemctl restart fwdcollector.service ;;
  status) cmd_status ;;
  logs) shift; docker logs "$@" "$NAME" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
