#!/bin/bash
# join_domain_final.sh - Полная автоматизация присоединения к домену
# Запускать с sudo: sudo ./join_domain_final.sh

set -e  # Выход при любой ошибке

DOMAIN="s1210.lan"
SERVER="rosa.s1210.lan"
ADMIN="admin"
PASSWORD="qwe123!E!E"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
error() { echo -e "${RED}[ОШИБКА]${NC} $1"; }

echo "================================================"
echo "   АВТОМАТИЧЕСКОЕ ПРИСОЕДИНЕНИЕ К ДОМЕНУ S1210"
echo "================================================"
echo "Домен: $DOMAIN"
echo "Сервер: $SERVER"
echo "================================================"

# Проверка, что скрипт запущен с sudo
if [ "$EUID" -ne 0 ]; then
    error "Скрипт должен запускаться с sudo!"
    echo "Используйте: sudo ./join_domain_final.sh"
    exit 1
fi

# ========== ШАГ 1: НАСТРОЙКА СЕТИ ==========
log "1. Настройка сети и DNS..."

# Сохраняем оригинальный resolv.conf
cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%s)

# Создаём новый resolv.conf
cat > /etc/resolv.conf << EOF
# Настройка DNS для домена $DOMAIN
nameserver 172.26.128.219
nameserver 10.89.87.63
search $DOMAIN
EOF

# Блокируем файл от изменений
chattr +i /etc/resolv.conf 2>/dev/null || true

log "   Проверка связи с сервером домена..."
if ping -c 2 -W 1 $SERVER > /dev/null 2>&1; then
    log "   ✓ Сервер $SERVER доступен"
else
    warn "   ⚠ Сервер $SERVER не отвечает на ping"
    warn "   Добавляю запись в /etc/hosts..."
    echo "172.26.128.219 $SERVER" >> /etc/hosts
fi

# ========== ШАГ 2: УСТАНОВКА ПАКЕТОВ ==========
log "2. Установка необходимых пакетов..."

if command -v dnf > /dev/null 2>&1; then
    dnf install -y freeipa-client oddjob-mkhomedir sssd authselect
elif command -v yum > /dev/null 2>&1; then
    yum install -y freeipa-client oddjob-mkhomedir sssd authselect
else
    error "Не найден менеджер пакетов (dnf/yum)"
    exit 1
fi

# ========== ШАГ 3: ПРИСОЕДИНЕНИЕ К ДОМЕНУ ==========
log "3. Присоединение к домену FreeIPA..."

# Автоматическое присоединение без вопросов
ipa-client-install \
    --domain="$DOMAIN" \
    --server="$SERVER" \
    --mkhomedir \
    --enable-dns-updates \
    -U \
    -p "$ADMIN" \
    -w "$PASSWORD" \
    --force-join \
    --no-ntp \
    --unattended

if [ $? -eq 0 ]; then
    log "   ✓ Успешно присоединились к домену"
else
    error "   Ошибка присоединения к домену"
    echo "   Проверьте логи: tail -50 /var/log/ipaclient-install.log"
    exit 1
fi

# ========== ШАГ 4: НАСТРОЙКА SSSD ДЛЯ SUDO ==========
log "4. Настройка SSSD для загрузки sudo-правил из домена..."

# Создаём конфигурацию sudo в отдельном файле
mkdir -p /etc/sssd/conf.d
cat > /etc/sssd/conf.d/99-sudo.conf << 'EOF'
# Настройки sudo для FreeIPA
# Этот файл создан автоматически при присоединении к домену

[sudo]
# Включить поддержку sudo правил из FreeIPA
enabled = True

# База поиска sudo правил в LDAP (FreeIPA)
ldap_sudo_search_base = ou=sudoers,dc=s1210,dc=lan

# Кэширование правил с обновлением каждые 10 минут
sudo_timed = True
sudo_refresh_interval = 600

# Время жизни кэша при отсутствии соединения (24 часа)
sudo_cached_timeout = 86400

# Использовать интегрированную схему FreeIPA
ldap_sudo_use_host_filter = False
ldap_sudo_include_regexp = True
EOF

# Устанавливаем правильные права на файлы SSSD
chmod 600 /etc/sssd/conf.d/99-sudo.conf
chown root:root /etc/sssd/conf.d/99-sudo.conf

# Настройка основного sssd.conf для работы с sudo
if [ -f /etc/sssd/sssd.conf ]; then
    # Делаем backup
    cp /etc/sssd/sssd.conf /etc/sssd/sssd.conf.backup.$(date +%s)

    # Проверяем, есть ли уже секция [sudo]
    if ! grep -q "^\[sudo\]" /etc/sssd/sssd.conf; then
        # Добавляем настройки в существующий конфиг
        cat >> /etc/sssd/sssd.conf << 'EOF'

# Автоматически добавленные настройки для sudo из FreeIPA
[sudo]
enabled = True
ldap_sudo_search_base = ou=sudoers,dc=s1210,dc=lan
sudo_timed = True
sudo_refresh_interval = 600
EOF
    fi
fi

# ========== ШАГ 5: НАСТРОЙКА AUTHSELECT ==========
log "5. Настройка системы аутентификации..."

# Используем authselect для правильной настройки
if command -v authselect > /dev/null 2>&1; then
    authselect select sssd with-mkhomedir --force
    log "   ✓ Authselect настроен"
else
    warn "   ⚠ authselect не найден, используем ручную настройку"
    systemctl enable sssd
    systemctl enable oddjobd
fi

# ========== ШАГ 6: ПЕРЕЗАПУСК СЛУЖБ ==========
log "6. Перезапуск системных служб..."

systemctl restart sssd
systemctl restart oddjobd

# Включаем автозагрузку
systemctl enable sssd
systemctl enable oddjobd

# ========== ШАГ 7: ПРОВЕРКА ==========
log "7. Проверка конфигурации..."

echo ""
echo "--- ИНФОРМАЦИЯ О СИСТЕМЕ ---"
echo "Hostname: $(hostname -f)"
echo "Домен: $(hostname -d)"
echo ""
echo "--- НАСТРОЙКИ DNS ---"
cat /etc/resolv.conf
echo ""
echo "--- ПРОВЕРКА KERBEROS ---"

# Проверяем Kerberos
if echo "$PASSWORD" | kinit "$ADMIN" 2>/dev/null; then
    log "   ✓ Kerberos аутентификация работает"
    echo "   Билеты:"
    klist
    kdestroy
else
    warn "   ⚠ Не удалось получить Kerberos билет"
fi

# Проверяем работу SSSD
echo ""
echo "--- ПРОВЕРКА SSSD ---"
if systemctl is-active --quiet sssd; then
    log "   ✓ Служба SSSD активна"

    # Проверка доменных пользователей
    echo "   Тест поиска пользователя admin:"
    if id "admin@$DOMAIN" > /dev/null 2>&1; then
        log "   ✓ Доменный пользователь admin найден"
    else
        warn "   ⚠ Не удалось найти доменного пользователя admin"
    fi
else
    error "   Служба SSSD не активна"
fi

# ========== ШАГ 8: СОЗДАНИЕ ТЕСТОВОГО СКРИПТА ДЛЯ ПРОВЕРКИ ==========
log "8. Создание тестового скрипта проверки..."

cat > /tmp/test_sudo_access.sh << 'EOF'
#!/bin/bash
# Тест sudo доступа для доменных пользователей
# Запускать от доменного пользователя: ssh admin@хост '/tmp/test_sudo_access.sh'

DOMAIN="s1210.lan"
USER=$(whoami)

echo "=== Тест sudo доступа для $USER ==="
echo "Время: $(date)"
echo "Хост: $(hostname -f)"
echo ""

# Проверка sudo прав через SSSD
echo "1. Проверка загруженных sudo правил..."
if command -v sssctl > /dev/null 2>&1; then
    sssctl sudo-rules-list --user $USER 2>/dev/null | head -20
else
    echo "   sssctl не найден"
fi

echo ""
echo "2. Проверка sudo -l..."
sudo -l 2>/dev/null | grep -A10 "User $USER"

echo ""
echo "3. Тест выполнения sudo команды..."
if sudo -n whoami 2>/dev/null; then
    echo "   ✅ SUDO БЕЗ ПАРОЛЯ: РАБОТАЕТ"
    echo "   Пользователь может выполнять sudo без пароля"
else
    echo "   ❌ SUDO БЕЗ ПАРОЛЯ: НЕ РАБОТАЕТ"
    echo "   Требуется настройка правил sudo в FreeIPA"
fi

echo ""
echo "=== РЕКОМЕНДАЦИИ ==="
echo "Если sudo без пароля не работает:"
echo "1. На сервере FreeIPA убедитесь, что:"
echo "   - Создана группа 'ansible_admins'"
echo "   - Пользователь 'admin' в этой группе"
echo "   - Создано sudo правило с опцией '!authenticate'"
echo "2. На клиенте проверьте:"
echo "   - systemctl status sssd"
echo "   - journalctl -u sssd --since '5 minutes ago'"
EOF

chmod +x /tmp/test_sudo_access.sh
log "   ✓ Тестовый скрипт создан: /tmp/test_sudo_access.sh"

# ========== ШАГ 9: ИНСТРУКЦИЯ ==========
echo ""
echo "================================================"
echo "             НАСТРОЙКА ЗАВЕРШЕНА"
echo "================================================"
echo ""
echo "✅ Компьютер успешно присоединён к домену $DOMAIN"
echo ""
echo "ЧТО ДАЛЬШЕ:"
echo ""
echo "1. ПЕРЕЗАГРУЗИТЕ КОМПЬЮТЕР для применения всех настроек:"
echo "   sudo reboot"
echo ""
echo "2. После перезагрузки проверьте работу:"
echo "   а) Войдите как доменный пользователь:"
echo "      ssh admin@$(hostname -f)"
echo "   б) Запустите тестовый скрипт:"
echo "      /tmp/test_sudo_access.sh"
echo ""
echo "3. С СЕРВЕРА ROSA проверьте управление через Ansible:"
echo "   # На сервере rosa.s1210.lan:"
echo "   kinit admin  # пароль: qwe123!E!E"
echo "   ansible $(hostname -s).$DOMAIN -m ping -b"
echo ""
echo "4. ЕСЛИ SUDO НЕ РАБОТАЕТ БЕЗ ПАРОЛЯ:"
echo "   На сервере rosa выполните команды:"
cat << 'EOF'
   kinit admin
   # Создать группу и правило если ещё нет:
   ipa group-add ansible_admins --desc="Администраторы Ansible"
   ipa group-add-member --users=admin ansible_admins
   ipa sudorule-add ansible_sudo --hostcat=all --cmdcat=all
   ipa sudorule-add-user --groups=ansible_admins ansible_sudo
   ipa sudorule-mod --sudooption="!authenticate" ansible_sudo
EOF
echo ""
echo "================================================"
echo "Скрипт завершил работу в: $(date)"
echo "================================================"

# Автоматическая перезагрузка (закомментируйте если не нужно)
echo ""
read -p "Перезагрузить компьютер сейчас? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Перезагрузка через 10 секунд..."
    sleep 10
    reboot
fi
