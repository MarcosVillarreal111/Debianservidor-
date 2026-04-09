#  Laravel Docker Deployment System

Este repositorio contiene dos scripts esenciales para automatizar la configuración de un servidor Debian y el despliegue de una aplicación Laravel utilizando Docker.

---

##  Descripción de los Scripts

### 1. `scriptservidor.sh` (Preparación del Sistema)
Este script debe ejecutarse primero para dejar el servidor listo.
* **Función:** Instala Docker y Docker Compose, configura dependencias de red y genera las llaves SSH para conectar con GitHub.
* **Uso:** Se encarga de clonar el código base en `/opt/laravel-app`.

### 2. `scriptdocker_laravel.sh` (Despliegue de Aplicación)
Este script se encarga de toda la infraestructura de contenedores.
* **Función:** Crea los archivos `Dockerfile` y `docker-compose.yml`, levanta los servicios (PHP, Nginx, MySQL, Redis) e instala Laravel internamente.
* **Automatización:** Configura el archivo `.env`, genera la llave de la app y corre las migraciones de base de datos.

---

##  Guía de Ejecución Paso a Paso

Sigue estos comandos en orden dentro de tu servidor para poner todo en marcha:

### Paso 1: Preparar el servidor
```bash
chmod +x scriptservidor.sh
./scriptservidor.sh
