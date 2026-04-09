#!/bin/bash

echo ""
echo "==================================="
echo "   Setup Docker Laravel COMPLETO"
echo "==================================="
echo ""

PROJECT_DIR="laravel-docker"

# ---------------------------------------------
# Verificar Docker
# ---------------------------------------------
echo "Verificando Docker..."
if ! command -v docker &> /dev/null; then
    echo "ERROR - Docker no está instalado"
    echo "Instálalo con:"
    echo "  sudo apt install docker.io docker-compose-plugin"
    exit 1
fi

echo "OK - Docker encontrado: $(docker --version)"

# Verificar que Docker esté corriendo
echo "Verificando que Docker esté activo..."
if ! docker info &> /dev/null; then
    echo "ERROR - Docker no está corriendo"
    echo "Ejecuta:"
    echo "  sudo systemctl start docker"
    exit 1
fi

echo "OK - Docker activo"
echo ""

# ---------------------------------------------
# PASO 1: Crear estructura
# ---------------------------------------------
echo "PASO 1: Creando estructura..."

if [ -d "$PROJECT_DIR" ]; then
    read -p "La carpeta ya existe. ¿Eliminarla? (s/n): " resp
    if [[ "$resp" == "s" || "$resp" == "S" ]]; then
        rm -rf "$PROJECT_DIR"
        echo "Carpeta eliminada"
    else
        echo "Usando carpeta existente"
    fi
fi

mkdir -p $PROJECT_DIR/docker/php
mkdir -p $PROJECT_DIR/docker/nginx
mkdir -p $PROJECT_DIR/src

cd $PROJECT_DIR

echo "OK - Carpetas creadas"
echo ""

# ---------------------------------------------
# PASO 2: Archivos config
# ---------------------------------------------
echo "PASO 2: Creando configuración..."

# Dockerfile
cat > docker/php/Dockerfile <<EOF
FROM php:8.2-fpm-alpine

RUN apk add --no-cache bash curl libpng-dev libxml2-dev zip unzip git

RUN docker-php-ext-install pdo_mysql bcmath gd

RUN apk add --no-cache \$PHPIZE_DEPS \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del \$PHPIZE_DEPS

RUN cp "\$PHP_INI_DIR/php.ini-development" "\$PHP_INI_DIR/php.ini" \
    && echo "memory_limit = -1" >> "\$PHP_INI_DIR/php.ini"

ENV COMPOSER_MEMORY_LIMIT=-1

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

RUN chown -R www-data:www-data /var/www/html

EXPOSE 9000
EOF

echo "  - Dockerfile"

# nginx
cat > docker/nginx/default.conf <<EOF
server {
    listen 80;
    index index.php index.html;
    server_name localhost;

    root /var/www/html/public;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass app:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

echo "  - nginx config"

# docker-compose
cat > docker-compose.yml <<EOF
services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./src:/var/www/html
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf
    depends_on:
      - app

  app:
    build:
      context: .
      dockerfile: docker/php/Dockerfile
    volumes:
      - ./src:/var/www/html

  db:
    image: mysql:8.0
    environment:
      MYSQL_DATABASE: my_database
      MYSQL_ROOT_PASSWORD: root_password
    volumes:
      - db_data:/var/lib/mysql

  redis:
    image: redis:alpine

  phpmyadmin:
    image: phpmyadmin/phpmyadmin
    ports:
      - "8080:80"
    environment:
      PMA_HOST: db
      MYSQL_ROOT_PASSWORD: root_password

volumes:
  db_data:
EOF

echo "  - docker-compose.yml"
echo ""

# ---------------------------------------------
# PASO 3: Levantar Docker
# ---------------------------------------------
echo "PASO 3: Iniciando contenedores..."
docker compose up -d --build

if [ $? -ne 0 ]; then
    echo "ERROR al iniciar Docker"
    exit 1
fi

echo "OK - Contenedores activos"
echo ""

# ---------------------------------------------
# PASO 4: Esperar servicios
# ---------------------------------------------
echo "Esperando servicios..."
sleep 20
echo "OK"
echo ""

# ---------------------------------------------
# PASO 5: Instalar Laravel
# ---------------------------------------------
echo "PASO 5: Instalar Laravel"
echo ""
echo "Ejecuta en otra terminal:"
echo ""
echo "cd $PROJECT_DIR"
echo 'docker compose exec app sh -c "composer create-project laravel/laravel /tmp/laravel && cp -rT /tmp/laravel /var/www/html"'
echo ""
read -p "Presiona Enter cuando termine..."

# ---------------------------------------------
# PASO 6: .env
# ---------------------------------------------
cat > src/.env <<EOF
APP_NAME=Laravel
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost

DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=my_database
DB_USERNAME=root
DB_PASSWORD=root_password

CACHE_DRIVER=redis
REDIS_HOST=redis
EOF

echo "OK - .env creado"

# ---------------------------------------------
# PASO 7: Permisos
# ---------------------------------------------
docker compose exec app chmod -R 775 storage bootstrap/cache

# ---------------------------------------------
# PASO 8: APP_KEY
# ---------------------------------------------
docker compose exec app php artisan key:generate

# ---------------------------------------------
# PASO 9: Migraciones
# ---------------------------------------------
docker compose exec app php artisan migrate --force

echo ""
echo "==================================="
echo "   INSTALACION COMPLETADA"
echo "==================================="
echo ""
echo "Web: http://localhost"
echo "PhpMyAdmin: http://localhost:8080"
echo ""