# Script para crear estructura Docker Laravel y ejecutar todo automaticamente
# Ejecutar: powershell -ExecutionPolicy Bypass -File setup-completo.ps1

Write-Host ""
Write-Host "===================================" -ForegroundColor Cyan
Write-Host "   Setup Docker Laravel COMPLETO" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan
Write-Host ""

# Guardar la ruta del proyecto al inicio — funciona en cualquier PC
$projectPath = Join-Path $PSScriptRoot "laravel-docker"

# Verificar si Docker esta instalado
Write-Host "Verificando Docker..." -ForegroundColor Yellow
try {
    $dockerVersion = docker --version
    Write-Host "OK - Docker encontrado: $dockerVersion" -ForegroundColor Green
} catch {
    Write-Host "ERROR - Docker no esta instalado o no esta en PATH" -ForegroundColor Red
    Write-Host "Instala Docker Desktop desde: https://www.docker.com/products/docker-desktop" -ForegroundColor Yellow
    Read-Host "Presiona Enter para salir"
    exit
}

# Verificar si Docker Desktop esta corriendo
Write-Host "Verificando que Docker este corriendo..." -ForegroundColor Yellow
try {
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker no responde" }
    Write-Host "OK - Docker esta activo" -ForegroundColor Green
} catch {
    Write-Host "ERROR - Docker Desktop no esta ejecutandose" -ForegroundColor Red
    Write-Host "Abrelo desde el menu de inicio e intentalo de nuevo" -ForegroundColor Yellow
    Read-Host "Presiona Enter para salir"
    exit
}

Write-Host ""

# ---------------------------------------------
# PASO 1: Crear estructura de carpetas
# ---------------------------------------------
Write-Host "PASO 1: Creando estructura de carpetas..." -ForegroundColor Cyan

# Si ya existe la carpeta, preguntar si sobreescribir
if (Test-Path "laravel-docker") {
    $resp = Read-Host "  La carpeta 'laravel-docker' ya existe. Eliminarla y empezar de nuevo? (s/n)"
    if ($resp -eq "s" -or $resp -eq "S") {
        Remove-Item -Recurse -Force "laravel-docker"
        Write-Host "  Carpeta eliminada" -ForegroundColor Gray
    } else {
        Write-Host "  Usando carpeta existente" -ForegroundColor Gray
    }
}

New-Item -ItemType Directory "laravel-docker/docker/php"   -Force | Out-Null
New-Item -ItemType Directory "laravel-docker/docker/nginx" -Force | Out-Null
New-Item -ItemType Directory "laravel-docker/src"          -Force | Out-Null

Set-Location "laravel-docker"
Write-Host "OK - Carpetas creadas" -ForegroundColor Green

Write-Host ""

# ---------------------------------------------
# PASO 2: Crear archivos de configuracion
# ---------------------------------------------
Write-Host "PASO 2: Creando archivos de configuracion..." -ForegroundColor Cyan

# -- Dockerfile --------------------------------------------------------------
@'
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
'@ | Out-File "docker/php/Dockerfile" -Encoding UTF8 -NoNewline
Write-Host "  - Dockerfile" -ForegroundColor Green

# -- nginx/default.conf -------------------------------------------------------
@'
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
'@ | Set-Content "docker/nginx/default.conf" -Encoding ascii
Write-Host "  - default.conf" -ForegroundColor Green

# -- docker-compose.yml -------------------------------------------------------
@'
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
'@ | Out-File "docker-compose.yml" -Encoding UTF8 -NoNewline
Write-Host "  - docker-compose.yml" -ForegroundColor Green

Write-Host ""

# ---------------------------------------------
# PASO 3: Construir e iniciar Docker
# ---------------------------------------------
Write-Host "PASO 3: Construyendo e iniciando Docker Compose..." -ForegroundColor Cyan
docker compose up -d --build

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR - No se pudo iniciar Docker Compose" -ForegroundColor Red
    Write-Host "Asegurate de que Docker Desktop este ejecutandose" -ForegroundColor Yellow
    Read-Host "Presiona Enter para salir"
    Set-Location ..
    exit
}
Write-Host "OK - Docker Compose iniciado" -ForegroundColor Green

Write-Host ""

# ---------------------------------------------
# PASO 4: Esperar servicios
# ---------------------------------------------
Write-Host "PASO 4: Esperando a que los servicios esten listos..." -ForegroundColor Cyan

for ($i = 20; $i -gt 0; $i--) {
    Write-Host "  $i segundos..." -ForegroundColor Gray
    Start-Sleep -Seconds 1
}
Write-Host "OK - Servicios listos" -ForegroundColor Green

Write-Host ""

# ---------------------------------------------
# PASO 5: Instalar Laravel manualmente
# ---------------------------------------------
Write-Host ""
Write-Host "-----------------------------------------" -ForegroundColor DarkGray
Write-Host "  PASO 5: Instala Laravel manualmente" -ForegroundColor Yellow
Write-Host "-----------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  1) Abre una terminal nueva" -ForegroundColor White
Write-Host ""
Write-Host "     Navega hasta la carpeta 'laravel-docker' y abri la terminal desde ahi." -ForegroundColor Gray
Write-Host "     (clic derecho dentro de la carpeta -> 'Abrir en Terminal')" -ForegroundColor Gray
Write-Host ""
Write-Host "  2) Ejecuta este comando:" -ForegroundColor White
Write-Host ""
Write-Host "     docker compose exec app sh -c `"composer create-project laravel/laravel /tmp/laravel --remove-vcs --no-interaction && cp -rT /tmp/laravel /var/www/html && rm -rf /tmp/laravel`"" -ForegroundColor Cyan
Write-Host ""
Write-Host "  *** IMPORTANTE: Espera a que el comando termine por completo.     ***" -ForegroundColor Red
Write-Host "  *** Sabras que termino cuando veas el prompt PS C:\...> de nuevo. ***" -ForegroundColor Red
Write-Host "  *** Si presionas Enter antes de tiempo, el paso 8 fallara.        ***" -ForegroundColor Red
Write-Host ""
Write-Host "  3) Cuando Composer termine, vuelve aqui y presiona Enter" -ForegroundColor White
Read-Host "  Listo? Presiona Enter para continuar"

Write-Host ""

# ---------------------------------------------
# PASO 6: Configurar .env con datos de la DB
# ---------------------------------------------
Write-Host "PASO 6: Configurando archivo .env..." -ForegroundColor Cyan

$envContent = @"
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
"@

$envContent | Out-File "src/.env" -Encoding UTF8 -NoNewline

Write-Host "OK - .env configurado con datos de MySQL y Redis" -ForegroundColor Green

Write-Host ""

# ---------------------------------------------
# PASO 7: Ajustar permisos
# ---------------------------------------------
Write-Host "PASO 7: Ajustando permisos de storage y cache..." -ForegroundColor Cyan

docker compose exec app chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache
docker compose exec app chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache

if ($LASTEXITCODE -eq 0) {
    Write-Host "OK - Permisos ajustados (775 para storage y bootstrap/cache)" -ForegroundColor Green
} else {
    Write-Host "ADVERTENCIA - No se pudo ajustar permisos automaticamente" -ForegroundColor Yellow
    Write-Host "  Ejecuta manualmente:" -ForegroundColor Gray
    Write-Host "  docker compose exec app chown -R www-data:www-data storage bootstrap/cache" -ForegroundColor White
    Write-Host "  docker compose exec app chmod -R 775 storage bootstrap/cache" -ForegroundColor White
}

Write-Host ""

# ---------------------------------------------
# PASO 8: Generar APP_KEY
# ---------------------------------------------
Write-Host "PASO 8: Generando APP_KEY..." -ForegroundColor Cyan
docker compose exec app php artisan key:generate --force

if ($LASTEXITCODE -eq 0) {
    Write-Host "OK - APP_KEY generada" -ForegroundColor Green
} else {
    Write-Host "ERROR - No se pudo generar APP_KEY" -ForegroundColor Red
    Write-Host "  Ejecuta manualmente: docker compose exec app php artisan key:generate" -ForegroundColor White
}

Write-Host ""

# ---------------------------------------------
# PASO 9: Limpiar cache de configuracion
# ---------------------------------------------
Write-Host "PASO 9: Limpiando cache de configuracion..." -ForegroundColor Cyan
docker compose exec app php artisan config:clear
Write-Host "OK - Config cache limpiado" -ForegroundColor Green

Write-Host ""

# ---------------------------------------------
# PASO 10: Correr migraciones
# ---------------------------------------------
Write-Host "PASO 10: Ejecutando migraciones..." -ForegroundColor Cyan

docker compose exec app php artisan migrate --force

if ($LASTEXITCODE -eq 0) {
    Write-Host "OK - Migraciones ejecutadas" -ForegroundColor Green
    Write-Host "  Limpiando cache de aplicacion..." -ForegroundColor Gray
    docker compose exec app php artisan cache:clear
    Write-Host "OK - Cache de aplicacion limpiado" -ForegroundColor Green
} else {
    Write-Host "ADVERTENCIA - No se pudieron ejecutar las migraciones" -ForegroundColor Yellow
    Write-Host "  Verifica que MySQL este listo y ejecuta manualmente:" -ForegroundColor Gray
    Write-Host "  docker compose exec app php artisan migrate" -ForegroundColor White
}

Write-Host ""

# ---------------------------------------------
# RESUMEN FINAL
# ---------------------------------------------
Write-Host "===================================" -ForegroundColor Green
Write-Host "   INSTALACION COMPLETADA!" -ForegroundColor Green
Write-Host "===================================" -ForegroundColor Green
Write-Host ""
Write-Host "Tu aplicacion Laravel esta lista en:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Web:        http://localhost:8000" -ForegroundColor Green
Write-Host "  PhpMyAdmin: http://localhost:8080" -ForegroundColor Green
Write-Host ""
Write-Host "Credenciales de Base de Datos:" -ForegroundColor Yellow
Write-Host "  Usuario:      root" -ForegroundColor White
Write-Host "  Contrasena:   root_password" -ForegroundColor White
Write-Host "  Base de datos: my_database" -ForegroundColor White
Write-Host ""
Write-Host "Comandos utiles:" -ForegroundColor Yellow
Write-Host "  Ver logs:           docker compose logs -f app" -ForegroundColor White
Write-Host "  Consola Laravel:    docker compose exec app php artisan tinker" -ForegroundColor White
Write-Host "  Ejecutar migracion: docker compose exec app php artisan migrate" -ForegroundColor White
Write-Host "  Detener Docker:     docker compose down" -ForegroundColor White
Write-Host "  Reconstruir:        docker compose up -d --build" -ForegroundColor White
Write-Host ""
Read-Host "Presiona Enter para finalizar"
