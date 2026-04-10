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