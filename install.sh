#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALL_DIR="/opt/discord-door-bot"
readonly VENV_DIR="${INSTALL_DIR}/.venv"
readonly ENV_FILE="/etc/discord-door-bot.env"
readonly SERVICE_FILE="/etc/systemd/system/doorbot.service"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

REBOOT_REQUIRED=0
SERIAL_ACTION="不需變更"

log() {
    printf '[doorbot] %s\n' "$*"
}

warn() {
    printf '[doorbot] 警告：%s\n' "$*" >&2
}

die() {
    printf '[doorbot] 錯誤：%s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：sudo bash install.sh

這是互動式安裝器，會詢問 Discord Bot Token、Guild ID 與伺服馬達設定。
Token 輸入時不會顯示，也不提供可寫入 shell history 的命令列參數。

選項：
  -h, --help    顯示此說明
EOF
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            [[ $# -eq 1 ]] || die "--help 不可搭配其他參數"
            usage
            exit 0
            ;;
        *)
            die "此安裝器不接受部署參數；請直接執行 sudo bash install.sh"
            ;;
    esac
fi

[[ -f "${SCRIPT_DIR}/door_bot.py" ]] || die "找不到 door_bot.py"
[[ -f "${SCRIPT_DIR}/requirements.txt" ]] || die "找不到 requirements.txt"
[[ -f "${SCRIPT_DIR}/doorbot.service.template" ]] || \
    die "找不到 doorbot.service.template"

[[ "$EUID" -eq 0 ]] || die "請使用 sudo bash install.sh 執行安裝"

RUN_USER="${SUDO_USER:-}"
[[ -n "$RUN_USER" && "$RUN_USER" != "root" ]] || \
    die "請從一般登入帳號使用 sudo 執行，不要直接以 root 登入安裝"
id "$RUN_USER" >/dev/null 2>&1 || die "找不到服務執行帳號：${RUN_USER}"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || id -g "$RUN_USER")"

command -v apt-get >/dev/null || die "找不到 apt-get；本專案需要 Raspberry Pi OS 或 Debian"
command -v systemctl >/dev/null || die "找不到 systemctl；本專案需要 systemd"
command -v python3 >/dev/null || die "找不到 python3"
getent group gpio >/dev/null || die "找不到 gpio 群組；請使用 Raspberry Pi OS"

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
    debian|raspbian) ;;
    *) warn "本專案以 Raspberry Pi OS/Debian 為目標，目前偵測到 ${ID:-未知系統}" ;;
esac
case "$(uname -m)" in
    armv7l|aarch64|arm64) ;;
    *) warn "目前不是 ARM 架構，GPIO 預期無法正常運作" ;;
esac

read_existing_value() {
    local key="$1"
    [[ -r "$ENV_FILE" ]] || return 0
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

ask_yes_no() {
    local prompt="$1"
    local default_answer="$2"
    local suffix answer

    if [[ "$default_answer" == "yes" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    while true; do
        read -r -p "${prompt} ${suffix}: " answer || die "無法讀取輸入"
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            "")
                [[ "$default_answer" == "yes" ]] && return 0
                return 1
                ;;
            *) printf '請輸入 y 或 n。\n' ;;
        esac
    done
}

prompt_value() {
    local variable_name="$1"
    local label="$2"
    local default_value="$3"
    local answer

    read -r -p "${label} [${default_value}]: " answer || die "無法讀取輸入"
    printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

prompt_required() {
    local variable_name="$1"
    local label="$2"
    local answer

    while true; do
        read -r -p "${label}: " answer || die "無法讀取輸入"
        if [[ -n "$answer" ]]; then
            printf -v "$variable_name" '%s' "$answer"
            return
        fi
        printf '%s 不可留空。\n' "$label"
    done
}

prompt_secret() {
    local answer

    while true; do
        read -r -s -p 'Discord Bot Token（輸入時不顯示）: ' answer || \
            die "無法讀取 Token"
        printf '\n'
        if [[ -n "$answer" ]]; then
            TOKEN="$answer"
            return
        fi
        printf 'Discord Bot Token 不可留空。\n'
    done
}

show_servo_settings() {
    log "伺服馬達設定："
    log "  BCM GPIO：${SERVO_GPIO_VALUE}"
    log "  角度範圍：${SERVO_MIN_VALUE} 到 ${SERVO_MAX_VALUE} 度"
    log "  待機／開鎖角度：${SERVO_REST_VALUE} / ${SERVO_OPEN_VALUE} 度"
    log "  開鎖保持／復位等待：${SERVO_HOLD_VALUE} / ${SERVO_RETURN_VALUE} 秒"
}

EXISTING_TOKEN="$(read_existing_value DISCORD_BOT_TOKEN)"
if [[ -n "$EXISTING_TOKEN" ]] && \
    ask_yes_no "發現既有 Token，是否繼續使用？" "yes"; then
    TOKEN="$EXISTING_TOKEN"
else
    prompt_secret
fi

GUILD_ID="$(read_existing_value DISCORD_GUILD_ID)"
if [[ -n "$GUILD_ID" ]]; then
    prompt_value GUILD_ID "Discord Guild ID" "$GUILD_ID"
else
    prompt_required GUILD_ID "Discord Guild ID"
fi

SERVO_GPIO_VALUE="$(read_existing_value SERVO_GPIO)"
SERVO_MIN_VALUE="$(read_existing_value SERVO_MIN_ANGLE)"
SERVO_MAX_VALUE="$(read_existing_value SERVO_MAX_ANGLE)"
SERVO_REST_VALUE="$(read_existing_value SERVO_REST_ANGLE)"
SERVO_OPEN_VALUE="$(read_existing_value SERVO_OPEN_ANGLE)"
SERVO_HOLD_VALUE="$(read_existing_value SERVO_HOLD_SECONDS)"
SERVO_RETURN_VALUE="$(read_existing_value SERVO_RETURN_SECONDS)"

SERVO_GPIO_VALUE="${SERVO_GPIO_VALUE:-14}"
SERVO_MIN_VALUE="${SERVO_MIN_VALUE:-0}"
SERVO_MAX_VALUE="${SERVO_MAX_VALUE:-90}"
SERVO_REST_VALUE="${SERVO_REST_VALUE:-0}"
SERVO_OPEN_VALUE="${SERVO_OPEN_VALUE:-37}"
SERVO_HOLD_VALUE="${SERVO_HOLD_VALUE:-0.5}"
SERVO_RETURN_VALUE="${SERVO_RETURN_VALUE:-0.5}"

show_servo_settings
if ! ask_yes_no "是否直接使用以上設定？" "yes"; then
    prompt_value SERVO_GPIO_VALUE "BCM GPIO" "$SERVO_GPIO_VALUE"
    prompt_value SERVO_MIN_VALUE "最小角度" "$SERVO_MIN_VALUE"
    prompt_value SERVO_MAX_VALUE "最大角度" "$SERVO_MAX_VALUE"
    prompt_value SERVO_REST_VALUE "待機角度" "$SERVO_REST_VALUE"
    prompt_value SERVO_OPEN_VALUE "開鎖角度" "$SERVO_OPEN_VALUE"
    prompt_value SERVO_HOLD_VALUE "維持開鎖角度秒數" "$SERVO_HOLD_VALUE"
    prompt_value SERVO_RETURN_VALUE "復位後等待秒數" "$SERVO_RETURN_VALUE"
fi

[[ "$TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "Discord Bot Token 含有非預期字元"
[[ "$GUILD_ID" =~ ^[0-9]+$ && "$GUILD_ID" != "0" ]] || \
    die "Discord Guild ID 必須是正整數"
[[ "$SERVO_GPIO_VALUE" =~ ^[0-9]+$ ]] || die "GPIO 必須是整數"
(( SERVO_GPIO_VALUE >= 0 && SERVO_GPIO_VALUE <= 27 )) || \
    die "GPIO 必須是 0 到 27 之間的 BCM 編號"

is_number() {
    [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

for value in \
    "$SERVO_MIN_VALUE" "$SERVO_MAX_VALUE" "$SERVO_REST_VALUE" \
    "$SERVO_OPEN_VALUE" "$SERVO_HOLD_VALUE" "$SERVO_RETURN_VALUE"; do
    is_number "$value" || die "角度與等待時間必須是一般數字"
done

awk -v min="$SERVO_MIN_VALUE" -v max="$SERVO_MAX_VALUE" \
    'BEGIN { exit !(min < max) }' || die "最小角度必須小於最大角度"
for pair in "待機:$SERVO_REST_VALUE" "開鎖:$SERVO_OPEN_VALUE"; do
    label="${pair%%:*}"
    value="${pair#*:}"
    awk -v value="$value" -v min="$SERVO_MIN_VALUE" -v max="$SERVO_MAX_VALUE" \
        'BEGIN { exit !(value >= min && value <= max) }' || \
        die "${label}角度必須介於最小與最大角度之間"
done
for pair in "開鎖:$SERVO_HOLD_VALUE" "復位:$SERVO_RETURN_VALUE"; do
    label="${pair%%:*}"
    value="${pair#*:}"
    awk -v value="$value" 'BEGIN { exit !(value >= 0) }' || \
        die "${label}等待時間不可為負數"
done

serial_conflicts_with_gpio14() {
    grep -Eq '(^|[[:space:]])console=(serial0|ttyAMA0|ttyS0),' \
        /boot/firmware/cmdline.txt 2>/dev/null ||
        grep -Eq '^[[:space:]]*enable_uart=1([[:space:]]|$)' \
            /boot/firmware/config.txt 2>/dev/null ||
        systemctl is-enabled serial-getty@serial0.service >/dev/null 2>&1 ||
        systemctl is-enabled serial-getty@ttyAMA0.service >/dev/null 2>&1 ||
        systemctl is-enabled serial-getty@ttyS0.service >/dev/null 2>&1
}

if [[ "$SERVO_GPIO_VALUE" == "14" ]] && serial_conflicts_with_gpio14; then
    warn "GPIO14 與 serial console 或 UART 衝突，開機訊號可能使 SG90 轉動"
    if ask_yes_no "是否由安裝器停用 serial console 與 UART hardware？" "yes"; then
        command -v raspi-config >/dev/null || \
            die "找不到 raspi-config，無法安全停用 serial/UART"
        SERIAL_ACTION="停用 serial console 與 UART hardware"
        REBOOT_REQUIRED=1
    else
        SERIAL_ACTION="保留 serial/UART（GPIO14 可能在開機時輸出訊號）"
    fi
fi

log "安裝摘要："
log "  服務帳號：${RUN_USER}"
log "  Discord Guild ID：${GUILD_ID}"
show_servo_settings
log "  serial/UART：${SERIAL_ACTION}"
log "  Bot Token：已提供（內容不顯示）"

if ! ask_yes_no "確認開始安裝？" "yes"; then
    unset TOKEN EXISTING_TOKEN
    log "已取消，系統未做任何變更"
    exit 0
fi

if [[ "$REBOOT_REQUIRED" -eq 1 ]]; then
    log "正在停用 serial console 與 UART hardware"
    raspi-config nonint do_serial_cons 1
    raspi-config nonint do_serial_hw 1
fi

log "正在安裝 Raspberry Pi OS 套件（不執行完整系統升級）"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    python3-pip python3-venv python3-dev build-essential swig liblgpio-dev

if systemctl list-unit-files doorbot.service >/dev/null 2>&1; then
    systemctl stop doorbot.service || true
fi

log "正在安裝程式至 ${INSTALL_DIR}"
install -d -o root -g root -m 0755 "$INSTALL_DIR"
install -o root -g root -m 0644 "$SCRIPT_DIR/door_bot.py" "$INSTALL_DIR/door_bot.py"
install -o root -g root -m 0644 \
    "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install --upgrade \
    -r "$INSTALL_DIR/requirements.txt"

umask 077
env_temp="$(mktemp)"
service_temp="$(mktemp)"
cleanup() {
    rm -f "$env_temp" "$service_temp"
}
trap cleanup EXIT

{
    printf 'DISCORD_BOT_TOKEN=%s\n' "$TOKEN"
    printf 'DISCORD_GUILD_ID=%s\n' "$GUILD_ID"
    printf 'SERVO_GPIO=%s\n' "$SERVO_GPIO_VALUE"
    printf 'SERVO_MIN_ANGLE=%s\n' "$SERVO_MIN_VALUE"
    printf 'SERVO_MAX_ANGLE=%s\n' "$SERVO_MAX_VALUE"
    printf 'SERVO_REST_ANGLE=%s\n' "$SERVO_REST_VALUE"
    printf 'SERVO_OPEN_ANGLE=%s\n' "$SERVO_OPEN_VALUE"
    printf 'SERVO_HOLD_SECONDS=%s\n' "$SERVO_HOLD_VALUE"
    printf 'SERVO_RETURN_SECONDS=%s\n' "$SERVO_RETURN_VALUE"
} >"$env_temp"
install -o root -g root -m 0600 "$env_temp" "$ENV_FILE"

sed \
    -e "s/@RUN_USER@/${RUN_USER}/g" \
    -e "s/@RUN_GROUP@/${RUN_GROUP}/g" \
    "$SCRIPT_DIR/doorbot.service.template" >"$service_temp"
install -o root -g root -m 0644 "$service_temp" "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable doorbot.service

unset TOKEN EXISTING_TOKEN DISCORD_BOT_TOKEN

if [[ "$REBOOT_REQUIRED" -eq 1 ]]; then
    log "安裝完成；doorbot.service 已設為開機啟動"
    warn "GPIO14 的 serial/UART 設定已變更，請執行 sudo reboot"
else
    if systemctl restart doorbot.service && \
        systemctl is-active --quiet doorbot.service; then
        log "安裝完成，doorbot.service 已啟動"
    else
        warn "doorbot.service 未成功啟動，請使用以下命令查看原因："
        warn "  sudo systemctl status doorbot.service"
        warn "  sudo journalctl -u doorbot.service -n 100 --no-pager"
        systemctl status doorbot.service --no-pager || true
        exit 1
    fi
fi

if command -v vcgencmd >/dev/null; then
    power_state="$(vcgencmd get_throttled 2>/dev/null || true)"
    if [[ -n "$power_state" ]]; then
        log "Raspberry Pi 電源狀態：${power_state}"
        [[ "$power_state" == "throttled=0x0" ]] || \
            warn "非零狀態可能代表目前或本次開機期間曾發生欠壓或降頻"
    fi
fi

log "設定已儲存至 ${ENV_FILE}，權限為 0600"
log "Discord 使用權限請至 Server Settings > Integrations 管理"
