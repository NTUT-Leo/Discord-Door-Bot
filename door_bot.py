"""Discord Door Bot: control an SG90 servo from one guild-only slash command."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
import logging
import math
import os
from typing import Any


LOGGER = logging.getLogger("doorbot")


class ConfigError(ValueError):
    """Raised when a runtime setting is missing or unsafe."""


def required(environ: Mapping[str, str], name: str) -> str:
    value = environ.get(name, "").strip()
    if not value:
        raise ConfigError(f"缺少必要設定：{name}")
    return value


def integer(environ: Mapping[str, str], name: str, default: int) -> int:
    raw = environ.get(name, str(default)).strip()
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} 必須是整數，目前值為 {raw!r}") from exc


def number(environ: Mapping[str, str], name: str, default: float) -> float:
    raw = environ.get(name, str(default)).strip()
    try:
        value = float(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} 必須是數字，目前值為 {raw!r}") from exc
    if not math.isfinite(value):
        raise ConfigError(f"{name} 必須是有限數字")
    return value


@dataclass(frozen=True, slots=True)
class DoorBotConfig:
    """Validated settings. GPIO uses BCM numbering, not physical pin numbers."""

    discord_bot_token: str
    discord_guild_id: int
    servo_gpio: int = 14
    servo_min_angle: float = 0.0
    servo_max_angle: float = 90.0
    servo_rest_angle: float = 0.0
    servo_open_angle: float = 37.0
    servo_hold_seconds: float = 0.5
    servo_return_seconds: float = 0.5

    @classmethod
    def from_env(
        cls, environ: Mapping[str, str] | None = None
    ) -> "DoorBotConfig":
        values = os.environ if environ is None else environ

        token = required(values, "DISCORD_BOT_TOKEN")
        if any(character.isspace() for character in token):
            raise ConfigError("DISCORD_BOT_TOKEN 不可包含空白字元")

        guild_raw = required(values, "DISCORD_GUILD_ID")
        try:
            guild_id = int(guild_raw)
        except ValueError as exc:
            raise ConfigError("DISCORD_GUILD_ID 必須是正整數") from exc
        if guild_id <= 0:
            raise ConfigError("DISCORD_GUILD_ID 必須是正整數")

        config = cls(
            discord_bot_token=token,
            discord_guild_id=guild_id,
            servo_gpio=integer(values, "SERVO_GPIO", 14),
            servo_min_angle=number(values, "SERVO_MIN_ANGLE", 0.0),
            servo_max_angle=number(values, "SERVO_MAX_ANGLE", 90.0),
            servo_rest_angle=number(values, "SERVO_REST_ANGLE", 0.0),
            servo_open_angle=number(values, "SERVO_OPEN_ANGLE", 37.0),
            servo_hold_seconds=number(values, "SERVO_HOLD_SECONDS", 0.5),
            servo_return_seconds=number(values, "SERVO_RETURN_SECONDS", 0.5),
        )
        config.validate()
        return config

    def validate(self) -> None:
        if not 0 <= self.servo_gpio <= 27:
            raise ConfigError("SERVO_GPIO 必須是 Raspberry Pi BCM GPIO 0 到 27")
        if self.servo_min_angle >= self.servo_max_angle:
            raise ConfigError("SERVO_MIN_ANGLE 必須小於 SERVO_MAX_ANGLE")

        for name, value in (
            ("SERVO_REST_ANGLE", self.servo_rest_angle),
            ("SERVO_OPEN_ANGLE", self.servo_open_angle),
        ):
            if not self.servo_min_angle <= value <= self.servo_max_angle:
                raise ConfigError(
                    f"{name} 必須介於 SERVO_MIN_ANGLE 與 SERVO_MAX_ANGLE 之間"
                )

        for name, value in (
            ("SERVO_HOLD_SECONDS", self.servo_hold_seconds),
            ("SERVO_RETURN_SECONDS", self.servo_return_seconds),
        ):
            if value < 0:
                raise ConfigError(f"{name} 不可為負數")


class ServoController:
    """Drive the SG90 and reject overlapping unlock requests."""

    def __init__(
        self,
        config: DoorBotConfig,
        servo_factory: Callable[..., Any],
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ) -> None:
        self.config = config
        self._servo_factory = servo_factory
        self._sleep = sleep
        self._servo: Any | None = None
        self._lock = asyncio.Lock()
        self._initialized = False

    @property
    def busy(self) -> bool:
        return self._lock.locked()

    def get_servo(self) -> Any:
        if self._servo is None:
            self._servo = self._servo_factory(
                self.config.servo_gpio,
                min_angle=self.config.servo_min_angle,
                max_angle=self.config.servo_max_angle,
                initial_angle=None,
            )
        return self._servo

    async def initialize_to_rest(self) -> None:
        """Move to standby once after startup, then stop PWM output."""
        if self._initialized:
            return

        servo = self.get_servo()
        try:
            servo.angle = self.config.servo_rest_angle
            await self._sleep(self.config.servo_return_seconds)
        finally:
            servo.detach()
        self._initialized = True

    async def run_unlock_cycle(self) -> bool:
        """Run one unlock cycle, or return False when another cycle is active."""
        if self._lock.locked():
            return False

        await self._lock.acquire()
        try:
            servo = self.get_servo()
            try:
                servo.angle = self.config.servo_open_angle
                await self._sleep(self.config.servo_hold_seconds)
            finally:
                try:
                    servo.angle = self.config.servo_rest_angle
                    await self._sleep(self.config.servo_return_seconds)
                finally:
                    servo.detach()
            return True
        finally:
            self._lock.release()

    def detach(self) -> None:
        """Stop PWM without creating a GPIO device during shutdown."""
        if self._servo is not None:
            self._servo.detach()


def run_bot(config: DoorBotConfig) -> None:
    """Import runtime dependencies and start the Discord client."""
    import discord
    from discord.ext import commands
    from gpiozero import AngularServo

    guild = discord.Object(id=config.discord_guild_id)
    controller = ServoController(config, AngularServo)
    intents = discord.Intents.default()
    intents.message_content = False

    class DoorBot(commands.Bot):
        async def setup_hook(self) -> None:
            await controller.initialize_to_rest()

            # Keep /open guild-only and remove a global copy left by older builds.
            self.tree.clear_commands(guild=None)
            await self.tree.sync(guild=None)
            synced = await self.tree.sync(guild=guild)
            LOGGER.info(
                "已同步 %d 個指令至 Discord Guild %d",
                len(synced),
                config.discord_guild_id,
            )

        async def close(self) -> None:
            try:
                controller.detach()
            finally:
                await super().close()

    bot = DoorBot(command_prefix=commands.when_mentioned, intents=intents)

    @bot.event
    async def on_ready() -> None:
        LOGGER.info("Bot 已登入：%s", bot.user)

    @bot.tree.command(
        name="open",
        description="執行實驗室門鎖的解鎖動作",
        guild=guild,
    )
    async def open_door(interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)

        try:
            performed = await controller.run_unlock_cycle()
        except Exception:
            LOGGER.exception("伺服馬達解鎖流程失敗")
            try:
                await interaction.edit_original_response(
                    content="解鎖動作失敗，請聯絡管理員檢查服務紀錄。"
                )
            except Exception:
                LOGGER.exception("無法回覆 Discord interaction")
            return

        if not performed:
            await interaction.edit_original_response(
                content="門鎖正在執行上一個請求，請稍候再試。"
            )
            return

        await interaction.edit_original_response(content="解鎖動作已完成。")

    bot.run(config.discord_bot_token, log_handler=None)


def main() -> int:
    try:
        config = DoorBotConfig.from_env()
    except ConfigError as exc:
        logging.basicConfig(level=logging.ERROR, format="%(levelname)s: %(message)s")
        logging.error("設定錯誤：%s", exc)
        return 2

    # Validate every setting before importing Discord or GPIO dependencies.
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    run_bot(config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
