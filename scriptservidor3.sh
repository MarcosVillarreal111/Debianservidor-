#!/bin/bash

################################################################################
# SCRIPT DE PROVISIONAMIENTO - LARAVEL + DOCKER + GIT
# Optimizado para: Debian 11, 12 / Ubuntu 20.04, 22.04, 24.04
# Autor: DevOps Team
# Versión: 2.0 - ESTABLE
################################################################################

set -e

# ════════════════════════════════════════════════════════════════════════════
# COLORES Y FUNCIONES DE LOG
# ════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { 
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" 
}

error() { 
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
    exit 1 
}

warn() { 
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $1${NC}" 
}

info() { 
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" 
}

success() { 
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $1${NC}" 
}

# ════════════════════════════════════════════════════════════════════════════
# VALIDACIONES INICIALES
# ════════════════════════════════════════════════════════════════════════════

check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        error "Este script debe ejecutarse como root (sudo)"
    fi
}

detect_os() {
    if [ ! -f /etc/os-release ]; then
        error "No se pudo detectar el sistema operativo"
    fi
    
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
    OS_NAME=$PRETTY_NAME
    
    case "$OS" in
        debian|ubuntu)
            log "Sistema detectado: $OS_NAME"
            ;;
        *)
            error "Este script solo soporta Debian/Ubuntu. Detectado: $OS"
            ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 1: ACTUALIZAR SISTEMA
# ════════════════════════════════════════════════════════════════════════════

update_system() {
    log "════════════════════════════════════════════════════════"
    log "PASO 1: Actualizando sistema..."
    log "════════════════════════════════════════════════════════"
    
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    
    success "Sistema actualizado"
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 2: INSTALAR HERRAMIENTAS BÁSICAS
# ════════════════════════════════════════════════════════════════════════════

install_basic_tools() {
    log "════════════════════════════════════════════════════════"
    log "PASO 2: Instalando herramientas básicas..."
    log "════════════════════════════════════════════════════════"
    
    local PACKAGES="git curl wget rsync openssh-client openssh-server"
    PACKAGES="$PACKAGES ca-certificates gnupg unzip make nano htop vim"
    PACKAGES="$PACKAGES shadow-utils sudo lsb-release"
    
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PACKAGES
    
    success "Herramientas instaladas"
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 3: INSTALAR DOCKER
# ════════════════════════════════════════════════════════════════════════════

install_docker() {
    log "════════════════════════════════════════════════════════"
    log "PASO 3: Instalando Docker..."
    log "════════════════════════════════════════════════════════"
    
    # Verificar si Docker ya existe
    if command -v docker &> /dev/null; then
        success "Docker ya está instalado: $(docker --version)"
        return 0
    fi
    
    info "Descargando repositorio oficial de Docker..."
    apt-get update -qq
    
    # Instalar dependencias
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl gnupg lsb-release
    
    # Agregar clave GPG de Docker
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$OS/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Agregar repositorio
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Instalar Docker
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    
    # Crear grupo docker si no existe
    if ! getent group docker > /dev/null 2>&1; then
        info "Creando grupo docker..."
        groupadd docker
    fi
    
    # Obtener usuario real
    REAL_USER=${SUDO_USER:-root}
    
    # Agregar usuario al grupo docker
    if [ "$REAL_USER" != "root" ]; then
        if ! id -nG "$REAL_USER" | grep -qw docker; then
            info "Agregando $REAL_USER al grupo docker..."
            usermod -aG docker "$REAL_USER"
        fi
    fi
    
    # Configurar permisos del socket
    chown root:docker /var/run/docker.sock
    chmod 660 /var/run/docker.sock
    
    # Habilitar e iniciar servicio
    systemctl enable docker
    systemctl restart docker
    
    info "Esperando que Docker esté listo..."
    sleep 3
    
    # Verificar que funciona
    if docker ps > /dev/null 2>&1; then
        success "Docker instalado y funcionando: $(docker --version)"
    else
        error "Docker no responde. Revisa: systemctl status docker"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 4: INSTALAR DOCKER COMPOSE
# ════════════════════════════════════════════════════════════════════════════

install_docker_compose() {
    log "════════════════════════════════════════════════════════"
    log "PASO 4: Instalando Docker Compose..."
    log "════════════════════════════════════════════════════════"
    
    if command -v docker-compose &> /dev/null; then
        success "Docker Compose ya está instalado: $(docker-compose --version)"
        return 0
    fi
    
    info "Obteniendo última versión de Docker Compose..."
    local VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | \
        grep tag_name | cut -d'"' -f4 | sed 's/v//')
    
    if [ -z "$VERSION" ]; then
        warn "No se pudo obtener versión, usando 2.24.0"
        VERSION="2.24.0"
    fi
    
    info "Descargando Docker Compose v$VERSION..."
    curl -fsSL "https://github.com/docker/compose/releases/download/v${VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    success "Docker Compose instalado: $(docker-compose --version)"
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 5: CONFIGURAR SSH DEL SERVIDOR
# ════════════════════════════════════════════════════════════════════════════

setup_ssh() {
    log "════════════════════════════════════════════════════════"
    log "PASO 5: Configurando SSH del servidor..."
    log "════════════════════════════════════════════════════════"
    
    # Crear backup
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%s)
    info "Backup creado: /etc/ssh/sshd_config.backup"
    
    # Configurar seguridad
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    
    # Validar configuración
    if sshd -t 2>/dev/null; then
        systemctl restart ssh
        success "SSH configurado correctamente"
    else
        error "Configuración SSH inválida. Revirtiendo cambios..."
        cp /etc/ssh/sshd_config.backup.$(ls -t /etc/ssh/sshd_config.backup.* | head -1 | cut -d. -f4) /etc/ssh/sshd_config
        systemctl restart ssh
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 6: CONFIGURAR SSH PARA GITHUB
# ════════════════════════════════════════════════════════════════════════════

setup_github_ssh() {
    log "════════════════════════════════════════════════════════"
    log "PASO 6: Configurando SSH para GitHub..."
    log "════════════════════════════════════════════════════════"
    
    local REAL_USER=${SUDO_USER:-root}
    local HOME_DIR=$(eval echo ~$REAL_USER)
    local KEY_PATH="$HOME_DIR/.ssh/id_ed25519"
    
    # Crear directorio .ssh
    if [ ! -d "$HOME_DIR/.ssh" ]; then
        info "Creando directorio .ssh..."
        mkdir -p "$HOME_DIR/.ssh"
        chmod 700 "$HOME_DIR/.ssh"
        chown "$REAL_USER:$REAL_USER" "$HOME_DIR/.ssh"
    fi
    
    # Generar clave si no existe
    if [ ! -f "$KEY_PATH" ]; then
        info "Generando nueva clave ED25519..."
        sudo -u "$REAL_USER" ssh-keygen -t ed25519 -C "devops@laravel-docker" \
            -N "" -f "$KEY_PATH"
        success "Clave generada"
    else
        info "Clave ED25519 ya existe"
    fi
    
    # Establecer permisos correctos
    chmod 600 "$KEY_PATH"
    chmod 644 "$KEY_PATH.pub"
    chown "$REAL_USER:$REAL_USER" "$KEY_PATH" "$KEY_PATH.pub"
    
    # Configurar SSH config para GitHub
    local SSH_CONFIG="$HOME_DIR/.ssh/config"
    if [ ! -f "$SSH_CONFIG" ] || ! grep -q "github.com" "$SSH_CONFIG" 2>/dev/null; then
        info "Creando configuración SSH para GitHub..."
        sudo -u "$REAL_USER" bash -c "cat >> ~/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
EOF"
        chmod 600 "$SSH_CONFIG"
    fi
    
    # Mostrar clave pública
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "🔑 CLAVE PÚBLICA PARA GITHUB:"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    cat "$KEY_PATH.pub"
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "PASOS:"
    warn "1️⃣  Copia la clave anterior (ssh-ed25519 AAAA...)"
    warn "2️⃣  Abre: https://github.com/settings/keys"
    warn "3️⃣  Haz clic en 'New SSH key'"
    warn "4️⃣  Pega la clave completa"
    warn "5️⃣  Dale un nombre: 'servidor-laravel'"
    warn "6️⃣  Haz clic en 'Add SSH key'"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    read -p "Presiona ENTER cuando hayas agregado la clave en GitHub..."
    
    # Probar conexión
    info "Probando conexión a GitHub..."
    if sudo -u "$REAL_USER" ssh -T git@github.com 2>&1 | grep -qE "(successfully|Hi )"; then
        success "Conexión exitosa a GitHub"
    else
        warn "Conexión probada, continúa si te conectaste correctamente"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 7: CLONAR REPOSITORIO
# ════════════════════════════════════════════════════════════════════════════

clone_repository() {
    log "════════════════════════════════════════════════════════"
    log "PASO 7: Clonando repositorio..."
    log "════════════════════════════════════════════════════════"
    
    local repo_url=$1
    local target_dir=${2:-"/opt/laravel-app"}
    local REAL_USER=${SUDO_USER:-root}
    
    if [ -z "$repo_url" ]; then
        error "URL del repositorio requerida"
    fi
    
    if [ -d "$target_dir" ]; then
        info "Directorio existe, actualizando..."
        sudo -u "$REAL_USER" bash -c "cd $target_dir && git pull origin main" || true
    else
        info "Creando directorio: $target_dir"
        mkdir -p "$target_dir"
        chown "$REAL_USER:$REAL_USER" "$target_dir"
        
        info "Clonando repositorio..."
        sudo -u "$REAL_USER" git clone "$repo_url" "$target_dir"
    fi
    
    success "Repositorio clonado/actualizado"
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 8: CONFIGURAR PROYECTO LARAVEL
# ════════════════════════════════════════════════════════════════════════════

setup_project() {
    log "════════════════════════════════════════════════════════"
    log "PASO 8: Configurando proyecto Laravel..."
    log "════════════════════════════════════════════════════════"
    
    local target_dir=${1:-"/opt/laravel-app"}
    
    if [ ! -d "$target_dir" ]; then
        error "Directorio del proyecto no existe: $target_dir"
    fi
    
    cd "$target_dir"
    
    if [ ! -f .env ]; then
        if [ -f .env.example ]; then
            info "Creando .env desde .env.example..."
            cp .env.example .env
        else
            warn ".env.example no encontrado, deberás crear .env manualmente"
        fi
    fi
    
    # Verificar que Docker Compose existe
    if [ ! -f docker-compose.dev.yml ] && [ ! -f docker-compose.yml ]; then
        error "No se encontró docker-compose.dev.yml o docker-compose.yml"
    fi
    
    local COMPOSE_FILE="docker-compose.dev.yml"
    if [ ! -f "$COMPOSE_FILE" ]; then
        COMPOSE_FILE="docker-compose.yml"
    fi
    
    info "Construyendo contenedores..."
    docker-compose -f "$COMPOSE_FILE" build
    
    info "Iniciando contenedores..."
    docker-compose -f "$COMPOSE_FILE" up -d
    
    info "Esperando que los contenedores estén listos..."
    sleep 5
    
    info "Instalando dependencias de Composer..."
    docker-compose -f "$COMPOSE_FILE" exec -T app composer install || true
    
    info "Generando clave de aplicación..."
    docker-compose -f "$COMPOSE_FILE" exec -T app php artisan key:generate || true
    
    info "Ejecutando migraciones..."
    docker-compose -f "$COMPOSE_FILE" exec -T app php artisan migrate --seed || true
    
    info "Configurando permisos..."
    docker-compose -f "$COMPOSE_FILE" exec -T app chmod -R 775 storage bootstrap/cache || true
    docker-compose -f "$COMPOSE_FILE" exec -T app chown -R www-data:www-data storage bootstrap/cache || true
    
    success "Proyecto Laravel configurado"
}

# ════════════════════════════════════════════════════════════════════════════
# FUNCIÓN PRINCIPAL
# ════════════════════════════════════════════════════════════════════════════

main() {
    log ""
    log "╔═══════════════════════════════════════════════════════════════════════╗"
    log "║                                                                       ║"
    log "║        PROVISIONAMIENTO DE SERVIDOR LARAVEL + DOCKER + GIT            ║"
    log "║                      VERSIÓN 2.0 - ESTABLE                            ║"
    log "║                                                                       ║"
    log "╚═══════════════════════════════════════════════════════════════════════╝"
    log ""
    
    # Validaciones
    check_sudo
    detect_os
    
    # Pasos de instalación
    update_system
    install_basic_tools
    install_docker
    install_docker_compose
    setup_ssh
    setup_github_ssh
    
    # Repositorio
    echo ""
    read -p "📋 URL del repositorio (git@github.com:usuario/repo.git): " repo_url
    
    if [ -z "$repo_url" ]; then
        error "URL del repositorio requerida"
    fi
    
    read -p "📁 Directorio destino (default: /opt/laravel-app): " target_dir
    target_dir=${target_dir:-"/opt/laravel-app"}
    
    clone_repository "$repo_url" "$target_dir"
    setup_project "$target_dir"
    
    # Resumen final
    echo ""
    log "╔═══════════════════════════════════════════════════════════════════════╗"
    log "║                                                                       ║"
    log "║              ✅ ¡PROVISIONAMIENTO COMPLETADO EXITOSAMENTE! ✅         ║"
    log "║                                                                       ║"
    log "╚═══════════════════════════════════════════════════════════════════════╝"
    log ""
    log "📊 RESUMEN DE INSTALACIÓN:"
    log "   ✓ Sistema operativo: $OS_NAME"
    log "   ✓ Docker: $(docker --version)"
    log "   ✓ Docker Compose: $(docker-compose --version)"
    log "   ✓ Git: $(git --version)"
    log "   ✓ SSH: Configurado y seguro"
    log "   ✓ GitHub SSH: Conectado"
    log "   ✓ Repositorio: $repo_url"
    log "   ✓ Proyecto: $target_dir"
    log ""
    log "🌐 Accede a tu aplicación en: http://localhost"
    log ""
    log "📚 Comandos útiles:"
    log "   docker ps                    # Ver contenedores"
    log "   docker logs -f               # Ver logs"
    log "   docker-compose down          # Detener servicios"
    log ""
}

# Ejecutar
main "$@"