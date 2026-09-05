# Discord Door Bot

Use a Raspberry Pi and an SG90 servo to add Discord-based remote control to a traditional mechanical door lock without modifying its existing card reader or electrical wiring. The project provides a guided installer for a quick setup and a complete manual DIY path for learning each deployment step.

本專案使用 Raspberry Pi 搭配 SG90 伺服馬達，以繩索拉動傳統電鎖內的機械開門結構。使用者可在指定的 Discord 伺服器執行 `/open`，不需要改動原有讀卡機或電鎖線路。

> [!WARNING]
> 本裝置僅屬門禁輔助，只應安裝於你有權管理的門上，且不得影響消防逃生、門鎖機構、原讀卡機或鑰匙之正常功能。

## 成果展示

<p align="center">
  <img src="Result_Images/IMG_1.jpg" alt="Raspberry Pi 與 SG90 安裝在傳統電鎖旁的完成外觀" width="48%">
  <img src="Result_Images/IMG_2.jpg" alt="打開電鎖外蓋後可看見 SG90 繩索與內部機械結構" width="48%">
</p>

左圖是安裝完成的外觀；右圖展示 SG90 如何透過繩索拉動電鎖內部機構。

## 運作原理

```mermaid
flowchart LR
    U[Discord 使用者] -->|Guild 專用 /open| D[Discord]
    D -->|Gateway 連線| B[Python Discord Bot]
    B -->|gpiozero 與 rpi-lgpio| G[BCM GPIO14]
    G --> S[SG90 伺服馬達]
    S -->|拉動繩索| L[電鎖機械開門結構]
```

SG90 固定在電鎖附近，馬達搖臂以不易延展的繩索連接原有機械開門結構。收到 `/open` 後，馬達轉到開鎖角度、短暫停留，再回到待機角度並停止 PWM 輸出。

主要特性：

- `/open` 只同步到一個指定的 Discord 伺服器，不提供私訊或全域指令。
- Discord 回覆採用 ephemeral 訊息，只有指令呼叫者看得到。
- 同一時間只執行一個開鎖動作，避免重複請求互相干擾。
- 動作失敗時仍會嘗試歸位並停止 PWM 輸出。
- Token 與角度存放在 Git 以外、權限為 `0600` 的系統設定檔。
- systemd 會在樹莓派開機後啟動 Bot，並在程式異常結束時重新啟動。

本專案沒有門位或鎖舌感測器，因此「解鎖動作已完成」只代表伺服馬達控制流程已結束，不代表門鎖一定已實際開啟。

## 硬體材料與機構

- Raspberry Pi 3B+，或其他具有 40-pin GPIO 排針的 Raspberry Pi
- Raspberry Pi OS Lite 64-bit
- SG90 伺服馬達
- 不易延展的繩索，例如 PE 釣魚線
- SG90 搖臂與螺絲
- 支架、束帶或適合現場材質的固定零件
- MicroSD 卡與符合 Raspberry Pi 規格的電源供應器
- 杜邦線，或經確認腳位後重新排列的三芯伺服接頭
- 選配：獨立 5V 伺服馬達電源

固定馬達時，先保留原本按鈕、鎖舌與讀卡機的活動空間。繩索在待機位置應保持放鬆，馬達轉動後才拉動機構；不要讓 SG90 長時間頂住機械極限或持續發出堵轉聲。

## 接線與供電

> [!CAUTION]
> 接線或重新排列接頭前，必須先關閉 Raspberry Pi 與外部電源。SG90 線色並非絕對標準，請同時核對馬達標示與資料表。

程式採用 **BCM 編號**。預設訊號腳位為 BCM GPIO14，也就是 40-pin 排針的實體 Pin 8。

| SG90 功能 | 常見線色 | Raspberry Pi 接點 | 實體 Pin |
| --- | --- | --- | ---: |
| PWM 訊號 | 橘色或黃色 | BCM GPIO14 | 8 |
| 5V 電源 | 紅色 | 5V，或外部 5V 正極 | 4 |
| GND | 棕色或黑色 | GND | 6 |

### SG90 接頭重新排序

成果照片使用實體 Pin 4、6、8 連續排列，因此三芯接頭必須依照 `5V、GND、訊號` 排列。SG90 原廠接頭通常不是這個順序；未重新排列就直接套上排針，可能造成短路或損壞硬體。

1. 確認 SG90 每條線的實際功能。
2. 抬起接頭端子的塑膠卡榫，逐一抽出端子。
3. 依 `5V、GND、訊號` 順序重新插回接頭。
4. 用萬用電表或線路標示再次確認後才能通電。

也可以不修改原接頭，改用三條杜邦線分別接到正確腳位。

### 方案 A：由 Raspberry Pi 5V 供電

1. SG90 5V 接實體 Pin 4。
2. SG90 GND 接實體 Pin 6。
3. SG90 訊號接實體 Pin 8，也就是 BCM GPIO14。

此方案零件較少，但伺服馬達的瞬間電流可能使 Raspberry Pi 欠壓、重開機或造成 USB 裝置不穩定。Raspberry Pi 3 官方建議使用 5V、2.5A 電源，實際餘裕仍取決於其他周邊裝置。[Raspberry Pi 電源文件](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#power-supply)

### 方案 B：使用外部 5V 電源

1. SG90 5V 接外部電源正極。
2. SG90 GND 接外部電源負極。
3. 外部電源負極再接 Raspberry Pi 任一 GND，讓兩邊共地。
4. SG90 訊號線仍接 BCM GPIO14。

使用兩組已上電的電源時，不要把外部 5V 正極接到 Raspberry Pi 的 5V pin；本方案只共用 GND。若 Pi 直供造成不穩定，應優先改用外部電源。

### 檢查 Raspberry Pi 是否欠壓

```bash
vcgencmd get_throttled
```

- `throttled=0x0`：本次開機以來沒有回報欠壓或降頻。
- 非零值：目前或本次開機期間曾發生欠壓、過熱或降頻，需要檢查供電與負載。
- 若驅動 SG90 後才變成非零值，請改用更合適的 Pi 電源或獨立馬達電源。

## 準備 Discord Bot

1. 開啟 [Discord Developer Portal](https://discord.com/developers/applications)，建立一個 Application。
2. 在 **Bot** 頁面建立 Bot 並產生 Token。Token 只輸入樹莓派，不要放入程式碼、README、截圖或 Git commit。
3. 本專案不需要開啟 `Message Content Intent`、`Presence Intent` 或 `Server Members Intent`。
4. 在 **Installation** 頁面啟用 **Guild Install**，並在 Default Install Settings 加入 `applications.commands` 與 `bot` scopes。Bot 權限只選擇實際需要的項目。[Discord 安裝設定](https://docs.discord.com/developers/tutorials/developing-a-user-installable-app#configuring-default-install-settings)
5. 使用 Installation 頁面的安裝連結將 Bot 加入目標伺服器。
6. 在 Discord 用戶端開啟 Developer Mode，對目標伺服器按右鍵並複製 **Server ID**；這就是稍後需要輸入的 Guild ID。
7. 到 **Server Settings > Integrations > 你的 Bot > Manage**，設定哪些使用者、角色與頻道可以執行 `/open`。[Discord Application Commands 權限](https://docs.discord.com/developers/interactions/application-commands#permissions)

程式不維護使用者或角色白名單；門禁權限完全由 Discord 伺服器管理員透過 Integrations 設定。

## 下載專案

先用 Raspberry Pi Imager 安裝 Raspberry Pi OS Lite 64-bit，並在 OS Customisation 中設定使用者、網路與 SSH。登入樹莓派後執行：

```bash
git clone https://github.com/NTUT-Leo/discord-door-bot.git
cd discord-door-bot
```

接著依需求選擇其中一條路線：

| 安裝方式 | 適合對象 | 內容 |
| --- | --- | --- |
| [方式一：互動式快速安裝](#方式一互動式快速安裝) | 想快速完成部署的使用者 | 由安裝器詢問必要資料並完成系統設定 |
| [方式二：手動 DIY 安裝](#方式二手動-diy-安裝) | 想理解每個部署步驟的使用者 | 依教學自行建立目錄、環境與服務 |

兩種方式會得到相同的程式目錄、設定檔與 systemd 服務，請選擇其中一種即可。

### 方式一：互動式快速安裝

在專案目錄內執行：

```bash
sudo bash install.sh
```

安裝器會：

1. 以隱藏輸入讀取 Discord Bot Token。
2. 詢問 Discord Guild ID。
3. 顯示目前設定或建議預設值：BCM GPIO14、角度範圍 `0–90°`、待機 `0°`、開鎖 `37°`、開鎖保持與復位等待各 `0.5` 秒。
4. 詢問要直接採用設定，或進入進階模式逐項修改。
5. 偵測 GPIO14 是否與 serial console 或 UART 衝突。
6. 顯示不含 Token 的安裝摘要，確認後才開始變更系統。
7. 安裝套件、建立設定檔與 systemd 服務。

重新執行安裝器時，可以沿用既有 Token 與設定。安裝器不會執行完整系統升級、不修改 Wi-Fi 或 SSH，也不會自動重新開機。

如果安裝結果提示需要重新開機：

```bash
sudo reboot
```

重新連線後確認服務：

```bash
sudo systemctl status doorbot.service --no-pager
```

若不需要重新開機，安裝器會直接啟動服務。

### 方式二：手動 DIY 安裝

以下命令都在剛才下載的 `discord-door-bot` 專案目錄內執行。

#### 1. 安裝系統套件

```bash
sudo apt update
sudo apt install -y \
  python3-pip python3-venv python3-dev \
  build-essential swig liblgpio-dev
```

這裡只更新 apt 套件清單並安裝必要套件，不會執行完整系統升級。

#### 2. 安裝程式與 Python 套件

```bash
sudo install -d -o root -g root -m 0755 /opt/discord-door-bot
sudo install -o root -g root -m 0644 \
  door_bot.py requirements.txt /opt/discord-door-bot/

sudo python3 -m venv /opt/discord-door-bot/.venv
sudo /opt/discord-door-bot/.venv/bin/python -m pip install --upgrade pip
sudo /opt/discord-door-bot/.venv/bin/python -m pip install --upgrade \
  -r /opt/discord-door-bot/requirements.txt
```

`requirements.txt` 不指定套件版本，因此會安裝執行當時的最新版。如果未來上游推出不相容版本，請參考疑難排解或自行固定已知可用版本。

#### 3. 建立設定檔

第一次安裝時執行：

```bash
sudo install -o root -g root -m 0600 \
  .env.example /etc/discord-door-bot.env
sudoedit /etc/discord-door-bot.env
```

將範例 Token、Guild ID 換成自己的資料，並依現場調整伺服馬達設定。不要把真實 Token 寫回專案內的 `.env.example`。

如果 `/etc/discord-door-bot.env` 已存在，請直接執行 `sudoedit /etc/discord-door-bot.env`，避免以範例檔覆蓋既有 Token。

#### 4. 建立 systemd 服務

```bash
RUN_USER="$(id -un)"
RUN_GROUP="$(id -gn)"

sed \
  -e "s/@RUN_USER@/${RUN_USER}/g" \
  -e "s/@RUN_GROUP@/${RUN_GROUP}/g" \
  doorbot.service.template | \
  sudo tee /etc/systemd/system/doorbot.service >/dev/null

sudo chown root:root /etc/systemd/system/doorbot.service
sudo chmod 0644 /etc/systemd/system/doorbot.service
sudo systemctl daemon-reload
sudo systemctl enable doorbot.service
```

服務以目前登入帳號執行，並透過 `SupplementaryGroups=gpio` 取得 GPIO 權限。

#### 5. 處理 GPIO14 與 UART 衝突

GPIO14 同時是 UART TX。若保留 serial console 或 UART hardware，開機輸出可能被 SG90 誤認為控制訊號而產生抖動。

使用 GPIO14 時執行：

```bash
sudo raspi-config nonint do_serial_cons 1
sudo raspi-config nonint do_serial_hw 1
sudo reboot
```

重新開機後，服務會自動啟動。這兩個設定分別停用 serial console 與 UART hardware；若 UART 必須保留，請把訊號線改接其他 GPIO，並同步修改 `SERVO_GPIO`。[Raspberry Pi serial 設定](https://www.raspberrypi.com/documentation/computers/configuration.html#enable-or-disable-serial-port)

若使用其他 GPIO 且不需重新開機，直接啟動服務：

```bash
sudo systemctl start doorbot.service
```

#### 6. 確認服務

```bash
sudo systemctl status doorbot.service --no-pager
sudo journalctl -u doorbot.service -n 50 --no-pager
```

看到 Bot 成功登入並同步一個 Guild 指令後，就可以到 Discord 執行 `/open`。

## 設定項目

設定檔位於 `/etc/discord-door-bot.env`，擁有者與權限應為 `root:root 0600`。

| 變數 | 必填 | 預設值 | 說明 |
| --- | :---: | ---: | --- |
| `DISCORD_BOT_TOKEN` | 是 | 無 | Discord Bot Token |
| `DISCORD_GUILD_ID` | 是 | 無 | 唯一同步 `/open` 的 Discord 伺服器 ID |
| `SERVO_GPIO` | 否 | `14` | BCM GPIO 編號，不是實體 Pin 編號 |
| `SERVO_MIN_ANGLE` | 否 | `0` | 伺服馬達設定的最小角度 |
| `SERVO_MAX_ANGLE` | 否 | `90` | 伺服馬達設定的最大角度 |
| `SERVO_REST_ANGLE` | 否 | `0` | 待機與復位角度 |
| `SERVO_OPEN_ANGLE` | 否 | `37` | 拉動開鎖機構的角度 |
| `SERVO_HOLD_SECONDS` | 否 | `0.5` | 維持開鎖角度的秒數 |
| `SERVO_RETURN_SECONDS` | 否 | `0.5` | 回到待機角度後、停止 PWM 前的等待秒數 |

程式會先驗證 Guild ID、GPIO、角度與時間，確認設定合理後才載入 Discord 與 GPIO 套件；發生錯誤時不會輸出 Token。

## 校正 SG90

第一次部署後，微調角度或等待時間時不必重新執行安裝器。編輯既有設定檔：

```bash
sudoedit /etc/discord-door-bot.env
```

儲存後重新啟動服務：

```bash
sudo systemctl restart doorbot.service
```

建議依下列順序校正：

1. 先將繩索與鎖體分離，只觀察馬達空轉方向。
2. 讓 `SERVO_OPEN_ANGLE` 從接近 `SERVO_REST_ANGLE` 的小幅度值開始。
3. 儲存設定、重新啟動服務，再到 Discord 執行 `/open`。
4. 重複「修改設定 → 重新啟動服務 → 執行 `/open`」，每次只增加少量角度。
5. 接上繩索後繼續小幅調整，直到剛好能拉動開鎖機構。
6. 保留機械餘裕，不要讓 SG90 頂住極限或持續堵轉。
7. 確認回到 `SERVO_REST_ANGLE` 時繩索已放鬆，且不妨礙原有按鈕。

> [!TIP]
> 每次重新啟動服務時，SG90 都會先移動至設定的 `SERVO_REST_ANGLE` 待機角度一次。

## Discord 權限管理

`/open` 只會註冊到 `DISCORD_GUILD_ID` 指定的伺服器。程式第一次成功啟動時，也會移除相同 Application 過去註冊的全域指令，避免同時看到兩個 `/open`。

到 Discord 的 **Server Settings > Integrations > 你的 Bot > Manage**：

1. 拒絕不應操作門鎖的人員或角色。
2. 只允許指定成員或實驗室角色使用 `/open`。
3. 視需要限制只能在特定門禁頻道執行。
4. 使用一般成員帳號確認最終權限符合預期。

Discord 伺服器管理員仍能修改 Integrations 權限，因此應限制管理員角色並定期檢查成員。

## 服務管理

```bash
# 查看狀態
sudo systemctl status doorbot.service

# 追蹤即時日誌
sudo journalctl -u doorbot.service -f

# 查看最近 100 行
sudo journalctl -u doorbot.service -n 100 --no-pager

# 重新啟動
sudo systemctl restart doorbot.service

# 停止與啟動
sudo systemctl stop doorbot.service
sudo systemctl start doorbot.service
```

日誌不會主動輸出 Token；分享日誌前仍應人工確認沒有自行加入的敏感資訊。

### 更新程式

使用快速安裝方式的使用者可執行：

```bash
cd discord-door-bot
git pull
sudo bash install.sh
```

安裝器會詢問是否沿用現有 Token 與設定。只修改角度或等待時間時不需要執行這個流程，直接編輯設定檔即可。

## 疑難排解

### Discord 看不到 `/open`

- 確認 `DISCORD_GUILD_ID` 是 Server ID，不是頻道或使用者 ID。
- 確認 Application 使用 Guild Install，且安裝設定包含 `applications.commands` 與 `bot` scopes。
- 使用 `journalctl` 查看指令同步或權限錯誤。
- 重新啟動 Discord 用戶端以更新指令選單。

Guild 指令通常會立即更新，不需要等待全域指令的傳播時間。[discord.py CommandTree 文件](https://discordpy.readthedocs.io/en/stable/interactions/api.html#discord.app_commands.CommandTree.sync)

### GPIO permission denied

```bash
getent group gpio
systemctl cat doorbot.service
ls -l /dev/gpiochip*
```

確認系統存在 `gpio` 群組，且 service 內包含 `SupplementaryGroups=gpio`。

### 安裝 rpi-lgpio 失敗

若看到 `swig: not found` 或 `cannot find -llgpio`，重新確認：

```bash
sudo apt install -y python3-dev build-essential swig liblgpio-dev
sudo /opt/discord-door-bot/.venv/bin/python -m pip install --upgrade rpi-lgpio
```

### 開機時 SG90 抖動或亂轉

- GPIO14 必須停用 serial console 與 UART hardware，或改用其他 GPIO。
- 確認接頭沒有把 5V、GND 與訊號接反。
- 檢查 Raspberry Pi 與 SG90 的供電是否穩定。
- 若作業系統接管 GPIO 前仍會短暫抖動，可改用其他 GPIO，或在訊號線加入適當的硬體下拉設計。

### Bot 顯示完成但門沒有開

「解鎖動作已完成」只代表程式已送出開鎖角度、等待、復位與停止 PWM，不代表門鎖已實際開啟。請檢查繩索、固定座、角度與供電。

## 專案結構

```text
.
├── door_bot.py                 # 單一 Bot 程式：設定、Discord 與伺服控制
├── install.sh                  # 互動式快速安裝器
├── requirements.txt            # 不鎖定版本的 Python 執行依賴
├── .env.example                # 不含真實憑證的設定範例
├── doorbot.service.template       # systemd 服務範本
├── Result_Images/              # 原始成果照片
├── .gitignore
└── LICENSE                     # MIT License
```

## License

[MIT License](LICENSE), Copyright © 2026 KANG.
