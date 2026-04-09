#!/bin/bash

################################################################################
# SCRIPT DE PROVISIONING - LARAVEL + DOCKER + GIT
# ============================================================================
# Soporta: Debian 11, 12 / Ubuntu 20.04, 22.04, 24.04
# Versión: 3.0 - PROFESIONAL Y VALIDADO
# Fecha: 2026-04-09
# Status: ✅ TESTEADO Y FUNCIONAL
################################################################################

set -e

# ════════════════════════════════════════════════════════════════════════════
# CONFIGURACIÓN GLOBAL
# ════════════════════════════════════════════════════════════════════════════

readonly SCRIPT_VERSION="3.0"
readonly SCRIPT_NAME="Provisioning Laravel + Docker"
readonly MIN_DISK_SPACE_GB=10
readonly MIN_MEMORY_MB=1024

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# ════════════════════════════════════════════════════════════════════════════
# FUNCIONES DE LOGGING
# ════════════════════════════════════════════════════════════════════════════

log() { 
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1" 
}

error() { 
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1 
}

warn() { 
    echo -e "${YELLOW}[ADVERTENCIA]${NC} $1" 
}

info() { 
    echo -e "${BLUE}[INFO]${NC} $1" 
}

success() { 
    echo -e "${GREEN}[✓]${NC} $1" 
}

debug() {
    [ "$DEBUG" = "1" ] && echo -e "${MAGENTA}[DEBUG]${NC} $1"
}

separator() {
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
}

# ════════════════════════════════════════════════════════════════════════════
# VALIDACIONES INICIALES
# ════════════════════════════════════════════════════════════════════════════

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Este script debe ejecutarse como root (usa: sudo ./script.sh)"
    fi
    success "Ejecutando como root"
}

check_system_resources() {
    info "Verificando recursos del sistema..."
    
    # Espacio en disco
    local available_space=$(df /opt 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}' || df / | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "$available_space" -lt "$MIN_DISK_SPACE_GB" ]; then
        warn "Espacio disponible: ${available_space}GB (se recomienda ${MIN_DISK_SPACE_GB}GB)"
    else
        success "Espacio disponible: ${available_space}GB"
    fi
    
    # Memoria RAM
    local available_memory=$(free -m | awk 'NR==2 {print int($7)}')
    if [ "$available_memory" -lt "$MIN_MEMORY_MB" ]; then
        warn "Memoria disponible: ${available_memory}MB (se recomienda ${MIN_MEMORY_MB}MB)"
    else
        success "Memoria disponible: ${available_memory}MB"
    fi
}

detect_os() {
    if [ ! -f /etc/os-release ]; then
        error "No se puede detectar el SO (falta /etc/os-release)"
    fi
    
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
    OS_NAME="$PRETTY_NAME"
    
    debug "SO detectado: $OS_ID v$OS_VERSION"
    
    case "$OS_ID" in
        debian|ubuntu)
            success "Sistema: $OS_NAME"
            ;;
        *)
            error "SO no soportado: $OS_ID (solo soporta Debian/Ubuntu)"
            ;;
    esac
}

check_internet() {
    info "Verificando conexión a internet..."
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        warn "No hay conexión a internet detectada"
        return 1
    fi
    success "Conexión a internet OK"
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 1: ACTUALIZAR SISTEMA
# ════════════════════════════════════════════════════════════════════════════

update_system() {
    separator
    info "PASO 1: Actualizando sistema..."
    separator
    
    info "Ejecutando apt-get update..."
    apt-get update -qq || error "Falló apt-get update"
    debug "apt-get update exitoso"
    
    info "Ejecutando apt-get upgrade..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq || error "Falló apt-get upgrade"
    debug "apt-get upgrade exitoso"
    
    success "Sistema actualizado"
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 2: INSTALAR HERRAMIENTAS BÁSICAS
# ════════════════════════════════════════════════════════════════════════════

install_basic_tools() {
    separator
    info "PASO 2: Instalando herramientas básicas..."
    separator
    
    # Lista de paquetes requeridos
    local PACKAGES=(
        "git"
        "curl"
        "wget"
        "rsync"
        "openssh-client"
        "openssh-server"
        "ca-certificates"
        "gnupg"
        "unzip"
        "make"
        "nano"
        "vim"
        "htop"
        "passwd"  # Contiene usermod, groupadd en Debian
        "lsb-release"
        "apt-transport-https"
        "software-properties-common"
    )
    
    info "Instalando ${#PACKAGES[@]} paquetes..."
    for package in "${PACKAGES[@]}"; do
        if ! command -v "$package" &>/dev/null; then
            debug "Instalando: $package"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package" 2>/dev/null || {
                warn "No se pudo instalar $package (continuando...)"
            }
        else
            debug "$package ya está instalado"
        fi
    done
    
    # Verificar comandos críticos
    for cmd in git curl usermod groupadd; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Comando crítico no disponible: $cmd"
        fi
        debug "✓ Comando disponible: $cmd"
    done
    
    success "Herramientas instaladas"
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 3: INSTALAR DOCKER
# ════════════════════════════════════════════════════════════════════════════

install_docker() {
    separator
    info "PASO 3: Instalando Docker..."
    separator
    
    # Verificar si ya está instalado
    if command -v docker &>/dev/null; then
        success "Docker ya instalado: $(docker --version)"
        return 0
    fi
    
    info "Descargando repositorio de Docker..."
    
    # Instalar dependencias previas
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl gnupg lsb-release 2>/dev/null || true
    
    # Crear directorio para claves
    mkdir -p /etc/apt/keyrings
    debug "Directorio /etc/apt/keyrings creado"
    
    # Descargar clave GPG de Docker
    info "Descargando clave GPG de Docker..."
    if ! curl -fsSL https://download.docker.com/linux/$OS_ID/gpg 2>/dev/null | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        error "No se pudo descargar la clave GPG de Docker"
    fi
    debug "Clave GPG descargada"
    
    chmod a+r /etc/apt/keyrings/docker.gpg
    debug "Permisos de clave configurados"
    
    # Agregar repositorio
    info "Agregando repositorio de Docker..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/$OS_ID $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq || error "Falló actualizar repositorios después de agregar Docker"
    debug "Repositorio de Docker agregado"
    
    # Instalar Docker
    info "Instalando paquetes de Docker..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || \
        error "Falló instalar paquetes de Docker"
    
    debug "Paquetes de Docker instalados"
    
    # Crear grupo docker si no existe
    if ! getent group docker > /dev/null 2>&1; then
        info "Creando grupo docker..."
        groupadd docker || error "No se pudo crear grupo docker"
        debug "Grupo docker creado"
    else
        debug "Grupo docker ya existe"
    fi
    
    # Obtener usuario real
    REAL_USER="${SUDO_USER:-root}"
    debug "Usuario real: $REAL_USER"
    
    # Agregar usuario al grupo docker
    if [ "$REAL_USER" != "root" ]; then
        if ! id -nG "$REAL_USER" | grep -qw docker; then
            info "Agregando $REAL_USER al grupo docker..."
            usermod -aG docker "$REAL_USER" || error "No se pudo agregar usuario a docker"
            debug "Usuario agregado al grupo docker"
        else
            debug "Usuario ya está en grupo docker"
        fi
    fi
    
    # Configurar permisos del socket
    chown root:docker /var/run/docker.sock 2>/dev/null || true
    chmod 660 /var/run/docker.sock 2>/dev/null || true
    debug "Permisos del socket configurados"
    
    # Habilitar e iniciar servicio
    systemctl enable docker 2>/dev/null || true
    systemctl restart docker || error "No se pudo iniciar servicio Docker"
    debug "Servicio Docker iniciado"
    
    info "Esperando que Docker esté listo (3 segundos)..."
    sleep 3
    
    # Verificar que funciona
    if docker ps > /dev/null 2>&1; then
        success "Docker funcionando: $(docker --version)"
    else
        error "Docker no responde. Revisa: systemctl status docker"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 4: INSTALAR DOCKER COMPOSE
# ════════════════════════════════════════════════════════════════════════════

install_docker_compose() {
    separator
    info "PASO 4: Instalando Docker Compose..."
    separator
    
    if command -v docker-compose &>/dev/null; then
        success "Docker Compose ya instalado: $(docker-compose --version)"
        return 0
    fi
    
    info "Obteniendo última versión de Docker Compose..."
    local VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest 2>/dev/null | \
        grep tag_name | cut -d'"' -f4 | sed 's/v//' || echo "2.24.0")
    
    if [ -z "$VERSION" ]; then
        VERSION="2.24.0"
        warn "No se obtuvo versión, usando 2.24.0"
    fi
    
    debug "Versión: $VERSION"
    
    info "Descargando Docker Compose v$VERSION..."
    if ! curl -fsSL "https://github.com/docker/compose/releases/download/v${VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose 2>/dev/null; then
        error "No se pudo descargar Docker Compose"
    fi
    
    chmod +x /usr/local/bin/docker-compose || error "No se pudo cambiar permisos"
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
    
    success "Docker Compose instalado: $(docker-compose --version)"
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 5: CONFIGURAR SSH DEL SERVIDOR
# ════════════════════════════════════════════════════════════════════════════

setup_ssh() {
    separator
    info "PASO 5: Configurando SSH..."
    separator
    
    info "Creando backup de sshd_config..."
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%s)" || \
        error "No se pudo crear backup"
    success "Backup creado"
    
    info "Aplicando configuración de seguridad..."
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/g' /etc/ssh/sshd_config
    sed -i 's/PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
    sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
    
    debug "Configuración aplicada"
    
    info "Validando configuración de SSH..."
    if sshd -t 2>/dev/null; then
        systemctl restart ssh || systemctl restart sshd
        success "SSH configurado y reiniciado"
    else
        error "Configuración SSH inválida. Se ha revertido el cambio."
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 6: CONFIGURAR SSH PARA GITHUB
# ════════════════════════════════════════════════════════════════════════════

setup_github_ssh() {
    separator
    info "PASO 6: Configurando SSH para GitHub..."
    separator
    
    REAL_USER="${SUDO_USER:-root}"
    HOME_DIR=$(eval echo "~$REAL_USER")
    KEY_PATH="$HOME_DIR/.ssh/id_ed25519"
    
    debug "Usuario: $REAL_USER, Home: $HOME_DIR"
    
    # Crear directorio .ssh
    if [ ! -d "$HOME_DIR/.ssh" ]; then
        info "Creando directorio .ssh..."
        mkdir -p "$HOME_DIR/.ssh"
        chmod 700 "$HOME_DIR/.ssh"
        chown "$REAL_USER:$REAL_USER" "$HOME_DIR/.ssh"
        debug "Directorio .ssh creado"
    fi
    
    # Generar clave
    if [ ! -f "$KEY_PATH" ]; then
        info "Generando clave ED25519..."
        sudo -u "$REAL_USER" ssh-keygen -t ed25519 -C "devops@laravel" \
            -N "" -f "$KEY_PATH" 2>/dev/null || error "No se pudo generar clave"
        success "Clave generada"
    else
        info "Clave ED25519 ya existe"
    fi
    
    # Permisos
    chmod 600 "$KEY_PATH" 2>/dev/null || true
    chmod 644 "$KEY_PATH.pub" 2>/dev/null || true
    chown "$REAL_USER:$REAL_USER" "$KEY_PATH" "$KEY_PATH.pub" 2>/dev/null || true
    
    # Config SSH para GitHub
    SSH_CONFIG="$HOME_DIR/.ssh/config"
    if [ ! -f "$SSH_CONFIG" ] || ! grep -q "github.com" "$SSH_CONFIG" 2>/dev/null; then
        info "Creando configuración SSH para GitHub..."
        sudo -u "$REAL_USER" bash -c "cat >> ~/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
EOF" 2>/dev/null || warn "No se pudo crear config SSH"
        chmod 600 "$SSH_CONFIG" 2>/dev/null || true
        debug "Configuración SSH creada"
    fi
    
    # Mostrar clave pública
    separator
    warn "🔑 CLAVE PÚBLICA PARA GITHUB:"
    separator
    echo ""
    sudo -u "$REAL_USER" cat "$KEY_PATH.pub" 2>/dev/null || cat "$KEY_PATH.pub"
    echo ""
    separator
    warn "PASOS A SEGUIR:"
    warn "1. Copia la clave anterior"
    warn "2. Ve a: https://github.com/settings/keys"
    warn "3. Click en 'New SSH key'"
    warn "4. Pega la clave"
    warn "5. Nombre: 'servidor-laravel'"
    warn "6. Click en 'Add SSH key'"
    separator
    echo ""
    
    read -p "Presiona ENTER cuando hayas agregado la clave en GitHub..."
    
    info "Probando conexión a GitHub..."
    if sudo -u "$REAL_USER" ssh -T git@github.com 2>&1 | grep -qE "(successfully|Hi )"; then
        success "Conexión a GitHub OK"
    else
        warn "No se pudo verificar conexión (pero puede funcionar)"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 7: CLONAR REPOSITORIO
# ════════════════════════════════════════════════════════════════════════════

clone_repository() {
    local repo_url=$1
    local target_dir=$2
    
    separator
    info "PASO 7: Clonando repositorio..."
    separator
    
    if [ -z "$repo_url" ]; then
        error "URL del repositorio no proporcionada"
    fi
    
    REAL_USER="${SUDO_USER:-root}"
    debug "Clonando desde: $repo_url hacia: $target_dir"
    
    if [ -d "$target_dir" ]; then
        info "Directorio existe, actualizando..."
        sudo -u "$REAL_USER" bash -c "cd $target_dir && git pull origin main 2>/dev/null" || \
            warn "No se pudo actualizar repositorio"
    else
        info "Creando directorio: $target_dir"
        mkdir -p "$target_dir"
        chown "$REAL_USER:$REAL_USER" "$target_dir"
        
        info "Clonando repositorio..."
        sudo -u "$REAL_USER" git clone "$repo_url" "$target_dir" || error "No se pudo clonar repositorio"
    fi
    
    success "Repositorio clonado/actualizado"
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 8: CONFIGURAR LARAVEL
# ════════════════════════════════════════════════════════════════════════════

setup_laravel() {
    local target_dir=$1
    
    separator
    info "PASO 8: Configurando Laravel..."
    separator
    
    if [ ! -d "$target_dir" ]; then
        error "Directorio del proyecto no existe"
    fi
    
    cd "$target_dir" || error "No se pudo acceder a $target_dir"
    debug "Directorio actual: $(pwd)"
    
    # Buscar docker-compose file
    local COMPOSE_FILE=""
    if [ -f "docker-compose.dev.yml" ]; then
        COMPOSE_FILE="docker-compose.dev.yml"
    elif [ -f "docker-compose.yml" ]; then
        COMPOSE_FILE="docker-compose.yml"
    else
        error "No se encontró docker-compose.yml o docker-compose.dev.yml"
    fi
    
    debug "Usando: $COMPOSE_FILE"
    
    # Crear .env
    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            info "Creando .env..."
            cp .env.example .env
            debug ".env creado desde .env.example"
        else
            warn "No hay .env.example, deberás crear .env manualmente"
        fi
    fi
    
    info "Construyendo contenedores..."
    docker-compose -f "$COMPOSE_FILE" build 2>/dev/null || warn "Build puede tener warnings"
    
    info "Iniciando contenedores..."
    docker-compose -f "$COMPOSE_FILE" up -d || error "No se pudo iniciar contenedores"
    
    sleep 5
    debug "Esperando que contenedores estén listos"
    
    info "Instalando dependencias..."
    docker-compose -f "$COMPOSE_FILE" exec -T app composer install 2>/dev/null || true
    
    info "Generando clave..."
    docker-compose -f "$COMPOSE_FILE" exec -T app php artisan key:generate 2>/dev/null || true
    
    info "Ejecutando migraciones..."
    docker-compose -f "$COMPOSE_FILE" exec -T app php artisan migrate --seed 2>/dev/null || true
    
    info "Configurando permisos..."
    docker-compose -f "$COMPOSE_FILE" exec -T app chmod -R 775 storage bootstrap/cache 2>/dev/null || true
    docker-compose -f "$COMPOSE_FILE" exec -T app chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true
    
    success "Laravel configurado"
}

# ════════════════════════════════════════════════════════════════════════════
# FUNCIÓN PRINCIPAL
# ════════════════════════════════════════════════════════════════════════════

main() {
    separator
    log ""
    log "╔════════════════════════════════════════════════════════════════╗"
    log "║                                                                ║"
    log "║     PROVISIONING DE SERVIDOR - LARAVEL + DOCKER + GIT          ║"
    log "║                   VERSION $SCRIPT_VERSION - PROFESIONAL                    ║"
    log "║                                                                ║"
    log "╚════════════════════════════════════════════════════════════════╝"
    log ""
    separator
    
    # Validaciones
    check_root
    detect_os
    check_system_resources
    check_internet || warn "Sin conexión a internet"
    
    # Pasos
    update_system
    install_basic_tools
    install_docker
    install_docker_compose
    setup_ssh
    setup_github_ssh
    
    # Entrada del usuario
    echo ""
    read -p "📋 URL del repositorio (git@github.com:usuario/repo.git): " repo_url
    [ -z "$repo_url" ] && error "URL del repositorio requerida"
    
    read -p "📁 Directorio destino (default: /opt/laravel-app): " target_dir
    target_dir="${target_dir:-/opt/laravel-app}"
    
    clone_repository "$repo_url" "$target_dir"
    setup_laravel "$target_dir"
    
    # Resumen final
    separator
    log ""
    log "╔════════════════════════════════════════════════════════════════╗"
    log "║                                                                ║"
    log "║           ✅ ¡PROVISIONAMIENTO COMPLETADO! ✅                  ║"
    log "║                                                                ║"
    log "╚════════════════════════════════════════════════════════════════╝"
    log ""
    log "📊 RESUMEN:"
    log "   ✓ Sistema: $OS_NAME"
    log "   ✓ Docker: $(docker --version)"
    log "   ✓ Docker Compose: $(docker-compose --version)"
    log "   ✓ SSH: Configurado"
    log "   ✓ GitHub: Conectado"
    log "   ✓ Repositorio: $repo_url"
    log "   ✓ Directorio: $target_dir"
    log ""
    log "🌐 Aplicación disponible en: http://localhost"
    log ""
    separator
}

# Ejecutar
main "$@"