#!/bin/bash

# Script para crear estructura Docker Laravel y ejecutar todo automaticamente
# Ejecutar: bash setup-completo.sh

# Definir colores ANSI
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
GRAY='\033[37m'
RESET='\033[0m'

echo ""
echo -e "${CYAN}===================================${RESET}"
echo -e "${CYAN}   Setup Docker Laravel COMPLETO${RESET}"
echo -e "${CYAN}===================================${RESET}"
echo ""

# Guardar la ruta del proyecto al inicio — funciona en cualquier PC
projectPath="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/laravel-docker"

# Verificar si Docker esta instalado
echo -e "${YELLOW}Verificando Docker...${RESET}"
if ! command -v docker &> /dev/null; then
    echo -e "${RED}ERROR - Docker no esta instalado o no esta en PATH${RESET}"
    echo -e "${YELLOW}Instala Docker con: sudo apt-get install docker.io${RESET}"
    read -p "Presiona Enter para salir"
    exit 1
fi

dockerVersion=$(docker --version)
echo -e "${GREEN}OK - Docker encontrado: $dockerVersion${RESET}"

# Verificar si Docker esta corriendo
echo -e "${YELLOW}Verificando que Docker este corriendo...${RESET}"
if ! docker info &> /dev/null; then
    echo -e "${RED}ERROR - Docker no esta ejecutandose o requiere permisos${RESET}"
    echo -e "${YELLOW}Asegurate de que:${RESET}"
    echo -e "${YELLOW}  1. El daemon de Docker esta activo: sudo systemctl start docker${RESET}"
    echo -e "${YELLOW}  2. Tu usuario esta en el grupo docker: sudo usermod -aG docker \$USER${RESET}"
    read -p "Presiona Enter para salir"
    exit 1
fi

echo -e "${GREEN}OK - Docker esta activo${RESET}"

echo ""

# ---------------------------------------------
# PASO 1: Crear estructura de carpetas
# ---------------------------------------------
echo -e "${CYAN}PASO 1: Creando estructura de carpetas...${RESET}"

# Si ya existe la carpeta, preguntar si sobreescribir
if [ -d "laravel-docker" ]; then
    read -p "  La carpeta 'laravel-docker' ya existe. ¿Eliminarla y empezar de nuevo? (s/n): " resp
    if [ "$resp" = "s" ] || [ "$resp" = "S" ]; then
        rm -rf "laravel-docker"
        echo -e "${GRAY}  Carpeta eliminada${RESET}"
    else
        echo -e "${GRAY}  Usando carpeta existente${RESET}"
    fi
fi

mkdir -p "laravel-docker/docker/php"
mkdir -p "laravel-docker/docker/nginx"
mkdir -p "laravel-docker/src"

cd "laravel-docker"
echo -e "${GREEN}OK - Carpetas creadas${RESET}"

echo ""

# ---------------------------------------------
# PASO 2: Crear archivos de configuracion
# ---------------------------------------------
echo -e "${CYAN}PASO 2: Creando archivos de configuracion...${RESET}"

# -- Dockerfile --------------------------------------------------------------
cat > "docker/php/Dockerfile" << 'EOF'
FROM php:8.2-fpm-alpine

RUN apk add --no-cache bash curl libpng-dev libxml2-dev zip unzip git

RUN docker-php-ext-install pdo_mysql bcmath gd

RUN apk add --no-cache $PHPIZE_DEPS \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del $PHPIZE_DEPS

# FIX: Sin esto Composer falla al instalar laravel/framework y phpunit
#      porque el limite de 128MB de Alpine no alcanza para resolver
#      el grafo de dependencias completo de Laravel.
RUN cp "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini" \
    && echo "memory_limit = -1" >> "$PHP_INI_DIR/php.ini"

ENV COMPOSER_MEMORY_LIMIT=-1

COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

RUN chown -R www-data:www-data /var/www/html

EXPOSE 9000
EOF
echo -e "${GREEN}  - Dockerfile${RESET}"

# -- nginx/default.conf -------------------------------------------------------
cat > "docker/nginx/default.conf" << 'EOF'
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
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass app:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
echo -e "${GREEN}  - default.conf${RESET}"

# -- docker-compose.yml -------------------------------------------------------
cat > "docker-compose.yml" << 'EOF'
services:
  nginx:
    image: nginx:alpine
    container_name: nginx_server
    ports:
      - "8000:80"
    volumes:
      - ./src:/var/www/html
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - app
    networks:
      - backend

  app:
    build:
      context: .
      dockerfile: docker/php/Dockerfile
    container_name: php_app
    user: root
    volumes:
      - ./src:/var/www/html
    networks:
      - backend

  db:
    image: mysql:8.0
    container_name: mysql_db
    restart: always
    environment:
      MYSQL_DATABASE: my_database
      MYSQL_ROOT_PASSWORD: root_password
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - backend
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-proot_password"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:alpine
    container_name: redis_cache
    networks:
      - backend

  phpmyadmin:
    image: phpmyadmin/phpmyadmin
    container_name: pma_gui
    ports:
      - "8080:80"
    environment:
      PMA_HOST: db
      MYSQL_ROOT_PASSWORD: root_password
    depends_on:
      - db
    networks:
      - backend

networks:
  backend:
    driver: bridge

volumes:
  db_data:
EOF
echo -e "${GREEN}  - docker-compose.yml${RESET}"

echo ""

# ---------------------------------------------
# PASO 3: Construir e iniciar Docker
# ---------------------------------------------
echo -e "${CYAN}PASO 3: Construyendo e iniciando Docker Compose...${RESET}"
docker compose up -d --build

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR - No se pudo iniciar Docker Compose${RESET}"
    echo -e "${YELLOW}Asegurate de que Docker este ejecutandose${RESET}"
    read -p "Presiona Enter para salir"
    cd ..
    exit 1
fi
echo -e "${GREEN}OK - Docker Compose iniciado${RESET}"

echo ""

# ---------------------------------------------
# PASO 4: Esperar servicios
# ---------------------------------------------
echo -e "${CYAN}PASO 4: Esperando a que los servicios esten listos...${RESET}"

for ((i=20; i>0; i--)); do
    echo -ne "${GRAY}  $i segundos...\r${RESET}"
    sleep 1
done
echo -e "${GREEN}OK - Servicios listos                    ${RESET}"

echo ""

# ---------------------------------------------
# PASO 5: Instalar Laravel manualmente
# ---------------------------------------------
echo ""
echo -e "${GRAY}-----------------------------------------${RESET}"
echo -e "${YELLOW}  PASO 5: Instala Laravel manualmente${RESET}"
echo -e "${GRAY}-----------------------------------------${RESET}"
echo ""
echo -e "${WHITE}  1) Abre una terminal nueva${RESET}"
echo ""
echo -e "${GRAY}     Navega hasta la carpeta 'laravel-docker' y abre una terminal desde ahi.${RESET}"
echo -e "${GRAY}     (cd laravel-docker)${RESET}"
echo ""
echo -e "${WHITE}  2) Ejecuta este comando:${RESET}"
echo ""
echo -e "${CYAN}     docker compose exec app sh -c \"composer create-project laravel/laravel /tmp/laravel --remove-vcs --no-interaction && cp -rT /tmp/laravel /var/www/html && rm -rf /tmp/laravel\"${RESET}"
echo ""
echo -e "${RED}  *** IMPORTANTE: Espera a que el comando termine por completo.        ***${RESET}"
echo -e "${RED}  *** Sabras que termino cuando veas el prompt $ de nuevo.            ***${RESET}"
echo -e "${RED}  *** Si presionas Enter antes de tiempo, el paso 8 fallara.          ***${RESET}"
echo ""
echo -e "${WHITE}  3) Cuando Composer termine, vuelve aqui y presiona Enter${RESET}"
read -p "  ¿Listo? Presiona Enter para continuar"

echo ""

# ---------------------------------------------
# PASO 6: Configurar .env con datos de la DB
# ---------------------------------------------
echo -e "${CYAN}PASO 6: Configurando archivo .env...${RESET}"

cat > "src/.env" << 'EOF'
APP_NAME=Laravel
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost:8000

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=my_database
DB_USERNAME=root
DB_PASSWORD=root_password

BROADCAST_DRIVER=log
CACHE_STORE=redis
CACHE_DRIVER=redis
QUEUE_CONNECTION=sync
SESSION_DRIVER=file
SESSION_LIFETIME=120

REDIS_HOST=redis
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=log
EOF

echo -e "${GREEN}OK - .env configurado con datos de MySQL y Redis${RESET}"

echo ""

# ---------------------------------------------
# PASO 7: Ajustar permisos
# ---------------------------------------------
echo -e "${CYAN}PASO 7: Ajustando permisos de storage y cache...${RESET}"

docker compose exec app chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache
docker compose exec app chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache

if [ $? -eq 0 ]; then
    echo -e "${GREEN}OK - Permisos ajustados (775 para storage y bootstrap/cache)${RESET}"
else
    echo -e "${YELLOW}ADVERTENCIA - No se pudo ajustar permisos automaticamente${RESET}"
    echo -e "${GRAY}  Ejecuta manualmente:${RESET}"
    echo -e "${WHITE}  docker compose exec app chown -R www-data:www-data storage bootstrap/cache${RESET}"
    echo -e "${WHITE}  docker compose exec app chmod -R 775 storage bootstrap/cache${RESET}"
fi

echo ""

# ---------------------------------------------
# PASO 8: Generar APP_KEY
# ---------------------------------------------
echo -e "${CYAN}PASO 8: Generando APP_KEY...${RESET}"
docker compose exec app php artisan key:generate --force

if [ $? -eq 0 ]; then
    echo -e "${GREEN}OK - APP_KEY generada${RESET}"
else
    echo -e "${RED}ERROR - No se pudo generar APP_KEY${RESET}"
    echo -e "${WHITE}  Ejecuta manualmente: docker compose exec app php artisan key:generate${RESET}"
fi

echo ""

# ---------------------------------------------
# PASO 9: Limpiar cache de configuracion
# ---------------------------------------------
echo -e "${CYAN}PASO 9: Limpiando cache de configuracion...${RESET}"
docker compose exec app php artisan config:clear
echo -e "${GREEN}OK - Config cache limpiado${RESET}"

echo ""

# ---------------------------------------------
# PASO 10: Correr migraciones
# ---------------------------------------------
echo -e "${CYAN}PASO 10: Ejecutando migraciones...${RESET}"

docker compose exec app php artisan migrate --force

if [ $? -eq 0 ]; then
    echo -e "${GREEN}OK - Migraciones ejecutadas${RESET}"
    echo -e "${GRAY}  Limpiando cache de aplicacion...${RESET}"
    docker compose exec app php artisan cache:clear
    echo -e "${GREEN}OK - Cache de aplicacion limpiado${RESET}"
else
    echo -e "${YELLOW}ADVERTENCIA - No se pudieron ejecutar las migraciones${RESET}"
    echo -e "${GRAY}  Verifica que MySQL este listo y ejecuta manualmente:${RESET}"
    echo -e "${WHITE}  docker compose exec app php artisan migrate${RESET}"
fi

echo ""

# ---------------------------------------------
# RESUMEN FINAL
# ---------------------------------------------
echo -e "${GREEN}===================================${RESET}"
echo -e "${GREEN}   ¡INSTALACION COMPLETADA!${RESET}"
echo -e "${GREEN}===================================${RESET}"
echo ""
echo -e "${CYAN}Tu aplicacion Laravel esta lista en:${RESET}"
echo ""
echo -e "${GREEN}  Web:        http://localhost:8000${RESET}"
echo -e "${GREEN}  PhpMyAdmin: http://localhost:8080${RESET}"
echo ""
echo -e "${YELLOW}Credenciales de Base de Datos:${RESET}"
echo -e "${WHITE}  Usuario:      root${RESET}"
echo -e "${WHITE}  Contrasena:   root_password${RESET}"
echo -e "${WHITE}  Base de datos: my_database${RESET}"
echo ""
echo -e "${YELLOW}Comandos utiles:${RESET}"
echo -e "${WHITE}  Ver logs:           docker compose logs -f app${RESET}"
echo -e "${WHITE}  Consola Laravel:    docker compose exec app php artisan tinker${RESET}"
echo -e "${WHITE}  Ejecutar migracion: docker compose exec app php artisan migrate${RESET}"
echo -e "${WHITE}  Detener Docker:     docker compose down${RESET}"
echo -e "${WHITE}  Reconstruir:        docker compose up -d --build${RESET}"
echo ""
read -p "Presiona Enter para finalizar"