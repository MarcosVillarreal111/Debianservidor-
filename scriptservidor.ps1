#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $1${NC}"; }
info() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"; }

check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        if ! sudo -n true 2>/dev/null; then
            error "Este script requiere sudo"
        fi
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        error "No se pudo detectar el sistema"
    fi
}

run_cmd() {
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

update_system() {
    log "Actualizando sistema..."
    case "$OS" in
        ubuntu|debian)
            run_cmd apt-get update -qq
            run_cmd apt-get upgrade -y -qq
            ;;
        *)
            error "SO no soportado"
            ;;
    esac
}

install_basic_tools() {
    log "Instalando herramientas..."
    run_cmd apt-get install -y -qq \
        git curl wget rsync openssh-client openssh-server \
        ca-certificates gnupg unzip make nano htop vim
}

install_docker() {
    log "Instalando Docker..."

    if command -v docker >/dev/null 2>&1; then
        warn "Docker ya instalado"
        return
    fi

    run_cmd apt-get update -qq
    run_cmd apt-get install -y -qq ca-certificates curl gnupg

    run_cmd install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/$OS/gpg | \
        run_cmd gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    run_cmd chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
        run_cmd tee /etc/apt/sources.list.d/docker.list > /dev/null

    run_cmd apt-get update -qq

    run_cmd apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    REAL_USER=${SUDO_USER:-$USER}
    run_cmd usermod -aG docker "$REAL_USER"

    run_cmd systemctl enable docker
    run_cmd systemctl start docker

    log "Docker instalado"
    warn "Ejecuta: newgrp docker"
}

install_docker_compose() {
    log "Instalando Docker Compose..."

    if command -v docker-compose &> /dev/null; then
        warn "Docker Compose ya existe"
        return
    fi

    curl -L "https://github.com/docker/compose/releases/download/v2.23.0/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose --silent

    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
}

setup_ssh() {
    log "Configurando SSH..."

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

    systemctl restart ssh
}

# 🔥 MODIFICADO A ED25519
setup_github_ssh() {
    log "Configurando SSH para GitHub (ED25519)..."

    KEY_PATH="$HOME/.ssh/id_ed25519"

    if [ ! -f "$KEY_PATH" ]; then
        info "Generando clave ED25519..."
        ssh-keygen -t ed25519 -C "devops@laravel-docker" -N "" -f "$KEY_PATH"
    else
        warn "Clave ED25519 ya existe"
    fi

    chmod 600 "$KEY_PATH"
    chmod 644 "$KEY_PATH.pub"

    # Iniciar agente SSH
    eval "$(ssh-agent -s)" >/dev/null
    ssh-add "$KEY_PATH"

    # Config opcional para GitHub
    if ! grep -q "github.com" ~/.ssh/config 2>/dev/null; then
        cat >> ~/.ssh/config <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
EOF
    fi

    log "Agrega esta clave a GitHub:"
    echo -e "${YELLOW}"
    cat "$KEY_PATH.pub"
    echo -e "${NC}"

    read -p "Presiona Enter después de agregarla..."

    log "Probando conexión..."
    ssh -T git@github.com || true
}

clone_repository() {
    local repo_url=$1
    local target_dir=${2:-"/opt/laravel-app"}

    log "Clonando repo..."

    if [ -d "$target_dir" ]; then
        cd "$target_dir"
        git pull origin main
    else
        mkdir -p "$target_dir"
        chown $USER:$USER "$target_dir"
        git clone "$repo_url" "$target_dir"
        cd "$target_dir"
    fi
}

setup_project() {
    log "Configurando Laravel..."

    [ ! -f .env ] && cp .env.example .env

    docker-compose -f docker-compose.dev.yml build
    docker-compose -f docker-compose.dev.yml up -d

    docker-compose -f docker-compose.dev.yml exec app composer install
    docker-compose -f docker-compose.dev.yml exec app php artisan key:generate
    docker-compose -f docker-compose.dev.yml exec app php artisan migrate --seed

    docker-compose -f docker-compose.dev.yml exec app chmod -R 775 storage bootstrap/cache
    docker-compose -f docker-compose.dev.yml exec app chown -R www-data:www-data storage bootstrap/cache
}

main() {
    log "Iniciando provisionamiento"

    check_sudo
    detect_os
    update_system
    install_basic_tools
    install_docker
    install_docker_compose
    setup_ssh
    setup_github_ssh

    read -p "Repo SSH (git@github.com:user/repo.git): " repo_url
    [ -z "$repo_url" ] && error "Repo requerida"

    clone_repository "$repo_url"
    setup_project

    log "Listo"
    echo "http://localhost"
}

main "$@"