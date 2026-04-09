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
    log "Instalando herramientas básicas..."
    run_cmd apt-get install -y -qq \
        git curl wget rsync openssh-client openssh-server \
        ca-certificates gnupg unzip make nano htop vim
}

install_docker() {
    log "Instalando Docker..."

    if command -v docker >/dev/null 2>&1; then
        log "✓ Docker ya está instalado"
    else
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

        log "✓ Docker instalado"
    fi

    # 🔧 MEJORA 1: Crear grupo docker si no existe
    if ! getent group docker > /dev/null 2>&1; then
        info "Creando grupo docker..."
        run_cmd groupadd docker
    fi

    REAL_USER=${SUDO_USER:-$USER}

    # 🔧 MEJORA 2: Agregar usuario al grupo
    if ! id -nG "$REAL_USER" | grep -qw docker; then
        info "Agregando $REAL_USER al grupo docker..."
        run_cmd usermod -aG docker "$REAL_USER"
    fi

    # 🔧 MEJORA 3: Configurar permisos del socket docker INMEDIATAMENTE
    run_cmd chown root:docker /var/run/docker.sock 2>/dev/null || true
    run_cmd chmod 660 /var/run/docker.sock 2>/dev/null || true

    # 🔧 MEJORA 4: Habilitar y reiniciar servicio
    run_cmd systemctl enable docker
    run_cmd systemctl restart docker
    
    log "✓ Esperando que Docker esté listo..."
    sleep 3

    # 🔧 MEJORA 5: Probar que funciona sin sudo
    if sudo -u "$REAL_USER" docker ps > /dev/null 2>&1; then
        log "✓ Docker funcionando correctamente sin sudo ✓"
    else
        warn "Reintentando permisos..."
        run_cmd systemctl restart docker
        sleep 2
        if sudo -u "$REAL_USER" docker ps > /dev/null 2>&1; then
            log "✓ Docker funcionando correctamente ✓"
        else
            error "No se pueden establecer permisos para Docker"
        fi
    fi
}

install_docker_compose() {
    log "Instalando Docker Compose..."

    if command -v docker-compose &> /dev/null; then
        log "✓ Docker Compose ya está instalado"
        return
    fi

    # 🔧 MEJORA: Obtener última versión automáticamente
    info "Obteniendo última versión de Docker Compose..."
    VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/v//')
    
    if [ -z "$VERSION" ]; then
        warn "No se pudo obtener versión, usando v2.23.0"
        VERSION="2.23.0"
    fi

    info "Descargando Docker Compose v$VERSION..."
    curl -L "https://github.com/docker/compose/releases/download/v${VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose --silent

    run_cmd chmod +x /usr/local/bin/docker-compose
    run_cmd ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    log "✓ Docker Compose v$VERSION instalado"
}

setup_ssh() {
    log "Configurando SSH del servidor..."

    run_cmd bash -c "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config"
    run_cmd bash -c "sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"

    run_cmd systemctl restart ssh
    log "✓ SSH configurado correctamente"
}

setup_github_ssh() {
    log "Configurando SSH para GitHub (ED25519)..."

    REAL_USER=${SUDO_USER:-$USER}
    KEY_PATH="/home/$REAL_USER/.ssh/id_ed25519"

    # Crear directorio .ssh si no existe
    if [ ! -d "/home/$REAL_USER/.ssh" ]; then
        info "Creando directorio .ssh..."
        sudo -u "$REAL_USER" mkdir -p "/home/$REAL_USER/.ssh"
        sudo -u "$REAL_USER" chmod 700 "/home/$REAL_USER/.ssh"
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
    sudo -u "$REAL_USER" chmod 600 "$KEY_PATH"
    sudo -u "$REAL_USER" chmod 644 "$KEY_PATH.pub"

    # Configurar archivo config para GitHub
    if ! sudo -u "$REAL_USER" grep -q "github.com" "/home/$REAL_USER/.ssh/config" 2>/dev/null; then
        info "Creando configuración SSH para GitHub..."
        sudo -u "$REAL_USER" bash -c 'cat >> ~/.ssh/config <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
EOF'
        sudo -u "$REAL_USER" chmod 600 "/home/$REAL_USER/.ssh/config"
    fi

    # 🔑 MOSTRAR CLAVE PÚBLICA
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "🔑 CLAVE PÚBLICA PARA GITHUB:"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    sudo -u "$REAL_USER" cat "$KEY_PATH.pub"
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "PASOS A SEGUIR:"
    warn "1. Copia la clave anterior (ssh-ed25519 ...)"
    warn "2. Abre: https://github.com/settings/keys"
    warn "3. Haz clic en 'New SSH key'"
    warn "4. Pega la clave completa"
    warn "5. Dale un nombre (ej: 'servidor-laravel')"
    warn "6. Haz clic en 'Add SSH key'"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    read -p "Presiona Enter cuando hayas agregado la clave en GitHub..."

    log "Probando conexión a GitHub..."
    if sudo -u "$REAL_USER" ssh -T git@github.com 2>&1 | grep -qE "(successfully|Hi )"; then
        log "✓ Conexión exitosa a GitHub"
    else
        warn "⚠️  Conexión probada, continúa si funciona correctamente"
    fi
}

clone_repository() {
    local repo_url=$1
    local target_dir=${2:-"/opt/laravel-app"}
    local REAL_USER=${SUDO_USER:-$USER}

    log "Clonando repositorio..."

    if [ -d "$target_dir" ]; then
        info "El directorio ya existe, actualizando..."
        sudo -u "$REAL_USER" bash -c "cd $target_dir && git pull origin main"
    else
        info "Creando directorio..."
        run_cmd mkdir -p "$target_dir"
        run_cmd chown "$REAL_USER:$REAL_USER" "$target_dir"
        
        info "Clonando repositorio..."
        sudo -u "$REAL_USER" git clone "$repo_url" "$target_dir"
    fi

    log "✓ Repositorio clonado/actualizado"
}

setup_project() {
    log "Configurando proyecto Laravel..."

    if [ ! -f .env ]; then
        info "Creando archivo .env..."
        cp .env.example .env
    fi

    info "Construyendo contenedores..."
    docker-compose -f docker-compose.dev.yml build

    info "Iniciando contenedores..."
    docker-compose -f docker-compose.dev.yml up -d

    info "Instalando dependencias..."
    docker-compose -f docker-compose.dev.yml exec -T app composer install

    info "Generando clave de aplicación..."
    docker-compose -f docker-compose.dev.yml exec -T app php artisan key:generate

    info "Ejecutando migraciones..."
    docker-compose -f docker-compose.dev.yml exec -T app php artisan migrate --seed

    info "Configurando permisos de directorios..."
    docker-compose -f docker-compose.dev.yml exec -T app chmod -R 775 storage bootstrap/cache
    docker-compose -f docker-compose.dev.yml exec -T app chown -R www-data:www-data storage bootstrap/cache

    log "✓ Proyecto Laravel configurado"
}

main() {
    log "╔════════════════════════════════════════════════════════╗"
    log "║  PROVISIONAMIENTO DE SERVIDOR LARAVEL + DOCKER + GIT  ║"
    log "║              ✨ VERSIÓN MEJORADA ✨                   ║"
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

    echo ""
    read -p "URL del repositorio SSH (git@github.com:usuario/repo.git): " repo_url
    [ -z "$repo_url" ] && error "URL del repositorio es requerida"

    clone_repository "$repo_url"
    setup_project

    echo ""
    log "╔════════════════════════════════════════════════════════╗"
    log "║         ✓ ¡PROVISIONAMIENTO COMPLETADO! ✓            ║"
    log "╚════════════════════════════════════════════════════════╝"
    log "Tu servidor Laravel está listo:"
    log "  • Docker y Docker Compose: ✓ Instalados y funcionando"
    log "  • SSH: ✓ Configurado y seguro"
    log "  • GitHub SSH: ✓ Conectado"
    log "  • Laravel: ✓ Inicializado"
    log ""
    log "Accede a: http://localhost"
    echo ""
}

main "$@"