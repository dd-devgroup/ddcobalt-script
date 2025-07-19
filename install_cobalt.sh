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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo -e "${WARN} ${YELLOW}Docker не найден. Устанавливаю Docker...${RESET}"
    apt update -y
    apt install -y ca-certificates curl gnupg lsb-release

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo -e "${OK} ${GREEN}Docker установлен.${RESET}"
  else
    echo -e "${OK} ${GREEN}Docker уже установлен.${RESET}"
  fi

  if ! command -v docker-compose &> /dev/null; then
    echo -e "${WARN} ${YELLOW}docker-compose не найден. Устанавливаю...${RESET}"
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    echo -e "${OK} ${GREEN}docker-compose установлен.${RESET}"
  else
    echo -e "${OK} ${GREEN}docker-compose уже установлен.${RESET}"
  fi

  echo -e "${INFO} ${CYAN}Установка зависимостей...${RESET}"
  apt update -y
  apt install -y docker-compose curl nscd certbot

  echo -e "${INFO} ${CYAN}Запуск nscd...${RESET}"
  systemctl enable nscd && systemctl start nscd

  echo -e "${ASK} ${YELLOW}Введите внешний API URL (например, my.cobalt.instance):${RESET}"
  read -rp ">>> " API_URL

  DOMAIN=$(echo "$API_URL" | sed -E 's#https?://##' | sed 's#/.*##')

  echo -e "${INFO} ${CYAN}Используем домен для certbot: $DOMAIN${RESET}"
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

  # Создаем docker-compose.yml из шаблона
  echo -e "${INFO} ${CYAN}Генерация docker-compose.yml из шаблона...${RESET}"
  render_template "$SCRIPT_DIR/docker-compose.yml.template" "$COMPOSE_FILE"

  # Если нужно, добавим в docker-compose монтирование cookies
  if [[ "$USE_COOKIES" == "y" ]]; then
    sed -i '/environment:/a \      COOKIE_PATH: "/cookies.json"' "$COMPOSE_FILE"
    sed -i '/volumes:/a \      - ./cookies.json:/cookies.json' "$COMPOSE_FILE"
  fi

  # Генерируем nginx-temp.conf из шаблона (конфиг без SSL)
  echo -e "${INFO} ${CYAN}Генерация nginx-temp.conf из шаблона...${RESET}"
  render_template "$SCRIPT_DIR/nginx-temp.conf.template" "./nginx-temp.conf"

  # Генерируем nginx.conf из шаблона (конфиг с SSL)
  echo -e "${INFO} ${CYAN}Генерация nginx.conf из шаблона...${RESET}"
  render_template "$SCRIPT_DIR/nginx.conf.template" "./nginx.conf"

  echo -e "${INFO} ${CYAN}Создание директорий для certbot webroot и certs...${RESET}"
  mkdir -p ./certs ./webroot

  echo -e "${INFO} ${CYAN}Запуск Cobalt и Watchtower через Docker Compose...${RESET}"
  docker compose -f "$COMPOSE_FILE" up -d cobalt watchtower

  echo -e "${INFO} ${CYAN}Запуск nginx без SSL для certbot...${RESET}"
  docker compose -f "$COMPOSE_FILE" up -d nginx

  echo -e "${INFO} ${CYAN}Ожидание запуска nginx...${RESET}"
  for i in {1..10}; do
    if nc -z localhost 80; then
      echo -e "${OK} ${GREEN}nginx запущен.${RESET}"
      break
    fi
    echo -e "${INFO} ${CYAN}Ожидание... ($i/10)${RESET}"
    sleep 2
  done

  echo -e "${INFO} ${CYAN}Выпуск Let's Encrypt сертификата...${RESET}"
  certbot certonly --webroot -w "$COBALT_DIR/webroot" -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN" --non-interactive --preferred-challenges http

  echo -e "${INFO} ${CYAN}Копирование сертификатов в ./certs...${RESET}"
  cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem "$COBALT_DIR/certs/fullchain.pem"
  cp /etc/letsencrypt/live/$DOMAIN/privkey.pem "$COBALT_DIR/certs/privkey.pem"

  echo -e "${INFO} ${CYAN}Остановка nginx для замены конфигурации...${RESET}"
  docker compose -f "$COMPOSE_FILE" stop nginx

  echo -e "${INFO} ${CYAN}Замена nginx-temp.conf на полный nginx.conf...${RESET}"
  cp nginx.conf nginx-temp.conf

  echo -e "${INFO} ${CYAN}Перезапуск nginx с полной конфигурацией...${RESET}"
  docker compose -f "$COMPOSE_FILE" up -d nginx

  echo -e "${OK} ${GREEN}Установка завершена!${RESET}"
  echo -e "${OK} ${GREEN}Cobalt доступен по адресу https://$DOMAIN${RESET}"
  [[ "$USE_COOKIES" == "y" ]] && echo -e "${WARN} ${YELLOW}Файл cookies.json создан. Заполните его при необходимости.${RESET}"
}


manage_certs() {
  DOMAIN=$(grep 'server_name' "$COBALT_DIR/nginx.conf" | head -n1 | awk '{print $2}' | tr -d ';')

  echo -e "${CYAN}Управление сертификатами${RESET}"
  echo -e "1. Обновить текущие сертификаты"
  echo -e "2. Сгенерировать новые сертификаты для другого домена"
  echo -e "0. Выход"
  read -rp "[?] Выберите действие (0-2): " cert_choice
  case $cert_choice in
    1)
      echo -e "${INFO} ${CYAN}Обновление сертификатов certbot...${RESET}"
      certbot renew
      docker restart cobalt-nginx
      ;;
    2)
      echo -e "${ASK} ${YELLOW}Введите новый домен:${RESET}"
      read -rp ">>> " NEW_DOMAIN
      sed -i "s/server_name .*/server_name $NEW_DOMAIN;/" "$COBALT_DIR/nginx.conf"
      docker compose -f "$COMPOSE_FILE" down
      # Обновляем webroot, если надо — здесь используем то же, что и раньше
      certbot certonly --webroot -w "$COBALT_DIR/webroot" -d "$NEW_DOMAIN" --agree-tos --email admin@$NEW_DOMAIN --non-interactive --preferred-challenges http
      docker compose -f "$COMPOSE_FILE" up -d
      echo -e "${OK} ${GREEN}Сертификаты обновлены для нового домена: $NEW_DOMAIN${RESET}"
      ;;
    0)
      return ;;
    *)
      echo -e "${ERR} ${RED}Неверный выбор.${RESET}"
      ;;
  esac
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

# Функция простого рендеринга шаблонов с заменой {{VAR}} на значение переменной
render_template() {
  local template_file="$1"
  local output_file="$2"
  local line

  > "$output_file" # Очистить/создать выходной файл

  while IFS= read -r line || [[ -n "$line" ]]; do
    while [[ "$line" =~ \{\{([A-Z_]+)\}\} ]]; do
      var_name="${BASH_REMATCH[1]}"
      var_value="${!var_name}"  # Получить значение переменной по имени
      line="${line//\{\{$var_name\}\}/$var_value}"
    done
    echo "$line" >> "$output_file"
  done < "$template_file"
}


while true; do
  echo -e ""
  echo -e "${CYAN}===== DDCobalt Setup Menu =====${RESET}"
  echo -e "1. 🔧 Установить Cobalt"
  echo -e "2. 🔄 Проверить обновления скрипта"
  echo -e "3. 🚪 Выйти"
  echo -e "4. 🔍 Проверить статус Cobalt"
  echo -e "5. 🔒 Управление сертификатами"
  echo -e ""
  read -rp "${ASK} Выберите действие [1-5]: " choice

  case $choice in
    1) install_cobalt ;;
    2) update_script ;;
    3) echo -e "${OK} ${GREEN}Выход...${RESET}"; exit 0 ;;
    4) check_status ;;
    5) manage_certs ;;
    *) echo -e "${ERR} ${RED}Неверный выбор. Попробуйте снова.${RESET}" ;;
  esac
done
