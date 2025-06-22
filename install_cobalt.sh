#!/bin/bash

set -e

# Цвета и эмодзи
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'

INFO="ℹ️ "
OK="✅"
WARN="⚠️ "
ERR="❌"
ASK="👉"

# Путь установки
COBALT_DIR="$HOME/cobalt"
COMPOSE_FILE="$COBALT_DIR/docker-compose.yml"
PORT="9000"
SCRIPT_URL="https://raw.githubusercontent.com/dd-devgroup/ddcobalt-script/main/install_cobalt.sh"
SCRIPT_PATH="$0"

# Проверка прав
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${ERR} ${RED}Пожалуйста, запустите скрипт с правами root (через sudo)${RESET}"
  exit 1
fi

# === Функция установки ===
install_cobalt() {
  echo -e "${INFO} ${CYAN}Установка зависимостей...${RESET}"
  echo -e "${INFO} ${CYAN}Проверка Docker...${RESET}"
  if ! command -v docker &> /dev/null; then
    echo -e "${WARN} ${YELLOW}Docker не найден. Попробуйте установить вручную: https://docs.docker.com/engine/install/ubuntu/${RESET}"
    exit 1
  else
    echo -e "${OK} ${GREEN}Docker уже установлен.${RESET}"
  fi

  echo -e "${INFO} ${CYAN}Установка зависимостей...${RESET}"
  apt update -y
  apt install -y docker-compose curl nscd

  echo -e "${INFO} ${CYAN}Запуск nscd...${RESET}"
  systemctl enable nscd && systemctl start nscd

  echo -e "${ASK} ${YELLOW}Введите внешний API URL (например, https://my.cobalt.instance/):${RESET}"
  read -rp ">>> " API_URL

  echo -e "${ASK} ${YELLOW}Введите доменное имя для доступа через Caddy (например, cobalt.example.com):${RESET}"
  read -rp ">>> " DOMAIN

  echo -e "${ASK} ${YELLOW}Нужно ли использовать cookies.json? [y/N]:${RESET}"
  read -rp ">>> " USE_COOKIES
  USE_COOKIES=${USE_COOKIES,,}

  echo -e "${INFO} ${CYAN}Создание директории $COBALT_DIR...${RESET}"
  mkdir -p "$COBALT_DIR"
  cd "$COBALT_DIR"

  if [[ "$USE_COOKIES" == "y" ]]; then
    echo -e "${INFO} ${CYAN}Создание пустого cookies.json...${RESET}"
    touch cookies.json
  fi

  echo -e "${INFO} ${CYAN}Создание docker-compose.yml...${RESET}"

  cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  cobalt:
    image: ghcr.io/imputnet/cobalt:11
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

  # Добавляем сервис caddy с автоматическим SSL и проксированием
  cat >> "$COMPOSE_FILE" <<EOF

  caddy:
    image: caddy:2
    restart: unless-stopped
    container_name: caddy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config

  watchtower:
    image: ghcr.io/containrrr/watchtower
    restart: unless-stopped
    command: --cleanup --scope cobalt --interval 900 --include-restarting
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  caddy_data:
  caddy_config:
EOF

  # Создаем Caddyfile для проксирования на cobalt
  cat > "$COBALT_DIR/Caddyfile" <<EOF
$DOMAIN {
    reverse_proxy localhost:$PORT
    log {
      output stdout
      format console
    }
}
EOF

  echo -e "${INFO} ${CYAN}Запуск Cobalt и Caddy через Docker Compose...${RESET}"
  docker compose -f "$COMPOSE_FILE" up -d

  echo -e "${OK} ${GREEN}Установка завершена!${RESET}"
  echo -e "${OK} ${GREEN}Cobalt доступен на порту $PORT локально и по домену https://$DOMAIN${RESET}"
  [[ "$USE_COOKIES" == "y" ]] && echo -e "${WARN} ${YELLOW}Файл cookies.json создан. Заполните его при необходимости.${RESET}"
}

# === Функция проверки обновлений скрипта ===
update_script() {
  echo -e "${INFO} ${CYAN}Проверка обновлений скрипта...${RESET}"
  TMP_FILE=$(mktemp)
  curl -fsSL "$SCRIPT_URL" -o "$TMP_FILE"

  if cmp -s "$TMP_FILE" "$SCRIPT_PATH"; then
    echo -e "${OK} ${GREEN}У вас уже последняя версия скрипта.${RESET}"
    rm "$TMP_FILE"
  else
    echo -e "${ASK} ${YELLOW}Найдена новая версия. Обновить? [y/N]:${RESET}"
    read -rp ">>> " CONFIRM
    CONFIRM=${CONFIRM,,}
    if [[ "$CONFIRM" == "y" ]]; then
      cp "$TMP_FILE" "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo -e "${OK} ${GREEN}Скрипт обновлён! Перезапустите его снова.${RESET}"
    else
      echo -e "${INFO} ${CYAN}Обновление отменено.${RESET}"
    fi
    rm "$TMP_FILE"
  fi
}

# === Функция проверки статуса cobalt ===
check_status() {
  echo -e "${INFO} ${CYAN}Проверка запущенных контейнеров Cobalt...${RESET}"
  if docker ps --format '{{.Names}}' | grep -qw cobalt; then
    echo -e "${OK} ${GREEN}Контейнер cobalt запущен:${RESET}"
    docker ps --filter "name=cobalt" --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

    echo -e "\n${INFO} ${CYAN}Вывод последних 20 строк логов cobalt...${RESET}"
    docker logs --tail 20 cobalt
  else
    echo -e "${WARN} ${YELLOW}Контейнер cobalt не запущен.${RESET}"
  fi
}

# === Главное меню ===
while true; do
  echo -e ""
  echo -e "${CYAN}===== DDCobalt Setup Menu =====${RESET}"
  echo -e "1. 🔧 Установить Cobalt"
  echo -e "2. 🔄 Проверить обновления скрипта"
  echo -e "3. 🚪 Выйти"
  echo -e "4. 🔍 Проверить статус Cobalt"
  echo -e ""
  read -rp "${ASK} Выберите действие [1-4]: " choice

  case $choice in
    1) install_cobalt ;;
    2) update_script ;;
    3) echo -e "${OK} ${GREEN}Выход...${RESET}"; exit 0 ;;
    4) check_status ;;
    *) echo -e "${ERR} ${RED}Неверный выбор. Попробуйте снова.${RESET}" ;;
  esac
done
