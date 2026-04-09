#!/bin/bash

set -e

# ═══════════════════════════════════════════════════════════════════
#  COLORES
# ═══════════════════════════════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════════════
#  FUNCIONES
# ═══════════════════════════════════════════════════════════════════
log() { echo -e "${GREEN}✓ $1${NC}"; }
error() { echo -e "${RED}✗ ERROR: $1${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
info() { echo -e "${BLUE}ℹ $1${NC}"; }
header() { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}\n${CYAN}  $1${NC}\n${CYAN}══════════════════════════════════════════════════════${NC}\n"; }

# ═══════════════════════════════════════════════════════════════════
#  VALIDACIONES
# ═══════════════════════════════════════════════════════════════════
header "VALIDANDO REQUISITOS"

# Verificar Docker
if ! command -v docker &> /dev/null; then
    error "Docker no está instalado. Instálalo con:\n  sudo apt install docker.io docker-compose-plugin"
fi
log "Docker: $(docker --version)"

# Verificar que Docker esté corriendo
if ! docker info &> /dev/null; then
    error "Docker no está corriendo. Ejecuta:\n  sudo systemctl start docker"
fi
log "Docker daemon activo"

# Verificar permisos de usuario
if ! docker ps &> /dev/null; then
    warn "Necesitas permisos de Docker. Ejecuta:\n  sudo usermod -aG docker \$USER\n  newgrp docker"
    exit 1
fi
log "Permisos de Docker OK"

# ═══════════════════════════════════════════════════════════════════
#  CONFIGURACIÓN INICIAL
# ═══════════════════════════════════════════════════════════════════
PROJECT_DIR="laravel-docker"

header "PASO 1: CREAR ESTRUCTURA"

# Manejar proyecto existente
if [ -d "$PROJECT_DIR" ]; then
    warn "La carpeta '$PROJECT_DIR' ya existe"
    read -p "¿Deseas eliminarla? (s/n): " resp
    if [[ "$resp" == "s" || "$resp" == "S" ]]; then
        rm -rf "$PROJECT_DIR"
        log "Carpeta eliminada"
    else
        log "Usando carpeta existente"
    fi
fi

# Crear estructura de carpetas
mkdir -p "$PROJECT_DIR/docker/php"
mkdir -p "$PROJECT_DIR/docker/nginx"
mkdir -p "$PROJECT_DIR/src"

cd "$PROJECT_DIR"
log "Estructura de carpetas creada"

# ═══════════════════════════════════════════════════════════════════
#  PASO 2: ARCHIVOS DE CONFIGURACIÓN
# ═══════════════════════════════════════════════════════════════════
header "PASO 2: CREAR CONFIGURACIÓN"

# Dockerfile PHP
cat > docker/php/Dockerfile <<'DOCKERFILE'
FROM php:8.2-fpm-alpine

RUN apk add --no-cache \
    bash curl libpng-dev libxml2-dev zip unzip git \
    $PHPIZE_DEPS

RUN docker-php-ext-install \
    pdo_mysql bcmath gd

RUN pecl install redis \
    && docker-php-ext-enable redis

RUN cp "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini" \
    && echo "memory_limit = -1" >> "$PHP_INI_DIR/php.ini"

ENV COMPOSER_MEMORY_LIMIT=-1

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

RUN chown -R www-data:www-data /var/www/html

EXPOSE 9000
DOCKERFILE

log "Dockerfile creado"

# Configuración Nginx
cat > docker/nginx/default.conf <<'NGINX'
server {
    listen 80;
    index index.php index.html;
    server_name localhost;

    root /var/www/html/public;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_pass app:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
NGINX

log "Nginx configurado"

# docker-compose.yml
cat > docker-compose.yml <<'COMPOSE'
version: '3.9'

services:
  nginx:
    image: nginx:alpine
    container_name: laravel_nginx
    ports:
      - "80:80"
    volumes:
      - ./src:/var/www/html
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf
    depends_on:
      - app
    networks:
      - laravel_network
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  app:
    build:
      context: .
      dockerfile: docker/php/Dockerfile
    container_name: laravel_app
    working_dir: /var/www/html
    volumes:
      - ./src:/var/www/html
    depends_on:
      - db
      - redis
    networks:
      - laravel_network
    environment:
      - DB_HOST=db
      - DB_PORT=3306
      - REDIS_HOST=redis

  db:
    image: mysql:8.0
    container_name: laravel_db
    environment:
      MYSQL_DATABASE: my_database
      MYSQL_ROOT_PASSWORD: root_password
      MYSQL_PASSWORD: password
      MYSQL_USER: laravel_user
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - laravel_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:alpine
    container_name: laravel_redis
    networks:
      - laravel_network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  phpmyadmin:
    image: phpmyadmin/phpmyadmin
    container_name: laravel_phpmyadmin
    ports:
      - "8080:80"
    environment:
      PMA_HOST: db
      PMA_USER: root
      PMA_PASSWORD: root_password
    depends_on:
      - db
    networks:
      - laravel_network

volumes:
  db_data:
    driver: local

networks:
  laravel_network:
    driver: bridge
COMPOSE

log "Docker-compose configurado"

# ═══════════════════════════════════════════════════════════════════
#  PASO 3: LEVANTAR CONTENEDORES
# ═══════════════════════════════════════════════════════════════════
header "PASO 3: INICIANDO CONTENEDORES"

if ! docker compose up -d --build; then
    error "No se pudieron iniciar los contenedores"
fi

log "Contenedores iniciados"

# ═══════════════════════════════════════════════════════════════════
#  PASO 4: ESPERAR SERVICIOS
# ═══════════════════════════════════════════════════════════════════
header "PASO 4: ESPERANDO SERVICIOS"

info "Esperando que los servicios estén listos..."
sleep 15

# Verificar que los servicios estén activos
if ! docker compose ps | grep -q "healthy"; then
    warn "Los servicios aún no están totalmente listos, pero continuamos..."
fi

log "Servicios activos"

# ═══════════════════════════════════════════════════════════════════
#  PASO 5: INSTALAR LARAVEL
# ═══════════════════════════════════════════════════════════════════
header "PASO 5: INSTALAR LARAVEL"

info "Instalando Laravel en el contenedor..."

docker compose exec -T app sh -c "composer create-project laravel/laravel:^10 /tmp/laravel && cp -rT /tmp/laravel /var/www/html" 2>&1 | tail -10

log "Laravel instalado"

# ═══════════════════════════════════════════════════════════════════
#  PASO 6: CREAR .env
# ═══════════════════════════════════════════════════════════════════
header "PASO 6: CONFIGURAR .env"

cat > src/.env <<'ENV'
APP_NAME="Laravel Docker"
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=my_database
DB_USERNAME=root
DB_PASSWORD=root_password

CACHE_DRIVER=redis
CACHE_STORE=redis
REDIS_HOST=redis
REDIS_PASSWORD=null
REDIS_PORT=6379

SESSION_DRIVER=cookie
SESSION_LIFETIME=120

QUEUE_CONNECTION=sync

MAIL_MAILER=log
ENV

log ".env creado"

# ═══════════════════════════════════════════════════════════════════
#  PASO 7: PERMISOS
# ═══════════════════════════════════════════════════════════════════
header "PASO 7: CONFIGURAR PERMISOS"

docker compose exec -T app chmod -R 775 storage bootstrap/cache
docker compose exec -T app chown -R www-data:www-data /var/www/html

log "Permisos configurados"

# ═══════════════════════════════════════════════════════════════════
#  PASO 8: GENERAR APP_KEY
# ═══════════════════════════════════════════════════════════════════
header "PASO 8: GENERAR APP_KEY"

docker compose exec -T app php artisan key:generate

log "APP_KEY generada"

# ═══════════════════════════════════════════════════════════════════
#  PASO 9: MIGRACIONES
# ═══════════════════════════════════════════════════════════════════
header "PASO 9: EJECUTAR MIGRACIONES"

docker compose exec -T app php artisan migrate --force

log "Migraciones ejecutadas"

# ═══════════════════════════════════════════════════════════════════
#  FINALIZACIÓN
# ═══════════════════════════════════════════════════════════════════
header "✓ INSTALACIÓN COMPLETADA"

echo -e "${GREEN}┌─────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  Accesos:${NC}"
echo -e "${GREEN}│${NC}"
echo -e "${GREEN}│  🌐 Web: ${CYAN}http://localhost${GREEN}${NC}"
echo -e "${GREEN}│  📊 PhpMyAdmin: ${CYAN}http://localhost:8080${GREEN}${NC}"
echo -e "${GREEN}│     (Usuario: root, Contraseña: root_password)${NC}"
echo -e "${GREEN}│${NC}"
echo -e "${GREEN}│  📁 Carpeta: ${CYAN}$(pwd)${GREEN}${NC}"
echo -e "${GREEN}│${NC}"
echo -e "${GREEN}│  🐳 Comandos útiles:${NC}"
echo -e "${GREEN}│     docker compose ps${NC}"
echo -e "${GREEN}│     docker compose logs app${NC}"
echo -e "${GREEN}│     docker compose exec app bash${NC}"
echo -e "${GREEN}│${NC}"
echo -e "${GREEN}└─────────────────────────────────────────────────────┘${NC}"
echo ""