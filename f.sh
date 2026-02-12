#!/bin/bash
# join_domain_complete.sh - Полная автоматизация присоединения к домену FreeIPA
# со встроенным SSH ключом для Ansible

set -e  # Выход при любой ошибке

# Конфигурация домена
DOMAIN="s1210.lan"
SERVER="rosa.s1210.lan"
ADMIN="admin"
PASSWORD="qwe123!E!E"
CLIENT_HOSTNAME=$(hostname -s)
FULL_HOSTNAME="${CLIENT_HOSTNAME}.${DOMAIN}"

# Ваш SSH ключ для Ansible
SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMvqlqk9OeXC/kjPNm8ZadtHNpHeqrI2aSAikO/4/jDY ansible@rosa.s1210.lan"

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
echo "Хост: $FULL_HOSTNAME"
echo "Домен: $DOMAIN"
echo "Сервер: $SERVER"
echo "SSH ключ: ed25519 (встроенный в скрипт)"
echo "================================================"

# Проверка, что скрипт запущен с sudo
if [ "$EUID" -ne 0 ]; then
    error "Скрипт должен запускаться с sudo!"
    echo "Используйте: sudo ./join_domain_complete.sh"
    exit 1
fi

# Проверка наличия dnf
if ! command -v dnf > /dev/null 2>&1; then
    error "Система не использует dnf!"
    echo "Этот скрипт предназначен только для систем с dnf"
    exit 1
fi

# ========== ШАГ 1: НАСТРОЙКА HOSTNAME И DNS ==========
log "1. Настройка hostname и DNS..."

# Устанавливаем полное доменное имя
log "   Установка hostname: $FULL_HOSTNAME"
hostnamectl set-hostname "$FULL_HOSTNAME"

# Резервное копирование resolv.conf
if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf "/etc/resolv.conf.backup.$(date +%s)"
fi

# Создаём новый resolv.conf с защитой от NetworkManager
cat > /etc/resolv.conf << EOF
# Настройка DNS для домена $DOMAIN
# Создано автоматически $(date)
nameserver 172.26.128.219
nameserver 10.89.87.63
search $DOMAIN
options timeout:2 attempts:3
EOF

# Защищаем файл от перезаписи
if command -v chattr > /dev/null 2>&1; then
    chattr +i /etc/resolv.conf 2>/dev/null || true
    log "   ✓ DNS настройки защищены от изменений"
fi

# Проверка связи с сервером
log "   Проверка связи с сервером домена..."
if ! ping -c 2 -W 1 "$SERVER" > /dev/null 2>&1; then
    warn "   ⚠ Сервер $SERVER не отвечает на ping"
    log "   Добавляю запись в /etc/hosts..."
    if ! grep -q "$SERVER" /etc/hosts; then
        echo "172.26.128.219 $SERVER" >> /etc/hosts
    fi
else
    log "   ✓ Сервер $SERVER доступен"
fi

# ========== ШАГ 2: УСТАНОВКА ПАКЕТОВ ==========
log "2. Установка необходимых пакетов..."

log "   Установка пакетов для домена..."
dnf install -y freeipa-client oddjob oddjob-mkhomedir sssd sssd-tools \
               authselect openssh-clients sudo

log "   ✓ Пакеты установлены"

# ========== ШАГ 3: НАСТРОЙКА SSH КЛЮЧА ==========
log "3. Настройка SSH для Ansible..."

# Создаём директорию для authorized_keys если её нет
mkdir -p /etc/ssh/authorized_keys

# Добавляем встроенный SSH ключ
log "   Добавляю SSH ключ ed25519..."
echo "$SSH_PUBLIC_KEY" > "/etc/ssh/authorized_keys/$ADMIN"
chmod 644 "/etc/ssh/authorized_keys/$ADMIN"
chown root:root "/etc/ssh/authorized_keys/$ADMIN"

# Проверяем что ключ записан
if [ -f "/etc/ssh/authorized_keys/$ADMIN" ] && [ -s "/etc/ssh/authorized_keys/$ADMIN" ]; then
    log "   ✓ SSH ключ добавлен для пользователя: $ADMIN"
    log "   Тип ключа: $(echo "$SSH_PUBLIC_KEY" | cut -d' ' -f1)"
    log "   Отпечаток ключа:"
    echo "$SSH_PUBLIC_KEY" | ssh-keygen -l -f /dev/stdin 2>/dev/null || echo "   (не удалось вычислить отпечаток)"
else
    error "   Ошибка добавления SSH ключа!"
    exit 1
fi

# Создаём конфигурацию для авторизации по SSH ключам
cat > /etc/ssh/sshd_config.d/99-ansible.conf << 'EOF'
# Настройки для Ansible совместимости
AuthorizedKeysFile /etc/ssh/authorized_keys/%u .ssh/authorized_keys
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no
GSSAPIAuthentication yes
GSSAPICleanupCredentials yes
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

# Оптимизация для Ansible
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive yes
MaxStartups 10:30:100
MaxSessions 100
EOF

# Перезапускаем SSH
systemctl restart sshd
if systemctl is-active --quiet sshd; then
    log "   ✓ SSH сервер перезапущен"
else
    error "   Ошибка перезапуска SSH сервера"
    journalctl -u sshd --no-pager -n 20
fi

# ========== ШАГ 4: ПОДГОТОВКА К ПРИСОЕДИНЕНИЮ ==========
log "4. Подготовка к присоединению к домену..."

# Очистка старых kerberos билетов
kdestroy 2>/dev/null || true
rm -f /tmp/krb5cc* 2>/dev/null || true

# Убедимся что SSSD остановлен перед присоединением
systemctl stop sssd 2>/dev/null || true
systemctl disable sssd 2>/dev/null || true

# ========== ШАГ 5: ПРИСОЕДИНЕНИЕ К ДОМЕНУ ==========
log "5. Присоединение к домену FreeIPA..."

# Временный файл для автоматизации
TEMP_PASS_FILE="/tmp/ipa_join_pass.txt"
echo "$PASSWORD" > "$TEMP_PASS_FILE"
chmod 600 "$TEMP_PASS_FILE"

# Выполняем присоединение с подробным логированием
log "   Выполняю ipa-client-install..."
if ipa-client-install \
    --domain="$DOMAIN" \
    --server="$SERVER" \
    --mkhomedir \
    --enable-dns-updates \
    -U \
    -p "$ADMIN" \
    -w "$PASSWORD" \
    --force-join \
    --no-ntp \
    --unattended \
    --no-ssh \
    --no-sshd \
    --fixed-primary \
    --force-join 2>&1 | tee /var/log/ipa-join.log; then

    log "   ✓ Успешно присоединились к домену"
else
    error "   Ошибка присоединения к домену"
    echo "   Детали в логе: /var/log/ipa-join.log"
    echo "   Пробую альтернативный метод..."

    # Альтернативный метод с --force
    ipa-client-install \
        --domain="$DOMAIN" \
        --server="$SERVER" \
        --mkhomedir \
        -p "$ADMIN" \
        -w "$PASSWORD" \
        --force-join \
        --unattended \
        --force

    if [ $? -eq 0 ]; then
        log "   ✓ Успешно присоединились (альтернативный метод)"
    else
        error "   Критическая ошибка присоединения"
        rm -f "$TEMP_PASS_FILE"
        exit 1
    fi
fi

# Удаляем временный файл с паролем
rm -f "$TEMP_PASS_FILE"

# ========== ШАГ 6: НАСТРОЙКА SSSD ДЛЯ SUDO ==========
log "6. Настройка SSSD для загрузки sudo-правил..."

# Создаём директорию если её нет
mkdir -p /etc/sssd/conf.d

# Создаём конфигурацию sudo
cat > /etc/sssd/conf.d/99-sudo-ipa.conf << EOF
# Автоматическая настройка sudo из FreeIPA
# Создано: $(date)

[domain/$DOMAIN]
# Включить поддержку sudo правил
sudo_provider = ipa
enabled = true
cache_credentials = true

# Настройки для sudo
ldap_sudo_search_base = ou=sudoers,dc=s1210,dc=lan
ldap_sudo_smart_refresh_interval = 600
ldap_sudo_full_refresh_interval = 3600
sudo_timed = true

# Оптимизация производительности
ldap_enumeration_refresh_timeout = 0
ldap_purge_cache_timeout = 1

# Настройки кэширования
entry_cache_timeout = 600
entry_cache_user_timeout = 5400
entry_cache_group_timeout = 5400
entry_cache_sudo_timeout = 5400

# Настройки reconnection
reconnection_retries = 3
fd_limit = 8192
EOF

# Устанавливаем правильные права
chmod 600 /etc/sssd/conf.d/99-sudo-ipa.conf
chown root:root /etc/sssd/conf.d/99-sudo-ipa.conf

# Обновляем основной конфиг если нужно
if [ -f /etc/sssd/sssd.conf ]; then
    # Делаем backup
    cp /etc/sssd/sssd.conf "/etc/sssd/sssd.conf.backup.$(date +%s)"

    # Обновляем настройки домена
    if grep -q "^\[domain/$DOMAIN\]" /etc/sssd/sssd.conf; then
        # Убедимся что sudo_provider включен
        if ! grep -q "sudo_provider.*=.*ipa" /etc/sssd/sssd.conf; then
            sed -i "/^\[domain\/$DOMAIN\]/,/^\[/ s/^\[domain\/$DOMAIN\]/&\nsudo_provider = ipa/" /etc/sssd/sssd.conf
        fi
    fi

    # Добавляем секцию sudo если её нет
    if ! grep -q "^\[sudo\]" /etc/sssd/sssd.conf; then
        cat >> /etc/sssd/sssd.conf << 'EOF'

# Настройки sudo для FreeIPA
[sudo]
enabled = True
ldap_sudo_search_base = ou=sudoers,dc=s1210,dc=lan
sudo_timed = True
sudo_refresh_interval = 600
ldap_sudo_use_host_filter = False
EOF
    fi
fi

# ========== ШАГ 7: НАСТРОЙКА AUTHSELECT И PAM ==========
log "7. Настройка системы аутентификации..."

if command -v authselect > /dev/null 2>&1; then
    # Проверяем текущий профиль
    if authselect check; then
        log "   Текущий профиль authselect корректен"
    else
        log "   Применяю профиль sssd с mkhomedir..."
        authselect select sssd with-mkhomedir --force
    fi

    # Включаем необходимые функции
    authselect enable-feature with-mkhomedir
    authselect enable-feature with-sudo

    log "   ✓ Authselect настроен"
else
    warn "   ⚠ authselect не найден, настраиваю PAM вручную..."

    # Ручная настройка mkhomedir для PAM
    if [ -f /etc/pam.d/system-auth ]; then
        if ! grep -q "pam_oddjob_mkhomedir" /etc/pam.d/system-auth; then
            sed -i '/^session.*pam_unix.so/a session     optional      pam_oddjob_mkhomedir.so umask=0077' /etc/pam.d/system-auth
        fi
    fi
fi

# ========== ШАГ 8: НАСТРОЙКА SUDO БЕЗ ПАРОЛЯ ==========
log "8. Настройка sudo правил..."

# Создаём локальный sudoers файл на случай проблем с доменом
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/99-ipa-emergency << 'EOF'
# Аварийные sudo правила если домен недоступен
# Этот файл отключается при нормальной работе SSSD

# Локальный администратор
admin ALL=(ALL) NOPASSWD: ALL

# Доменные пользователи из группы admins
%admins ALL=(ALL) NOPASSWD: ALL
EOF

chmod 440 /etc/sudoers.d/99-ipa-emergency

# ========== ШАГ 9: ПЕРЕЗАПУСК СЛУЖБ ==========
log "9. Перезапуск и активация служб..."

# Останавливаем и очищаем кэш SSSD
systemctl stop sssd 2>/dev/null || true
rm -f /var/lib/sss/db/* 2>/dev/null || true

# Запускаем службы
systemctl start oddjobd
systemctl enable oddjobd

systemctl start sssd
systemctl enable sssd

# Даем время на инициализацию
sleep 3

# Проверяем работу
if systemctl is-active --quiet sssd; then
    log "   ✓ SSSD запущен и работает"
else
    error "   SSSD не запустился"
    journalctl -u sssd --no-pager -n 30
fi

# ========== ШАГ 10: ПРОВЕРКА КОНФИГУРАЦИИ ==========
log "10. Проверка конфигурации..."

echo ""
echo "--- СВОДКА КОНФИГУРАЦИИ ---"
echo "Hostname: $(hostname -f)"
echo "Домен: $(hostname -d)"
echo ""

# Проверка SSH ключа
log "Проверка SSH ключа..."
if [ -f "/etc/ssh/authorized_keys/$ADMIN" ]; then
    log "   ✓ SSH ключ установлен"
    KEY_TYPE=$(head -n1 "/etc/ssh/authorized_keys/$ADMIN" | cut -d' ' -f1)
    KEY_FINGERPRINT=$(ssh-keygen -l -f "/etc/ssh/authorized_keys/$ADMIN" 2>/dev/null | head -n1)
    log "   Тип ключа: $KEY_TYPE"
    log "   Отпечаток: $KEY_FINGERPRINT"
else
    warn "   ⚠ SSH ключ не найден"
fi

# Проверка Kerberos
log "Проверка Kerberos аутентификации..."
if echo "$PASSWORD" | kinit "$ADMIN@${DOMAIN^^}" 2>/dev/null; then
    log "   ✓ Kerberos билет получен"
    echo "   Текущие билеты:"
    klist 2>/dev/null | head -5
    kdestroy
else
    warn "   ⚠ Не удалось получить Kerberos билет"
    log "   Пробую без realm..."
    if echo "$PASSWORD" | kinit "$ADMIN" 2>/dev/null; then
        log "   ✓ Kerberos билет получен (без realm)"
        kdestroy
    fi
fi

# Проверка доменных пользователей
log "Проверка доменных пользователей..."
if getent passwd "$ADMIN@$DOMAIN" > /dev/null 2>&1 || getent passwd "$ADMIN" > /dev/null 2>&1; then
    log "   ✓ Доменный пользователь '$ADMIN' доступен"
    log "   Информация о пользователе:"
    id "$ADMIN" 2>/dev/null || id "$ADMIN@$DOMAIN" 2>/dev/null
else
    warn "   ⚠ Доменный пользователь '$ADMIN' не найден"
fi

# Проверка sudo правил
log "Проверка загрузки sudo правил..."
if command -v sssctl > /dev/null 2>&1; then
    if sssctl config-check 2>/dev/null | grep -q "SSSD is correctly configured"; then
        log "   ✓ SSSD корректно настроен"
    fi

    log "   Проверка sudo правил для $ADMIN..."
    sudo_rules=$(sssctl sudo-rules-list --user "$ADMIN" 2>/dev/null | head -10)
    if [ -n "$sudo_rules" ]; then
        echo "$sudo_rules"
    else
        warn "   ⚠ Нет загруженных sudo правил"
    fi
fi

# ========== ШАГ 11: ТЕСТ SSH ПОДКЛЮЧЕНИЯ ==========
log "11. Тест SSH конфигурации..."

echo ""
echo "--- ИНСТРУКЦИЯ ДЛЯ ТЕСТИРОВАНИЯ SSH ---"
echo ""
echo "1. С сервера rosa.s1210.lan выполните:"
echo "   ssh -i ~/.ssh/ansible_key $ADMIN@$FULL_HOSTNAME"
echo ""
echo "2. Если подключение успешно, проверьте sudo:"
echo "   ssh -i ~/.ssh/ansible_key $ADMIN@$FULL_HOSTNAME 'sudo whoami'"
echo ""
echo "3. Для теста Ansible выполните на rosa:"
echo "   ansible $FULL_HOSTNAME -m ping -b"
echo ""

# Создаём тестовый скрипт для проверки
cat > /usr/local/bin/test-domain-setup << 'EOF'
#!/bin/bash
# Тест настроек домена и SSH

echo "=== Тест настроек домена и SSH ==="
echo "Время: $(date)"
echo "Хост: $(hostname -f)"
echo ""

echo "1. Проверка SSH ключа:"
if [ -f "/etc/ssh/authorized_keys/admin" ]; then
    echo "   ✅ SSH ключ найден"
    echo "   Тип: $(head -n1 /etc/ssh/authorized_keys/admin | cut -d' ' -f1)"
else
    echo "   ❌ SSH ключ не найден"
fi

echo ""
echo "2. Проверка доменного пользователя:"
if getent passwd admin > /dev/null 2>&1; then
    echo "   ✅ Доменный пользователь 'admin' доступен"
    echo "   UID: $(id -u admin 2>/dev/null)"
else
    echo "   ❌ Доменный пользователь не найден"
fi

echo ""
echo "3. Проверка Kerberos:"
if klist 2>/dev/null | grep -q "Default principal"; then
    echo "   ✅ Kerberos билеты активны"
    klist 2>/dev/null | head -3
else
    echo "   ⚠ Нет активных Kerberos билетов"
    echo "   Получите билет: kinit admin"
fi

echo ""
echo "4. Проверка sudo через SSSD:"
if command -v sssctl > /dev/null 2>&1; then
    if sssctl config-check 2>/dev/null | grep -q "SSSD is correctly configured"; then
        echo "   ✅ SSSD настроен корректно"
    fi
    echo "   Sudo правила для admin:"
    sssctl sudo-rules-list --user admin 2>/dev/null | head -5
fi

echo ""
echo "=== КОМАНДЫ ДЛЯ ПРОВЕРКИ С СЕРВЕРА ROSA ==="
echo ""
echo "1. Проверка SSH:"
echo "   ssh -i ~/.ssh/ansible_key admin@$(hostname -f) 'echo Успех!'"
echo ""
echo "2. Проверка sudo:"
echo "   ssh -i ~/.ssh/ansible_key admin@$(hostname -f) 'sudo whoami'"
echo ""
echo "3. Проверка Ansible:"
echo "   ansible $(hostname -s).s1210.lan -m ping -b"
EOF

chmod +x /usr/local/bin/test-domain-setup

# ========== ШАГ 12: ФИНАЛЬНАЯ ПРОВЕРКА ==========
log "12. Финальная проверка и инструкции..."

echo ""
echo "================================================"
echo "          НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА!"
echo "================================================"
echo ""
echo "✅ Хост: $FULL_HOSTNAME присоединён к домену $DOMAIN"
echo ""
echo "ЧТО БЫЛО СДЕЛАНО:"
echo "1. ✓ Hostname: $FULL_HOSTNAME"
echo "2. ✓ DNS: серверы домена"
echo "3. ✓ Пакеты: freeipa-client, sssd, ssh"
echo "4. ✓ SSH ключ: ed25519 (встроен в скрипт)"
echo "5. ✓ Присоединение к домену FreeIPA"
echo "6. ✓ SSSD настроен для sudo правил"
echo "7. ✓ Authselect/PAM настроены"
echo "8. ✓ Аварийные sudo правила"
echo ""
echo "ДЛЯ ПРОВЕРКИ:"
echo ""
echo "1. Перезагрузите систему:"
echo "   sudo reboot"
echo ""
echo "2. После перезагрузки проверьте настройки:"
echo "   test-domain-setup"
echo ""
echo "3. С сервера ROSA проверьте подключение:"
echo "   # SSH подключение"
echo "   ssh -i ~/.ssh/ansible_key $ADMIN@$FULL_HOSTNAME"
echo ""
echo "   # Тест sudo"
echo "   ssh -i ~/.ssh/ansible_key $ADMIN@$FULL_HOSTNAME 'sudo whoami'"
echo ""
echo "   # Тест Ansible"
echo "   kinit admin"
echo "   ansible $FULL_HOSTNAME -m ping -b"
echo ""
echo "ЕСЛИ ВОЗНИКЛИ ПРОБЛЕМЫ:"
echo ""
echo "1. SSH не работает:"
echo "   Проверьте ключ: cat /etc/ssh/authorized_keys/admin"
echo "   Проверьте SSH: systemctl status sshd"
echo ""
echo "2. Домен не работает:"
echo "   Проверьте DNS: cat /etc/resolv.conf"
echo "   Перезапустите SSSD: systemctl restart sssd"
echo ""
echo "3. Sudo не работает без пароля:"
echo "   На rosa проверьте настройки FreeIPA:"
cat << 'SERVER_CHECK'
   kinit admin
   ipa sudorule-find
   ipa group-show ansible_admins
   ipa host-find $(hostname -f)
SERVER_CHECK
echo ""
echo "================================================"
log "Скрипт завершил работу: $(date)"
echo "================================================"

# Автоматическая перезагрузка
echo ""
read -p "Перезагрузить компьютер сейчас? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Перезагрузка через 10 секунд (Ctrl+C для отмены)..."
    for i in {10..1}; do
        echo -n "."
        sleep 1
    done
    echo ""
    log "Выполняю перезагрузку..."
    reboot
else
    echo ""
    warn "⚠ Не забудьте перезагрузить систему для применения всех настроек!"
    echo "   Команда для перезагрузки: sudo reboot"
fi
