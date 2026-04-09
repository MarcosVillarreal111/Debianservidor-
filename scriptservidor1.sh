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
    
    # Mejora: Verificar si usermod existe
    if command -v usermod >/dev/null 2>&1; then
        run_cmd usermod -aG docker "$REAL_USER"
        log "Usuario $REAL_USER agregado al grupo docker"
    else
        warn "usermod no disponible, usa: sudo usermod -aG docker $REAL_USER"
    fi

    run_cmd systemctl enable docker
    run_cmd systemctl start docker

    log "Docker instalado"
    warn "⚠️  Ejecuta: newgrp docker o cierra sesión y vuelve a entrar"
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
    
    log "Docker Compose instalado"
}

setup_ssh() {
    log "Configurando SSH del servidor..."

    # Con sudo para /etc/ssh/sshd_config
    run_cmd bash -c "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config"
    run_cmd bash -c "sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"

    run_cmd systemctl restart ssh
    log "SSH configurado"
}

# 🔥 MEJORADO: Clave SSH para GitHub con mejor manejo
setup_github_ssh() {
    log "Configurando SSH para GitHub (ED25519)..."

    REAL_USER=${SUDO_USER:-$USER}
    KEY_PATH="/home/$REAL_USER/.ssh/id_ed25519"

    # Crear directorio si no existe
    if [ ! -d "/home/$REAL_USER/.ssh" ]; then
        info "Creando directorio .ssh..."
        mkdir -p "/home/$REAL_USER/.ssh"
        chmod 700 "/home/$REAL_USER/.ssh"
    fi

    # Generar clave SI NO EXISTE
    if [ ! -f "$KEY_PATH" ]; then
        info "Generando nueva clave ED25519..."
        sudo -u "$REAL_USER" ssh-keygen -t ed25519 -C "devops@laravel-docker" -N "" -f "$KEY_PATH"
        info "✓ Clave generada"
    else
        info "✓ Clave ED25519 ya existe"
    fi

    # Permisos correctos
    chmod 600 "$KEY_PATH"
    chmod 644 "$KEY_PATH.pub"
    chown "$REAL_USER:$REAL_USER" "$KEY_PATH" "$KEY_PATH.pub"

    # Iniciar agente SSH (como usuario real, no root)
    info "Inicializando agente SSH..."
    sudo -u "$REAL_USER" bash -c 'eval "$(ssh-agent -s)" > /dev/null 2>&1 && ssh-add ~/.ssh/id_ed25519 > /dev/null 2>&1' || true

    # Config para GitHub (como usuario real)
    if ! sudo -u "$REAL_USER" grep -q "github.com" ~/.ssh/config 2>/dev/null; then
        sudo -u "$REAL_USER" bash -c 'mkdir -p ~/.ssh && cat >> ~/.ssh/config <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
EOF'
    fi

    # 🔑 MOSTRAR LA CLAVE PÚBLICA DE FORMA CLARA
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "CLAVE PÚBLICA PARA GITHUB:"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    cat "$KEY_PATH.pub"
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "PASOS:"
    warn "1. Copia la clave anterior"
    warn "2. Ve a: https://github.com/settings/keys"
    warn "3. Click en 'New SSH key'"
    warn "4. Pega la clave y guarda"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    read -p "Presiona Enter cuando hayas agregado la clave en GitHub..."

    log "Probando conexión a GitHub..."
    if sudo -u "$REAL_USER" ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        log "✓ Conexión exitosa a GitHub"
    else
        warn "⚠️  No se pudo verificar conexión, pero la clave está lista"
    fi
}

clone_repository() {
    local repo_url=$1
    local target_dir=${2:-"/opt/laravel-app"}
    local REAL_USER=${SUDO_USER:-$USER}

    log "Clonando repositorio..."

    if [ -d "$target_dir" ]; then
        cd "$target_dir"
        git pull origin main
    else
        mkdir -p "$target_dir"
        run_cmd chown "$REAL_USER:$REAL_USER" "$target_dir"
        sudo -u "$REAL_USER" git clone "$repo_url" "$target_dir"
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
    log "╔════════════════════════════════════════════════════════╗"
    log "║  PROVISIONAMIENTO DE SERVIDOR LARAVEL + DOCKER + GIT  ║"
    log "╚════════════════════════════════════════════════════════╝"
    echo ""

    check_sudo
    detect_os
    info "Sistema detectado: $OS $OS_VERSION"
    
    update_system
    install_basic_tools
    install_docker
    install_docker_compose
    setup_ssh
    setup_github_ssh

    read -p "URL del repositorio SSH (git@github.com:user/repo.git): " repo_url
    [ -z "$repo_url" ] && error "URL del repositorio es requerida"

    clone_repository "$repo_url"
    setup_project

    echo ""
    log "╔════════════════════════════════════════════════════════╗"
    log "║         ✓ PROVISIONAMIENTO COMPLETADO                  ║"
    log "╚════════════════════════════════════════════════════════╝"
    log "Accede a: http://localhost"
}

main "$@"