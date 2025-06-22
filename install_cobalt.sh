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
  apt update -y && apt install -y curl nscd

  echo -e "${INFO} ${CYAN}Запуск nscd...${RESET}"
  systemctl enable nscd && systemctl start nscd

  echo -e "${ASK} ${YELLOW}Введите внешний API URL (например, https://my.cobalt.instance/):${RESET}"
  read -rp ">>> " API_URL

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

  cat >> "$COMPOSE_FILE" <<EOF

  watchtower:
    image: ghcr.io/containrrr/watchtower
    restart: unless-stopped
    command: --cleanup --scope cobalt --interval 900 --include-restarting
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

  echo -e "${INFO} ${CYAN}Запуск Cobalt через Docker Compose...${RESET}"
  docker compose -f "$COMPOSE_FILE" up -d

  echo -e "${OK} ${GREEN}Установка завершена! Cobalt работает на порту $PORT${RESET}"
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

# === Главное меню ===
while true; do
  echo -e ""
  echo -e "${CYAN}===== DDCobalt Setup Menu =====${RESET}"
  echo -e "1. 🔧 Установить Cobalt"
  echo -e "2. 🔄 Проверить обновления скрипта"
  echo -e "3. 🚪 Выйти"
  echo -e ""
  read -rp "${ASK} Выберите действие [1-3]: " choice

  case $choice in
    1) install_cobalt ;;
    2) update_script ;;
    3) echo -e "${OK} ${GREEN}Выход...${RESET}"; exit 0 ;;
    *) echo -e "${ERR} ${RED}Неверный выбор. Попробуйте снова.${RESET}" ;;
  esac
done
