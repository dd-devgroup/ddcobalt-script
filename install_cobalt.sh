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
ASK="🔍"

COBALT_DIR="$HOME/cobalt"
COMPOSE_FILE="$COBALT_DIR/docker-compose.yml"
PORT="9000"
SCRIPT_URL="https://raw.githubusercontent.com/dd-devgroup/ddcobalt-script/main/install_cobalt.sh"
LOCAL_SCRIPT="$HOME/ddcobalt-install.sh"

if [[ ! -f "$LOCAL_SCRIPT" ]]; then
  echo -e "${WARN} ${YELLOW}Скрипт запущен не из файла, сохраняю в $LOCAL_SCRIPT и перезапускаюсь...${RESET}"
  curl -fsSL "$SCRIPT_URL" -o "$LOCAL_SCRIPT"
  chmod +x "$LOCAL_SCRIPT"
  exec "$LOCAL_SCRIPT" "$@"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${ERR} ${RED}Пожалуйста, запустите скрипт с правами root (через sudo)${RESET}"
  exit 1
fi

install_cobalt() {
  echo -e "${INFO} ${CYAN}Проверка Docker...${RESET}"
  if ! command -v docker &> /dev/null; then
    echo -e "${WARN} ${YELLOW}Docker не найден. Установите Docker: https://docs.docker.com/engine/install/ubuntu/${RESET}"
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

  echo -e "${ASK} ${YELLOW}Введите доменное имя для доступа через Nginx (например, cobalt.example.com):${RESET}"
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
version: '3.8'

networks:
  cobalt_net:
    name: cobalt_net
    driver: bridge

services:
  cobalt:
    image: ghcr.io/imputnet/cobalt:11
    init: true
    read_only: true
    restart: unless-stopped
    container_name: cobalt
    environment:
      API_URL: "$API_URL"
    networks:
      - cobalt_net
EOF

  if [[ "$USE_COOKIES" == "y" ]]; then
    echo '      COOKIE_PATH: "/cookies.json"' >> "$COMPOSE_FILE"
  fi

  cat >> "$COMPOSE_FILE" <<EOF

  nginx:
    image: nginx:stable
    container_name: cobalt-nginx
    restart: unless-stopped
    ports:
      - 80:80
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - cobalt_net

  watchtower:
    image: ghcr.io/containrrr/watchtower
    restart: unless-stopped
    command: --cleanup --scope cobalt --interval 900 --include-restarting
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

  if [[ "$USE_COOKIES" == "y" ]]; then
    echo -e "
volumes:
  - ./cookies.json:/cookies.json" >> "$COMPOSE_FILE"
  fi

  echo -e "${INFO} ${CYAN}Создание конфигурации nginx (./nginx.conf)...${RESET}"
  cat > nginx.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://cobalt:9000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  echo -e "${INFO} ${CYAN}Запуск Cobalt через Docker Compose...${RESET}"
  docker compose -f "$COMPOSE_FILE" up -d

  echo -e "${OK} ${GREEN}Установка завершена!${RESET}"
  echo -e "${OK} ${GREEN}Cobalt доступен по адресу http://$DOMAIN${RESET}"
  [[ "$USE_COOKIES" == "y" ]] && echo -e "${WARN} ${YELLOW}Файл cookies.json создан. Заполните его при необходимости.${RESET}"
}

update_script() {
  echo -e "${INFO} ${CYAN}Проверка обновлений скрипта...${RESET}"
  TMP_FILE=$(mktemp)
  curl -fsSL "$SCRIPT_URL" -o "$TMP_FILE"

  if cmp -s "$TMP_FILE" "$LOCAL_SCRIPT"; then
    echo -e "${OK} ${GREEN}У вас уже последняя версия скрипта.${RESET}"
    rm "$TMP_FILE"
  else
    echo -e "${WARN} ${YELLOW}Найдена новая версия. Обновляю автоматически...${RESET}"
    cp "$TMP_FILE" "$LOCAL_SCRIPT"
    chmod +x "$LOCAL_SCRIPT"
    rm "$TMP_FILE"
    echo -e "${OK} ${GREEN}Скрипт обновлён! Перезапустите его снова.${RESET}"
  fi
}

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
