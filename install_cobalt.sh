#!/bin/bash

set -e

# === Настройки ===
COBALT_DIR="$HOME/cobalt"
COMPOSE_FILE="$COBALT_DIR/docker-compose.yml"
DOCKER_IMAGE="ghcr.io/imputnet/cobalt:11"
WATCHTOWER_IMAGE="ghcr.io/containrrr/watchtower"
PORT="9000"

# === Проверка на root ===
if [ "$(id -u)" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с правами root (через sudo)"
  exit 1
fi

# === Установка зависимостей ===
echo "Обновление пакетов и установка зависимостей..."
apt update
apt install -y docker.io docker-compose curl nscd

# Запуск nscd
echo "Запуск nscd..."
systemctl enable nscd
systemctl start nscd

# === Получение параметров от пользователя ===
read -rp "Введите внешний API URL (например, https://my.cobalt.instance/): " API_URL

read -rp "Нужно ли использовать cookies.json? [y/N]: " USE_COOKIES
USE_COOKIES=${USE_COOKIES,,}  # в нижний регистр

# === Создание директорий и файлов ===
echo "Создание директории $COBALT_DIR..."
mkdir -p "$COBALT_DIR"
cd "$COBALT_DIR"

if [[ "$USE_COOKIES" == "y" ]]; then
  echo "Создание пустого cookies.json (вы можете позже заполнить его вручную)..."
  touch cookies.json
fi

# === Генерация docker-compose.yml ===
echo "Создание docker-compose.yml..."

cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  cobalt:
    image: $DOCKER_IMAGE
    init: true
    read_only: true
    restart: unless-stopped
    container_name: cobalt
    ports:
      - "$PORT:9000"
    environment:
      API_URL: "$API_URL"
EOF

if [[ "$USE_COOKIES" == "y" ]]; then
  cat >> "$COMPOSE_FILE" <<EOF
      COOKIE_PATH: "/cookies.json"
EOF
fi

cat >> "$COMPOSE_FILE" <<EOF
    labels:
      - com.centurylinklabs.watchtower.scope=cobalt
EOF

if [[ "$USE_COOKIES" == "y" ]]; then
  cat >> "$COMPOSE_FILE" <<EOF
    volumes:
      - ./cookies.json:/cookies.json
EOF
fi

cat >> "$COMPOSE_FILE" <<EOF

  watchtower:
    image: $WATCHTOWER_IMAGE
    restart: unless-stopped
    command: --cleanup --scope cobalt --interval 900 --include-restarting
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

# === Запуск контейнеров ===
echo "Запуск Cobalt через Docker Compose..."
docker compose -f "$COMPOSE_FILE" up -d

echo "✅ Установка завершена. Cobalt запущен на порту $PORT"
[[ "$USE_COOKIES" == "y" ]] && echo "ℹ️  Файл cookies.json создан. Заполните его при необходимости."
