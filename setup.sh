#!/usr/bin/env bash
# ==============================================================================
# Docker Installer + Builder + Docker Hub Pusher (interactive)
# ==============================================================================

set -euo pipefail

# ---- config (defaults; you can override via env or prompts) -------------------
DEFAULT_REPO_URL="https://github.com/graylanquantum/quantum-road-scanner-pqs/"
APP_DIR="${APP_DIR:-$HOME/docker_app_src}"
IMAGE_LOCAL_NAME="${IMAGE_LOCAL_NAME:-app_image}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
LOG_PATH="${LOG_PATH:-$HOME/docker_ship.log}"
DOCKER_REQUIRED_VERSION="${DOCKER_REQUIRED_VERSION:-20.10.0}"

# ------------------------------------------------------------------------------
# pretty prints
# ------------------------------------------------------------------------------
color()   { echo -en "\033[$1m"; }
nocolor() { echo -en "\033[0m"; }
info()    { color 36; echo "[INFO]" "$@"; nocolor; }
warn()    { color 33; echo "[WARN]" "$@"; nocolor; }
error()   { color 31; echo "[ERROR]" "$@"; nocolor; }
ok()      { color 32; echo "[OK]" "$@"; nocolor; }

# tee all output (but we keep the token out of logs by not echoing it)
exec > >(tee -a "$LOG_PATH") 2>&1

trap 'error "An error occurred. See $LOG_PATH for details."; exit 1' ERR

if [[ $EUID -eq 0 ]]; then
  error "Do NOT run this script as root. Use a regular user with sudo."
  exit 2
fi
if ! sudo -v; then
  error "sudo privileges are required."
  exit 2
fi

# ------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------
version_ge() { [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

ensure_docker_installed() {
  info "Checking Docker installation…"
  if ! command -v docker >/dev/null 2>&1 || \
     ! version_ge "$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//')" "$DOCKER_REQUIRED_VERSION"; then
    info "Installing Docker (CE) and plugins…"
    sudo apt-get update -y
    sudo apt-get remove -y docker docker-engine docker.io containerd runc || true
    sudo apt-get install -y ca-certificates curl gnupg lsb-release git
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
       https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable docker
    sudo systemctl start docker
  fi

  if ! docker info >/dev/null 2>&1; then
    # add user to docker group if needed
    if ! id -nG "$USER" | grep -qw docker; then
      warn "Adding $USER to docker group (you may need to log out/in afterwards)."
      sudo usermod -aG docker "$USER"
      warn "Please log out and log back in to refresh group membership, then rerun this script."
      exit 0
    fi
    error "Docker daemon not available. Try: sudo systemctl restart docker"
    exit 1
  fi

  ok "Docker is ready: $(docker --version)"
}

prompt_git_repo() {
  if [[ -z "${GIT_REPO_URL:-}" ]]; then
    echo -n "Git repo URL of Docker image source [${DEFAULT_REPO_URL}]: "
    read -r REPLY_URL
    GIT_REPO_URL="${REPLY_URL:-$DEFAULT_REPO_URL}"
  fi
  ok "Using source repo: $GIT_REPO_URL"
}

clone_repo() {
  rm -rf "$APP_DIR"
  info "Cloning $GIT_REPO_URL into $APP_DIR…"
  git clone "$GIT_REPO_URL" "$APP_DIR"
  ok "Repo cloned."
  if [[ ! -f "$APP_DIR/Dockerfile" ]]; then
    error "No Dockerfile found in repo root ($APP_DIR). Add one or set the correct repo."
    exit 1
  fi
}

derive_image_name_defaults() {
  # default dockerhub repo name from git repo basename
  local base
  base="$(basename -s .git "$GIT_REPO_URL" 2>/dev/null || echo app)"
  # handle trailing slash
  [[ -z "$base" ]] && base="$(basename "$(dirname "$GIT_REPO_URL")")"
  DOCKERHUB_REPO="${DOCKERHUB_REPO:-$base}"
  IMAGE_LOCAL_NAME="${IMAGE_LOCAL_NAME:-$base}"
}

prompt_dockerhub_creds() {
  if [[ -z "${DOCKERHUB_USERNAME:-}" ]]; then
    echo -n "Docker Hub username: "
    read -r DOCKERHUB_USERNAME
  fi
  derive_image_name_defaults
  echo -n "Docker Hub repo (namespace/name) [${DOCKERHUB_USERNAME}/${DOCKERHUB_REPO}]: "
  read -r REPLY_REPO
  if [[ -n "$REPLY_REPO" ]]; then
    if [[ "$REPLY_REPO" == *"/"* ]]; then
      DOCKERHUB_NAMESPACE="${REPLY_REPO%/*}"
      DOCKERHUB_REPO="${REPLY_REPO#*/}"
    else
      DOCKERHUB_NAMESPACE="$DOCKERHUB_USERNAME"
      DOCKERHUB_REPO="$REPLY_REPO"
    fi
  else
    DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-$DOCKERHUB_USERNAME}"
  fi

  if [[ -z "${DOCKERHUB_TOKEN:-}" ]]; then
    # read token silently, do not echo to log
    >&2 echo -n "Docker Hub access token (input hidden): "
    stty -echo
    read -r DOCKERHUB_TOKEN
    stty echo
    >&2 echo
    if [[ -z "$DOCKERHUB_TOKEN" ]]; then
      error "Token cannot be empty."
      exit 1
    fi
  fi

  echo -n "Tag to push [${IMAGE_TAG}]: "
  read -r REPLY_TAG
  IMAGE_TAG="${REPLY_TAG:-$IMAGE_TAG}"

  ok "Target: docker.io/${DOCKERHUB_NAMESPACE}/${DOCKERHUB_REPO}:${IMAGE_TAG}"
}

docker_login() {
  info "Logging in to Docker Hub as ${DOCKERHUB_USERNAME}…"
  if ! echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin; then
    error "Docker Hub login failed."
    exit 1
  fi
  ok "Logged in."
}

build_image() {
  info "Building local image: ${IMAGE_LOCAL_NAME}:${IMAGE_TAG}"
  if docker buildx version >/dev/null 2>&1; then
    docker buildx build --load -t "${IMAGE_LOCAL_NAME}:${IMAGE_TAG}" "$APP_DIR"
  else
    docker build -t "${IMAGE_LOCAL_NAME}:${IMAGE_TAG}" "$APP_DIR"
  fi
  ok "Build complete."
}

tag_and_push() {
  local remote="docker.io/${DOCKERHUB_NAMESPACE}/${DOCKERHUB_REPO}:${IMAGE_TAG}"
  info "Tagging ${IMAGE_LOCAL_NAME}:${IMAGE_TAG} -> ${remote}"
  docker tag "${IMAGE_LOCAL_NAME}:${IMAGE_TAG}" "${remote}"
  info "Pushing ${remote}"
  docker push "${remote}"
  ok "Pushed ${remote}"

  if [[ "$IMAGE_TAG" != "latest" ]]; then
    local latest="docker.io/${DOCKERHUB_NAMESPACE}/${DOCKERHUB_REPO}:latest"
    info "Tagging + pushing ${latest}"
    docker tag "${IMAGE_LOCAL_NAME}:${IMAGE_TAG}" "${latest}"
    docker push "${latest}"
    ok "Pushed ${latest}"
  fi
}

usage() {
  cat <<EOF
Usage:
  $0 install            # install/verify Docker
  $0 build              # prompt for repo, clone, build local image
  $0 push               # prompt for Docker Hub creds, login, tag & push built image
  $0 all                # full flow: install -> clone/build -> login -> push
Env overrides:
  GIT_REPO_URL, APP_DIR, IMAGE_LOCAL_NAME, IMAGE_TAG,
  DOCKERHUB_USERNAME, DOCKERHUB_TOKEN, DOCKERHUB_NAMESPACE, DOCKERHUB_REPO
EOF
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
cmd="${1:-all}"

case "$cmd" in
  install)
    ensure_docker_installed
    ;;
  build)
    ensure_docker_installed
    prompt_git_repo
    clone_repo
    if [[ "$IMAGE_TAG" == "latest" && -d "$APP_DIR/.git" ]]; then
      IMAGE_TAG="$(git -C "$APP_DIR" describe --tags --always --dirty 2>/dev/null || echo latest)"
    fi
    build_image
    ;;
  push)
    ensure_docker_installed
    prompt_dockerhub_creds
    docker_login
    if ! docker image inspect "${IMAGE_LOCAL_NAME}:${IMAGE_TAG}" >/dev/null 2>&1; then
      warn "Local image ${IMAGE_LOCAL_NAME}:${IMAGE_TAG} not found. Trying ${DOCKERHUB_REPO}:${IMAGE_TAG}…"
      IMAGE_LOCAL_NAME="${DOCKERHUB_REPO}"
      if ! docker image inspect "${IMAGE_LOCAL_NAME}:${IMAGE_TAG}" >/dev/null 2>&1; then
        error "No local image tagged ${IMAGE_LOCAL_NAME}:${IMAGE_TAG}. Run '$0 build' first."
        exit 1
      fi
    fi
    tag_and_push
    ;;
  all)
    ensure_docker_installed
    prompt_git_repo
    clone_repo
    if [[ "$IMAGE_TAG" == "latest" && -d "$APP_DIR/.git" ]]; then
      IMAGE_TAG="$(git -C "$APP_DIR" describe --tags --always --dirty 2>/dev/null || echo latest)"
    fi
    build_image
    prompt_dockerhub_creds
    docker_login
    tag_and_push
    ;;
  *)
    usage
    exit 1
    ;;
esac

ok "Done."
