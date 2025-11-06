#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Telegram Billing Bot для oscam.pro
Версия 3.4 (исправлены недостающие функции, добавлен graceful shutdown)
"""

import asyncio
import logging
import os
import re
import csv
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Tuple, Dict, List

from dotenv import load_dotenv
from playwright.async_api import async_playwright, Page, Browser, BrowserContext
from telegram import (
    Update,
    ReplyKeyboardMarkup,
    ReplyKeyboardRemove,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
)
from telegram.ext import (
    Application,
    CommandHandler,
    MessageHandler,
    ConversationHandler,
    CallbackQueryHandler,
    filters,
    ContextTypes,
)

# ──────────────────────────────────────────────────────────────────────────────
# Настройки окружения и логов
# ──────────────────────────────────────────────────────────────────────────────
load_dotenv()

DATA_DIR = Path("/root/billing-bot/logs")
DATA_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
    handlers=[
        logging.FileHandler(DATA_DIR / "billing.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger(__name__)

# Переменные окружения
BOT_TOKEN = os.getenv("BOT_TOKEN")
ADMIN_ID = int(os.getenv("ADMIN_ID", "0"))
OSCAM_URL = os.getenv("OSCAM_URL", "http://oscam.pro")
OSCAM_USER = os.getenv("OSCAM_USER")
OSCAM_PASS = os.getenv("OSCAM_PASS")
STATE_FILE = DATA_DIR / "oscam_state.json"

# Состояния диалога
(WAITING_LOGIN, WAITING_PASSWORD, WAITING_PACKAGE, WAITING_DURATION, WAITING_CHECK_LOGIN) = range(5)

# Тексты кнопок (RU)
BUTTON_BUY = "Купить подписку"
BUTTON_PROFILE = "Профиль"
BUTTON_SERVER_STATS = "Статистика серверов"
BUTTON_CHECK = "Проверить подписку"

def default_reply_markup() -> ReplyKeyboardMarkup:
    keyboard = [
        [BUTTON_BUY],
        [BUTTON_PROFILE, BUTTON_SERVER_STATS],
        [BUTTON_CHECK],
    ]
    return ReplyKeyboardMarkup(keyboard, resize_keyboard=True)

# Пакеты и порты
PACKAGES_WITH_PORTS: Dict[str, str] = {
    "Telekarta": "720",
    "Telekarta+56": "703",
    "NTV Plus 56": "560",
    "Russkiy Mir": "7044",
    "AlemTV": "768",
    "Tivusat + Sky Italy 13E": "705",
    "Klubnichka 13E/19E": "704",
    "HD plus + ORF 19E": "719",
    "Polsat": "708",
    "Sky UK": "711",
    "NTV 56 + Russkiy Mir 56": "560",
    "Focussat 0.8W + Freesat 16E": "712",
    "Canal Digitaal 23E": "714",
    "Skylink 23.5E": "715",
    "Antiksat 16E + Skylink 23.5E": "768",
}
POPULAR_PACKAGES = ["Telekarta", "Telekarta+56", "NTV Plus 56", "Russkiy Mir"]

# Глобальные объекты Playwright
_playwright = None
_browser: Optional[Browser] = None
_context: Optional[BrowserContext] = None


# ──────────────────────────────────────────────────────────────────────────────
# Playwright helpers
# ──────────────────────────────────────────────────────────────────────────────
async def get_browser() -> BrowserContext:
    """Создаёт/возвращает контекст браузера."""
    global _playwright, _browser, _context
    if _browser is None:
        _playwright = await async_playwright().start()
        _browser = await _playwright.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"],
        )

        ctx_kwargs = {
            "viewport": {"width": 1600, "height": 1024},
            "user_agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/120.0.0.0 Safari/537.36"
            ),
            "locale": "ru-RU",
        }

        if STATE_FILE.exists():
            try:
                _context = await _browser.new_context(storage_state=str(STATE_FILE), **ctx_kwargs)
                logger.info("Загружено сохранённое состояние сессии")
            except Exception as e:
                logger.warning(f"Не удалось загрузить состояние сессии: {e}")
                _context = await _browser.new_context(**ctx_kwargs)
        else:
            _context = await _browser.new_context(**ctx_kwargs)

        logger.info("Chromium (headless) запущен")
    return _context


async def close_browser():
    """Graceful shutdown браузера."""
    global _playwright, _browser, _context
    try:
        if _context:
            await _context.close()
            _context = None
        if _browser:
            await _browser.close()
            _browser = None
        if _playwright:
            await _playwright.stop()
            _playwright = None
        logger.info("Браузер закрыт")
    except Exception as e:
        logger.error(f"Ошибка при закрытии браузера: {e}")


async def _screenshot(page: Page, tag: str) -> None:
    """Сохранить скриншот для диагностики."""
    try:
        p = DATA_DIR / f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{tag}.png"
        await page.screenshot(path=str(p), full_page=True)
        logger.info(f"Скриншот: {p}")
    except Exception as e:
        logger.warning(f"Не удалось сохранить скриншот: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# oscam.pro actions
# ──────────────────────────────────────────────────────────────────────────────
async def ensure_logged_in(page: Page) -> bool:
    """Надёжный вход на сайт: ищем поля разными способами, сохраняем сессию."""
    try:
        login_url = f"{OSCAM_URL}/login.php"
        await page.goto(login_url, wait_until="domcontentloaded", timeout=30000)
        await asyncio.sleep(0.8)

        # Уже авторизованы?
        if await page.query_selector('a[href*="dealer.php"], a[href*="add_client.php"], a[href*="logout"]'):
            logger.info("Авторизация уже есть")
            return True

        # Поля логина/пароля
        user_el = (
            await page.query_selector('input[name*="login" i]') or
            await page.query_selector('input[name*="user" i]') or
            await page.query_selector('input[placeholder*="логин" i]') or
            await page.query_selector('input[placeholder*="login" i]') or
            await page.query_selector("input[type='text']")
        )
        pass_el = (
            await page.query_selector("input[type='password']") or
            await page.query_selector('input[name*="pass" i]')
        )

        if not user_el or not pass_el:
            logger.error("Не найдено поле логина/пароля на странице входа")
            await _screenshot(page, "login_no_fields")
            return False

        await user_el.fill(OSCAM_USER or "")
        await pass_el.fill(OSCAM_PASS or "")

        submit = (
            await page.query_selector("button[type='submit']") or
            await page.query_selector("input[type='submit']") or
            await page.query_selector('button:has-text("Войти")') or
            await page.query_selector('button:has-text("Login")')
        )
        if submit:
            await submit.click()
        else:
            await pass_el.press("Enter")

        try:
            await page.wait_for_load_state("networkidle", timeout=12000)
        except Exception:
            await page.wait_for_load_state("domcontentloaded", timeout=12000)
        await asyncio.sleep(0.8)

        # Проверка успеха
        if await page.query_selector('a[href*="dealer.php"], a[href*="add_client.php"], a[href*="logout"]'):
            try:
                await page.context.storage_state(path=str(STATE_FILE))
            except Exception as e:
                logger.warning(f"Не удалось сохранить состояние сессии: {e}")
            logger.info("Успешная авторизация")
            return True

        # Пробуем напрямую dealer.php
        await page.goto(f"{OSCAM_URL}/dealer.php", wait_until="domcontentloaded")
        if await page.query_selector("table, form, a[href*='add_client.php']"):
            try:
                await page.context.storage_state(path=str(STATE_FILE))
            except Exception:
                pass
            logger.info("Успешная авторизация (через переход на dealer.php)")
            return True

        logger.error("Вход не удался")
        await _screenshot(page, "login_failed")
        return False

    except Exception as e:
        logger.error(f"Ошибка входа: {e}")
        await _screenshot(page, "login_exception")
        return False


async def add_client(page: Page, username: str, password: str) -> bool:
    """Добавление нового клиента: логин, пароль/подтверждение, email, сервер, сохранить."""
    try:
        await page.goto(f"{OSCAM_URL}/add_client.php", wait_until="domcontentloaded")
        await asyncio.sleep(0.6)

        # Логин
        login_input = (
            await page.query_selector('input[name*="login" i]') or
            await page.query_selector('input[placeholder*="логин" i]') or
            await page.query_selector("input[type='text']")
        )
        if not login_input:
            logger.error("Поле логина клиента не найдено")
            await _screenshot(page, "add_client_no_login")
            return False
        await login_input.fill(username)

        # Пароли
        pass_inputs = await page.query_selector_all("input[type='password']")
        if len(pass_inputs) >= 1:
            await pass_inputs[0].fill(password)
        if len(pass_inputs) >= 2:
            await pass_inputs[1].fill(password)

        # Обязательное поле e-mail (по скриншоту на сайте оно есть)
        email_input = (
            await page.query_selector("input[type='email']") or
            await page.query_selector('input[name*="mail" i]') or
            await page.query_selector('input[placeholder*="почт" i]') or
            await page.query_selector('input[placeholder*="email" i]')
        )
        if email_input:
            await email_input.fill(f"{username}@example.com")

        # Сервер
        server_select = await page.query_selector("select")
        if server_select:
            options = await server_select.query_selector_all("option")
            if len(options) >= 2:
                await options[1].click()

        await asyncio.sleep(0.3)

        # Сохранить
        save_btn = (
            await page.query_selector('button:has-text("Сохранить")') or
            await page.query_selector("input[type='submit']") or
            await page.query_selector("button[type='submit']")
        )
        if not save_btn:
            logger.error("Кнопка 'Сохранить' не найдена")
            await _screenshot(page, "add_client_no_submit")
            return False

        await save_btn.click()
        try:
            await page.wait_for_load_state("networkidle", timeout=12000)
        except Exception:
            await page.wait_for_load_state("domcontentloaded", timeout=12000)
        await asyncio.sleep(0.6)

        if "dealer.php" in page.url:
            logger.info(f"Клиент {username} успешно добавлен (redirect dealer.php)")
            return True

        html = (await page.content()).lower()
        if re.search(r"успешн|добавлен|создан|saved", html, re.IGNORECASE):
            logger.info(f"Клиент {username} успешно добавлен (по тексту страницы)")
            return True

        logger.error("Не удалось подтвердить добавление клиента")
        await _screenshot(page, "add_client_not_confirmed")
        return False

    except Exception as e:
        logger.error(f"Ошибка добавления клиента: {e}")
        await _screenshot(page, "add_client_exception")
        return False


async def buy_package(page: Page, username: str, package_name: str, duration: int) -> Tuple[bool, str, str]:
    """Покупка пакета для клиента."""
    try:
        await page.goto(f"{OSCAM_URL}/dealer.php", wait_until="domcontentloaded")
        await asyncio.sleep(0.8)

        # Находим строку клиента
        client_row = await page.query_selector(f'tr:has-text("{username}")')
        if not client_row:
            # Попробуем поле поиска (на некоторых шаблонах оно есть)
            search_box = (
                await page.query_selector('input[type="search"]') or
                await page.query_selector('input[placeholder*="поиск" i]') or
                await page.query_selector('input[placeholder*="search" i]')
            )
            if search_box:
                await search_box.fill(username)
                await asyncio.sleep(0.8)
                client_row = await page.query_selector(f'tr:has-text("{username}")')

        if not client_row:
            logger.error(f"Клиент {username} не найден в таблице")
            await _screenshot(page, "buy_not_found")
            return False, "", ""

        # Переход в выбор пакетов
        buy_link = await client_row.query_selector('a[href*="packets.php"]')
        if not buy_link:
            imgs = await client_row.query_selector_all("img")
            for img in imgs:
                src = (await img.get_attribute("src") or "").lower()
                if any(w in src for w in ["dollar", "money", "buy"]):
                    buy_link = await img.evaluate_handle("el => el.closest('a')")
                    break
        if not buy_link:
            logger.error("Ссылка на покупку пакетов не найдена")
            await _screenshot(page, "buy_no_link")
            return False, "", ""

        await buy_link.click()
        await page.wait_for_load_state("domcontentloaded", timeout=10000)
        await asyncio.sleep(0.6)

        # Выбор пакета
        package_select = await page.query_selector("select")
        if package_select:
            try:
                await package_select.select_option(label=package_name)
            except Exception:
                # Частичное совпадение по тексту
                options = await package_select.query_selector_all("option")
                found = False
                for opt in options:
                    txt = (await opt.inner_text()).strip()
                    if package_name.lower() in txt.lower():
                        value = await opt.get_attribute("value")
                        await package_select.select_option(value=value)
                        found = True
                        break
                if not found:
                    logger.error(f"Пакет '{package_name}' не найден в списке")
                    await _screenshot(page, "buy_no_package")
                    return False, "", ""
            await asyncio.sleep(0.3)

        # Срок
        period_link = await page.query_selector(f'a:has-text("{duration}")')
        if period_link:
            await period_link.click()
            await asyncio.sleep(0.3)

        # Порт и дата
        port = PACKAGES_WITH_PORTS.get(package_name, "unknown")
        end_date = (datetime.now() + timedelta(days=duration)).strftime("%d.%m.%Y")

        # Подтвердить покупку
        buy_btn = (
            await page.query_selector('button:has-text("Купить")') or
            await page.query_selector("input[type='submit']") or
            await page.query_selector("button")
        )
        if not buy_btn:
            logger.error("Кнопка подтверждения покупки не найдена")
            await _screenshot(page, "buy_no_submit")
            return False, "", ""

        await buy_btn.click()
        try:
            await page.wait_for_load_state("networkidle", timeout=12000)
        except Exception:
            await page.wait_for_load_state("domcontentloaded", timeout=12000)
        await asyncio.sleep(0.6)

        if "dealer.php" in page.url:
            return True, port, end_date

        html = (await page.content()).lower()
        if re.search(r"успешн|активир|куплен|success", html, re.IGNORECASE):
            return True, port, end_date

        logger.error("Покупка не подтвердилась")
        await _screenshot(page, "buy_failed")
        return False, "", ""

    except Exception as e:
        logger.error(f"Ошибка покупки пакета: {e}")
        await _screenshot(page, "buy_exception")
        return False, "", ""


async def _find_table_like(page_or_frame) -> List[Dict[str, str]]:
    """Умный поиск таблицы клиентов (JS в браузере)."""
    js = r"""
    () => {
      function t(x){return x && x.innerText ? x.innerText.trim() : "";}
      const req = ['логин','login','пакет','package','начало','start','конец','end'];
      for (const table of Array.from(document.querySelectorAll('table'))) {
        let thead = Array.from(table.querySelectorAll('thead th'));
        if (thead.length === 0) {
          const first = table.querySelector('tr');
          if (first) thead = Array.from(first.querySelectorAll('th,td'));
        }
        const headers = thead.map(h => t(h).toLowerCase());
        const ok = req.filter(r => headers.some(h => h.includes(r))).length >= 2;
        if (!ok) continue;

        const idx = {login:-1, package:-1, start:-1, end:-1};
        for (let i=0;i<headers.length;i++){
          const h = headers[i];
          if (idx.login<0 && (h.includes('логин')||h.includes('login'))) idx.login=i;
          if (idx.package<0 && (h.includes('пакет')||h.includes('package'))) idx.package=i;
          if (idx.start<0 && (h.includes('начало')||h.includes('start'))) idx.start=i;
          if (idx.end<0 && (h.includes('конец')||h.includes('end'))) idx.end=i;
        }
        if (idx.login<0) idx.login = 0;

        const rows = [];
        const trs = Array.from(table.querySelectorAll('tr'));
        let from = 0;
        if (trs.length>0) {
          const firstCells = Array.from(trs[0].querySelectorAll('th,td')).map(c=>t(c).toLowerCase());
          const headerish = firstCells.some(x => /логин|login|пакет|package|начало|start|конец|end/.test(x));
          from = headerish ? 1 : 0;
        }
        for (let r=from;r<trs.length;r++){
          const cells = Array.from(trs[r].querySelectorAll('td,th')).map(c=>t(c));
          if (cells.length===0) continue;
          const get=(i)=> (i>=0 && i<cells.length) ? cells[i].trim() : "";
          rows.push({Login:get(idx.login), Package:get(idx.package), Start:get(idx.start), End:get(idx.end)});
        }
        if (rows.length>0) return rows;
      }
      return [];
    }
    """
    try:
        result = await page_or_frame.evaluate(js)
        if isinstance(result, list):
            return result
    except Exception:
        pass
    return []


async def save_clients_table(page: Page) -> str:
    """Выгружает таблицу клиентов в CSV."""
    try:
        await page.goto(f"{OSCAM_URL}/dealer.php", wait_until="domcontentloaded")
        await asyncio.sleep(0.6)

        rows = await _find_table_like(page)
        if not rows:
            # Пробуем iframes
            for fr in page.frames:
                if fr == page.main_frame:
                    continue
                try:
                    rows = await _find_table_like(fr)
                    if rows:
                        break
                except Exception:
                    continue

        csv_path = DATA_DIR / "clients_table.csv"
        with open(csv_path, "w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["Login", "Package", "Start", "End"])
            w.writeheader()
            for r in rows:
                if r.get("Login"):
                    w.writerow(r)

        logger.info(f"Сохранено строк: {len(rows)} -> {csv_path}")
        return str(csv_path)

    except Exception as e:
        logger.error(f"Ошибка выгрузки таблицы: {e}")
        await _screenshot(page, "save_clients_table_exception")
        return ""


async def get_client_subscription(username: str) -> Optional[Dict[str, str]]:
    """Поиск клиента по логину в выгруженном CSV."""
    try:
        p = DATA_DIR / "clients_table.csv"
        if not p.exists():
            return None
        with open(p, "r", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                if row.get("Login", "").strip().lower() == username.lower():
                    return row
        return None
    except Exception:
        return None


async def get_profile_info(page: Page) -> Dict[str, str]:
    """
    Получает информацию о профиле дилера.
    Возвращает словарь с ключами: login, balance, discount, active_clients
    """
    try:
        # Переходим на страницу профиля/дилера
        await page.goto(f"{OSCAM_URL}/dealer.php", wait_until="domcontentloaded")
        await asyncio.sleep(0.6)

        result = {
            "login": OSCAM_USER or "N/A",
            "balance": "N/A",
            "discount": "N/A",
            "active_clients": "0"
        }

        # Пытаемся найти информацию на странице с помощью JS
        profile_js = """
        () => {
            function getText(selector) {
                const el = document.querySelector(selector);
                return el ? el.innerText.trim() : '';
            }

            function findTextContaining(keywords) {
                const all = Array.from(document.querySelectorAll('div, span, td, p'));
                for (const el of all) {
                    const text = el.innerText || '';
                    for (const keyword of keywords) {
                        if (text.toLowerCase().includes(keyword.toLowerCase())) {
                            return text.trim();
                        }
                    }
                }
                return '';
            }

            // Ищем баланс
            const balance = findTextContaining(['баланс', 'balance', 'остаток']);

            // Ищем скидку
            const discount = findTextContaining(['скидка', 'discount']);

            // Считаем активных клиентов в таблице
            const rows = Array.from(document.querySelectorAll('table tr'));
            let activeCount = 0;
            for (const row of rows) {
                const cells = Array.from(row.querySelectorAll('td'));
                // Пропускаем заголовки
                if (cells.length === 0) continue;
                // Считаем строки с данными
                const hasLogin = cells.some(cell => cell.innerText && cell.innerText.trim().length > 0);
                if (hasLogin) activeCount++;
            }
            // Вычитаем заголовок если есть
            if (activeCount > 0) activeCount = Math.max(0, activeCount - 1);

            return {
                balance: balance,
                discount: discount,
                active_clients: activeCount.toString()
            };
        }
        """

        try:
            info = await page.evaluate(profile_js)
            if info:
                # Извлекаем числовые значения из текста
                if info.get("balance"):
                    # Ищем число с возможными символами валюты
                    balance_match = re.search(r'[\d\s,.]+', info["balance"])
                    if balance_match:
                        result["balance"] = balance_match.group().strip()

                if info.get("discount"):
                    # Ищем процент или число
                    discount_match = re.search(r'\d+%?', info["discount"])
                    if discount_match:
                        result["discount"] = discount_match.group()

                if info.get("active_clients"):
                    result["active_clients"] = info["active_clients"]
        except Exception as e:
            logger.warning(f"Не удалось получить данные профиля через JS: {e}")

        # Альтернативный метод - подсчет клиентов из таблицы
        try:
            rows = await _find_table_like(page)
            if rows:
                # Считаем строки с логинами
                active = sum(1 for r in rows if r.get("Login") and r["Login"].strip())
                result["active_clients"] = str(active)
        except Exception as e:
            logger.warning(f"Не удалось подсчитать клиентов из таблицы: {e}")

        logger.info(f"Получена информация профиля: {result}")
        return result

    except Exception as e:
        logger.error(f"Ошибка получения информации профиля: {e}")
        await _screenshot(page, "get_profile_exception")
        return {
            "login": OSCAM_USER or "N/A",
            "balance": "N/A",
            "discount": "N/A",
            "active_clients": "0"
        }


async def get_server_stats(page: Page) -> Dict[str, any]:
    """
    Получает статистику серверов.
    Возвращает словарь с ключами: servers (dict), stats (dict)
    """
    try:
        # Пробуем найти страницу статистики
        # Обычно это может быть stats.php, servers.php, или dealer.php с информацией
        stats_urls = [
            f"{OSCAM_URL}/stats.php",
            f"{OSCAM_URL}/servers.php",
            f"{OSCAM_URL}/dealer.php"
        ]

        result = {
            "servers": {},
            "stats": {"total_active": "0"}
        }

        for url in stats_urls:
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=10000)
                await asyncio.sleep(0.5)

                # Проверяем, есть ли на странице нужная информация
                stats_js = """
                () => {
                    function getText(el) {
                        return el && el.innerText ? el.innerText.trim() : '';
                    }

                    const servers = {};
                    const stats = {};

                    // Ищем таблицы с информацией о серверах
                    const tables = Array.from(document.querySelectorAll('table'));

                    for (const table of tables) {
                        const rows = Array.from(table.querySelectorAll('tr'));

                        for (const row of rows) {
                            const cells = Array.from(row.querySelectorAll('td, th'));
                            if (cells.length < 2) continue;

                            const cellTexts = cells.map(c => getText(c));

                            // Ищем паттерны: "Server X" или "oscam X" и нагрузку/load
                            for (let i = 0; i < cellTexts.length - 1; i++) {
                                const cell = cellTexts[i].toLowerCase();
                                const nextCell = cellTexts[i + 1];

                                if ((cell.includes('server') || cell.includes('oscam')) && nextCell) {
                                    // Извлекаем имя сервера
                                    const serverName = cellTexts[i];
                                    // Следующая ячейка может содержать нагрузку
                                    if (nextCell.match(/\d+/)) {
                                        servers[serverName] = nextCell;
                                    }
                                }

                                // Ищем load/нагрузку
                                if (cell.includes('load') || cell.includes('нагрузка')) {
                                    const prevCell = cellTexts[Math.max(0, i - 1)];
                                    if (prevCell && !prevCell.toLowerCase().includes('load')) {
                                        servers[prevCell] = cellTexts[i + 1] || nextCell;
                                    }
                                }
                            }
                        }
                    }

                    // Ищем общую статистику
                    const allText = document.body.innerText;

                    // Ищем "активных клиентов" или "active clients"
                    const activeMatch = allText.match(/(?:активных|active)[:\s]+(\d+)/i);
                    if (activeMatch) {
                        stats.total_active = activeMatch[1];
                    }

                    // Ищем "online" клиентов
                    const onlineMatch = allText.match(/(?:online|онлайн)[:\s]+(\d+)/i);
                    if (onlineMatch) {
                        stats.online = onlineMatch[1];
                    }

                    return { servers, stats };
                }
                """

                info = await page.evaluate(stats_js)

                if info and (info.get("servers") or info.get("stats")):
                    if info.get("servers"):
                        result["servers"].update(info["servers"])
                    if info.get("stats"):
                        result["stats"].update(info["stats"])

                    # Если нашли данные, прекращаем поиск
                    if result["servers"]:
                        break

            except Exception as e:
                logger.debug(f"Не удалось получить статистику с {url}: {e}")
                continue

        # Если не нашли статистику серверов, пробуем подсчитать активных клиентов
        if not result["servers"] or result["stats"]["total_active"] == "0":
            try:
                await page.goto(f"{OSCAM_URL}/dealer.php", wait_until="domcontentloaded")
                await asyncio.sleep(0.5)

                rows = await _find_table_like(page)
                if rows:
                    # Считаем активных клиентов (с пакетами)
                    active = sum(1 for r in rows if r.get("Login") and r.get("Package"))
                    result["stats"]["total_active"] = str(active)

                    # Группируем по серверам если есть такая информация
                    # (обычно сервер не отображается в таблице клиентов)

            except Exception as e:
                logger.warning(f"Не удалось подсчитать активных клиентов: {e}")

        logger.info(f"Получена статистика серверов: {result}")
        return result

    except Exception as e:
        logger.error(f"Ошибка получения статистики серверов: {e}")
        await _screenshot(page, "get_server_stats_exception")
        return {
            "servers": {},
            "stats": {"total_active": "0"}
        }


# ──────────────────────────────────────────────────────────────────────────────
# Telegram handlers
# ──────────────────────────────────────────────────────────────────────────────
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != ADMIN_ID:
        await update.message.reply_text("Доступ запрещён.")
        return

    text = (
        "Добро пожаловать в Billing Bot!\n\n"
        f"- {BUTTON_BUY} — создать логин и купить пакет\n"
        f"- {BUTTON_PROFILE} — баланс и статистика\n"
        f"- {BUTTON_SERVER_STATS} — нагрузка серверов\n"
        f"- {BUTTON_CHECK} — проверить окончание подписки"
    )
    await update.message.reply_text(text, reply_markup=default_reply_markup())


async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = update.message.text

    if text == BUTTON_BUY:
        await update.message.reply_text("Введите логин нового пользователя:", reply_markup=ReplyKeyboardRemove())
        return WAITING_LOGIN

    elif text == BUTTON_PROFILE:
        await update.message.reply_text("Получаю профиль...")
        try:
            ctx = await get_browser()
            page = await ctx.new_page()

            if not await ensure_logged_in(page):
                await page.close()
                await update.message.reply_text("Ошибка входа. Проверьте .env", reply_markup=default_reply_markup())
                return ConversationHandler.END

            info = await get_profile_info(page)
            await page.close()

            msg = (
                "Профиль дилера\n\n"
                f"Логин: {info['login']}\n"
                f"Баланс: {info['balance']}\n"
                f"Скидка: {info['discount']}\n"
                f"Активных клиентов: {info['active_clients']}"
            )
            await update.message.reply_text(msg, reply_markup=default_reply_markup())

        except Exception as e:
            logger.error(e)
            await update.message.reply_text(f"Ошибка: {e}", reply_markup=default_reply_markup())
        return ConversationHandler.END

    elif text == BUTTON_SERVER_STATS:
        await update.message.reply_text("Получаю статистику серверов...")
        try:
            ctx = await get_browser()
            page = await ctx.new_page()

            if not await ensure_logged_in(page):
                await page.close()
                await update.message.reply_text("Ошибка входа. Проверьте .env", reply_markup=default_reply_markup())
                return ConversationHandler.END

            data = await get_server_stats(page)
            await page.close()

            res = "Статистика серверов\n\n"
            if data["servers"]:
                res += "Нагрузка:\n"
                for s, l in data["servers"].items():
                    res += f"- {s}: {l}\n"
                res += "\n"
            if data["stats"].get("total_active"):
                res += f"Активных клиентов: {data['stats']['total_active']}\n"

            if not data["servers"] and data["stats"]["total_active"] == "0":
                res += "\nИнформация о серверах недоступна."

            await update.message.reply_text(res, reply_markup=default_reply_markup())

        except Exception as e:
            logger.error(e)
            await update.message.reply_text(f"Ошибка: {e}", reply_markup=default_reply_markup())
        return ConversationHandler.END

    elif text == BUTTON_CHECK:
        await update.message.reply_text("Введите логин клиента:", reply_markup=ReplyKeyboardRemove())
        return WAITING_CHECK_LOGIN

    return ConversationHandler.END


async def receive_login(update: Update, context: ContextTypes.DEFAULT_TYPE):
    context.user_data["new_login"] = update.message.text.strip()
    await update.message.reply_text("Введите пароль для нового пользователя:")
    return WAITING_PASSWORD


async def receive_password(update: Update, context: ContextTypes.DEFAULT_TYPE):
    context.user_data["new_password"] = update.message.text.strip()

    keyboard = [
        [
            InlineKeyboardButton("Telekarta", callback_data="pkg_Telekarta"),
            InlineKeyboardButton("Telekarta+56", callback_data="pkg_Telekarta+56"),
        ],
        [
            InlineKeyboardButton("NTV Plus 56", callback_data="pkg_NTV Plus 56"),
            InlineKeyboardButton("Russkiy Mir", callback_data="pkg_Russkiy Mir"),
        ],
        [InlineKeyboardButton("Показать все пакеты", callback_data="show_all_packages")],
    ]
    await update.message.reply_text(
        "Выберите пакет:\n\nПопулярные — на кнопках выше.\nИли нажмите «Показать все пакеты».",
        reply_markup=InlineKeyboardMarkup(keyboard),
    )
    return WAITING_PACKAGE


async def show_all_packages(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()

    keyboard: List[List[InlineKeyboardButton]] = []
    pkgs = list(PACKAGES_WITH_PORTS.keys())
    for i in range(0, len(pkgs), 2):
        row = [InlineKeyboardButton(pkgs[i][:30], callback_data=f"pkg_{pkgs[i]}")]
        if i + 1 < len(pkgs):
            row.append(InlineKeyboardButton(pkgs[i + 1][:30], callback_data=f"pkg_{pkgs[i + 1]}"))
        keyboard.append(row)

    keyboard.append([InlineKeyboardButton("Назад", callback_data="back_to_popular")])

    await q.edit_message_text("Все доступные пакеты:\n\nВыберите пакет:", reply_markup=InlineKeyboardMarkup(keyboard))
    return WAITING_PACKAGE


async def back_to_popular_packages(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()

    keyboard = [
        [
            InlineKeyboardButton("Telekarta", callback_data="pkg_Telekarta"),
            InlineKeyboardButton("Telekarta+56", callback_data="pkg_Telekarta+56"),
        ],
        [
            InlineKeyboardButton("NTV Plus 56", callback_data="pkg_NTV Plus 56"),
            InlineKeyboardButton("Russkiy Mir", callback_data="pkg_Russkiy Mir"),
        ],
        [InlineKeyboardButton("Показать все пакеты", callback_data="show_all_packages")],
    ]
    await q.edit_message_text(
        "Выберите пакет:\n\nПопулярные — на кнопках выше.\nИли нажмите «Показать все пакеты».",
        reply_markup=InlineKeyboardMarkup(keyboard),
    )
    return WAITING_PACKAGE


async def receive_package_choice(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()

    package = q.data.replace("pkg_", "")
    context.user_data["package"] = package

    keyboard = [
        [
            InlineKeyboardButton("30 дней", callback_data="dur_30"),
            InlineKeyboardButton("60 дней", callback_data="dur_60"),
            InlineKeyboardButton("90 дней", callback_data="dur_90"),
        ],
        [
            InlineKeyboardButton("120 дней", callback_data="dur_120"),
            InlineKeyboardButton("150 дней", callback_data="dur_150"),
            InlineKeyboardButton("180 дней", callback_data="dur_180"),
        ],
        [InlineKeyboardButton("360 дней", callback_data="dur_360")],
    ]
    await q.edit_message_text(
        f"Пакет: {package}\n\nВыберите срок подписки:",
        reply_markup=InlineKeyboardMarkup(keyboard),
    )
    return WAITING_DURATION


async def receive_duration_and_process(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()

    duration = int(q.data.replace("dur_", ""))
    username = context.user_data["new_login"]
    password = context.user_data["new_password"]
    package_name = context.user_data["package"]

    await q.edit_message_text("Обрабатываю запрос... Пожалуйста, подождите.")

    try:
        ctx = await get_browser()
        page = await ctx.new_page()

        if not await ensure_logged_in(page):
            await page.close()
            await q.message.reply_text("Ошибка входа. Проверьте .env", reply_markup=default_reply_markup())
            return ConversationHandler.END

        ok_add = await add_client(page, username, password)
        if not ok_add:
            await page.close()
            await q.message.reply_text("Не удалось добавить клиента. См. логи/скриншоты.",
                                       reply_markup=default_reply_markup())
            return ConversationHandler.END

        success, port, end_date = await buy_package(page, username, package_name, duration)
        await page.close()

        if success:
            msg = (
                "Подписка успешно оформлена!\n\n"
                f"Логин: {username}\n"
                f"Пароль: {password}\n"
                f"Пакет: {package_name}\n"
                f"Протокол: newcamd\n"
                f"Порт: {port}\n"
                f"Действует до: {end_date}\n"
            )
            await q.message.reply_text(msg, reply_markup=default_reply_markup())
        else:
            await q.message.reply_text("Ошибка при покупке пакета. См. логи/скриншоты.",
                                       reply_markup=default_reply_markup())

    except Exception as e:
        logger.error(f"Ошибка: {e}")
        await q.message.reply_text(f"Ошибка: {e}", reply_markup=default_reply_markup())

    context.user_data.clear()
    return ConversationHandler.END


async def check_subscription(update: Update, context: ContextTypes.DEFAULT_TYPE):
    username = update.message.text.strip()
    await update.message.reply_text("Обновляю данные...")

    try:
        ctx = await get_browser()
        page = await ctx.new_page()

        if not await ensure_logged_in(page):
            await page.close()
            await update.message.reply_text("Ошибка входа. Проверьте .env", reply_markup=default_reply_markup())
            return ConversationHandler.END

        csv_path = await save_clients_table(page)
        await page.close()

        if not csv_path:
            await update.message.reply_text("Не удалось получить таблицу клиентов.",
                                            reply_markup=default_reply_markup())
            return ConversationHandler.END

        info = await get_client_subscription(username)

        if info:
            res = (
                "Информация о клиенте\n\n"
                f"Логин: {info.get('Login', '-')}\n"
                f"Пакет: {info.get('Package', 'не активирован') or 'не активирован'}\n"
                f"Начало: {info.get('Start', '-') or '-'}\n"
                f"Окончание: {info.get('End', '-') or '-'}"
            )
        else:
            res = f"Клиент {username} не найден."

        await update.message.reply_text(res, reply_markup=default_reply_markup())

    except Exception as e:
        logger.error(e)
        await update.message.reply_text(f"Ошибка: {e}", reply_markup=default_reply_markup())

    return ConversationHandler.END


async def cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Операция отменена.", reply_markup=default_reply_markup())
    context.user_data.clear()
    return ConversationHandler.END


# ──────────────────────────────────────────────────────────────────────────────
# Регистрация бота
# ──────────────────────────────────────────────────────────────────────────────
def build_application() -> Application:
    app = Application.builder().token(BOT_TOKEN).build()

    create_subscription_handler = ConversationHandler(
        entry_points=[MessageHandler(filters.Regex(r'^Купить подписку$'), button_handler)],
        states={
            WAITING_LOGIN: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_login)],
            WAITING_PASSWORD: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_password)],
            WAITING_PACKAGE: [
                CallbackQueryHandler(show_all_packages, pattern=r'^show_all_packages$'),
                CallbackQueryHandler(back_to_popular_packages, pattern=r'^back_to_popular$'),
                CallbackQueryHandler(receive_package_choice, pattern=r'^pkg_'),
            ],
            WAITING_DURATION: [CallbackQueryHandler(receive_duration_and_process, pattern=r'^dur_')],
        },
        fallbacks=[CommandHandler("cancel", cancel)],
    )

    check_subscription_handler = ConversationHandler(
        entry_points=[MessageHandler(filters.Regex(r'^Проверить подписку$'), button_handler)],
        states={WAITING_CHECK_LOGIN: [MessageHandler(filters.TEXT & ~filters.COMMAND, check_subscription)]},
        fallbacks=[CommandHandler("cancel", cancel)],
    )

    app.add_handler(CommandHandler("start", start))
    app.add_handler(create_subscription_handler)
    app.add_handler(check_subscription_handler)
    app.add_handler(MessageHandler(filters.Regex(r'^Профиль$'), button_handler))
    app.add_handler(MessageHandler(filters.Regex(r'^Статистика серверов$'), button_handler))

    return app


async def post_stop(app: Application) -> None:
    """Callback при остановке бота."""
    await close_browser()


def main():
    if not BOT_TOKEN:
        logger.error("BOT_TOKEN не задан в .env")
        return
    if not OSCAM_USER or not OSCAM_PASS:
        logger.error("OSCAM_USER/OSCAM_PASS не заданы в .env")
        return

    app = build_application()

    # Регистрируем callback для graceful shutdown
    app.post_stop = post_stop

    logger.info("Бот запущен")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
