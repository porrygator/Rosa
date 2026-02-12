#!/bin/bash
# Быстрый вывод из домена

echo "Вывод из домена S1210.LAN..."

# 1. Удаление IPA клиента
sudo ipa-client-install --uninstall -U 2>/dev/null || echo "IPA клиент удален"

# 2. Очистка Kerberos
sudo rm -f /etc/krb5.conf /etc/krb5.keytab 2>/dev/null

# 3. Очистка SSSD
sudo systemctl stop sssd 2>/dev/null
sudo rm -f /etc/sssd/sssd.conf 2>/dev/null
sudo systemctl disable sssd 2>/dev/null

# 4. Сброс DNS
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo rm -f /etc/resolv.conf 2>/dev/null || true

# 5. Возврат к локальной аутентификации
sudo authselect select minimal --force 2>/dev/null || true

# 6. Перезапуск NetworkManager
sudo systemctl restart NetworkManager 2>/dev/null || true

echo "Готово! Перезагрузите компьютер."
