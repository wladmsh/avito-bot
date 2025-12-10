# bot.py
import asyncio
import aiohttp
import re
import os
import json
import logging
from aiogram import Bot, Dispatcher, types
from aiogram.filters import Command
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from bs4 import BeautifulSoup
from dotenv import load_dotenv
from typing import Optional

load_dotenv()
TOKEN = os.getenv("TELEGRAM_TOKEN")
ADMIN_ID = int(os.getenv("CHAT_ID"))
PROXY = os.getenv("PROXY")  # optional, e.g. "http://user:pass@host:port"
USER_AGENT = os.getenv("USER_AGENT", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                                     "(KHTML, like Gecko) Chrome/120 Safari/537.36")

if not TOKEN or not ADMIN_ID:
    raise RuntimeError("TELEGRAM_TOKEN and CHAT_ID must be set in .env")

bot = Bot(token=TOKEN, parse_mode="HTML", proxy=PROXY if PROXY else None)
storage = MemoryStorage()
dp = Dispatcher(storage=storage)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("avito-snipe")

TASKS_FILE = "tasks.json"
SAVE_LOCK = asyncio.Lock()

class AddTask(StatesGroup):
    url = State()
    name = State()
    min_price = State()
    max_price = State()

class EditTask(StatesGroup):
    which = State()   # holds "id:field" like "3:min_price"
    value = State()

# --- tasks load/save ---
def load_tasks():
    if os.path.exists(TASKS_FILE):
        with open(TASKS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

async def save_tasks_async(tasks):
    async with SAVE_LOCK:
        with open(TASKS_FILE, "w", encoding="utf-8") as f:
            json.dump(tasks, f, ensure_ascii=False, indent=2)

tasks = load_tasks()  # dict of id -> task

# Ensure tasks keys are strings
tasks = {str(k): v for k, v in tasks.items()}

def next_task_id():
    if not tasks:
        return "1"
    ids = [int(k) for k in tasks.keys() if k.isdigit()]
    return str(max(ids) + 1)

# --- keyboards ---
def main_kb():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="➕ Добавить задание", callback_data="add")],
        [InlineKeyboardButton(text="📋 Список заданий", callback_data="list")],
        [InlineKeyboardButton(text="ℹ️ Помощь", callback_data="help")]
    ])

def task_kb(task_id: str, task: dict):
    kb = InlineKeyboardMarkup(row_width=2)
    kb.add(
        InlineKeyboardButton(text=("✅ Выключить" if task.get("active", True) else "🔁 Включить"),
                             callback_data=f"toggle:{task_id}"),
        InlineKeyboardButton(text="✏️ Редактировать", callback_data=f"edit_menu:{task_id}"),
    )
    kb.add(
        InlineKeyboardButton(text="🗑 Удалить", callback_data=f"delete:{task_id}"),
        InlineKeyboardButton(text="🔎 Открыть URL", url=task["url"])
    )
    return kb

def list_kb():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="back_main")]
    ])

def edit_field_kb(task_id: str):
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton("Название", callback_data=f"edit:{task_id}:name"),
         InlineKeyboardButton("URL", callback_data=f"edit:{task_id}:url")],
        [InlineKeyboardButton("Мин. цена", callback_data=f"edit:{task_id}:min_price"),
         InlineKeyboardButton("Макс. цена", callback_data=f"edit:{task_id}:max_price")],
        [InlineKeyboardButton("⬅️ Назад", callback_data="list")]
    ])

# --- handlers ---
@dp.message(Command("start"))
async def start(m: types.Message):
    if m.from_user.id != ADMIN_ID:
        return
    await m.answer("Avito-снайпер запущен. Выберите действие:", reply_markup=main_kb())

@dp.callback_query(lambda c: c.data == "help")
async def help_cb(cb: types.CallbackQuery):
    await cb.message.edit_text(
        "Я мониторю Avito по отфильтрованным ссылкам. Порядок добавления:\n"
        "1) отправь ссылку на страницу поиска/категории Avito (с фильтрами как нужно)\n"
        "2) дай имя заданию\n"
        "3) укажи минимальную цену (0 = нет минимума)\n"
        "4) укажи максимальную цену\n\n"
        "В списке заданий можно включать/выключать, редактировать параметры и удалять задания.",
        reply_markup=main_kb()
    )

@dp.callback_query(lambda c: c.data == "back_main")
async def back_main(cb: types.CallbackQuery):
    await cb.message.edit_text("Главное меню", reply_markup=main_kb())

# ---------- Add task flow ----------
@dp.callback_query(lambda c: c.data == "add")
async def add1(cb: types.CallbackQuery, state: FSMContext):
    await cb.message.edit_text("Кидай ссылку Avito (страница поиска с фильтрами).")
    await state.set_state(AddTask.url)

@dp.message(AddTask.url)
async def url_handler(m: types.Message, state: FSMContext):
    if "avito.ru" not in m.text:
        await m.answer("Не та ссылка — нужна ссылка домена avito.ru")
        return
    await state.update_data(url=m.text.strip())
    await m.answer("Назови задание (короткое имя).")
    await state.set_state(AddTask.name)

@dp.message(AddTask.name)
async def name_handler(m: types.Message, state: FSMContext):
    await state.update_data(name=m.text.strip())
    await m.answer("Мин. цена? (0 = без минимума)")
    await state.set_state(AddTask.min_price)

@dp.message(AddTask.min_price)
async def minp_handler(m: types.Message, state: FSMContext):
    p = m.text.replace(" ", "").replace("₽", "").strip()
    if not p.isdigit():
        await m.answer("Введи число (0 = без минимума).")
        return
    min_price = int(p)
    if min_price == 0:
        min_price = None
    await state.update_data(min_price=min_price)
    await m.answer("Макс. цена?")
    await state.set_state(AddTask.max_price)

@dp.message(AddTask.max_price)
async def maxp_handler(m: types.Message, state: FSMContext):
    p = m.text.replace(" ", "").replace("₽", "").strip()
    if not p.isdigit():
        await m.answer("Только число.")
        return
    max_price = int(p)
    data = await state.get_data()
    tid = next_task_id()
    tasks[tid] = {
        "name": data["name"],
        "url": data["url"],
        "min_price": data.get("min_price"),
        "max_price": max_price,
        "seen": [],
        "active": True
    }
    await save_tasks_async(tasks)
    await m.answer(f"Готово! «{data['name']}» следит.", reply_markup=main_kb())
    await state.clear()

# ---------- List tasks ----------
@dp.callback_query(lambda c: c.data == "list")
async def lst(cb: types.CallbackQuery):
    if not tasks:
        await cb.message.edit_text("Список пуст", reply_markup=main_kb())
        return
    txt = "<b>Задания:</b>\n\n"
    for i, (k, t) in enumerate(sorted(tasks.items(), key=lambda x: int(x[0])), start=1):
        mn = f"от {t['min_price']:,} ₽ " if t.get('min_price') else ""
        act = "🟢" if t.get("active", True) else "🔴"
        txt += f"{act} <b>{i}. {t['name']}</b> (id: {k})\n{mn}— {t['max_price']:,} ₽\n{t['url']}\n\n"
    await cb.message.edit_text(txt, reply_markup=list_kb())

# ---------- Task action callbacks ----------
@dp.callback_query(lambda c: c.data and c.data.startswith("toggle:"))
async def toggle(cb: types.CallbackQuery):
    _, tid = cb.data.split(":", 1)
    t = tasks.get(tid)
    if not t:
        await cb.answer("Задание не найдено", show_alert=True)
        return
    t["active"] = not t.get("active", True)
    await save_tasks_async(tasks)
    await cb.answer("Статус изменён")
    # обновить сообщение с клавишами (если возможно)
    await cb.message.edit_text(f"<b>{t['name']}</b>\nСтатус: {'активно' if t['active'] else 'выключено'}",
                               reply_markup=task_kb(tid, t))

@dp.callback_query(lambda c: c.data and c.data.startswith("delete:"))
async def delete(cb: types.CallbackQuery):
    _, tid = cb.data.split(":", 1)
    t = tasks.pop(tid, None)
    if t:
        await save_tasks_async(tasks)
        await cb.answer("Задание удалено")
        await cb.message.edit_text("Удалено.", reply_markup=main_kb())
    else:
        await cb.answer("Задание не найдено", show_alert=True)

@dp.callback_query(lambda c: c.data and c.data.startswith("edit_menu:"))
async def edit_menu(cb: types.CallbackQuery):
    _, tid = cb.data.split(":", 1)
    t = tasks.get(tid)
    if not t:
        await cb.answer("Не найдено", show_alert=True)
        return
    txt = f"<b>{t['name']}</b>\nМин: {t.get('min_price') or 0} ₽\nМакс: {t['max_price']:,} ₽\n\nВыберите поле для редактирования."
    await cb.message.edit_text(txt, reply_markup=edit_field_kb(tid))

@dp.callback_query(lambda c: c.data and c.data.startswith("edit:"))
async def edit_choice(cb: types.CallbackQuery, state: FSMContext):
    # callback data format: edit:<task_id>:<field>
    _, tid, field = cb.data.split(":", 2)
    if tid not in tasks:
        await cb.answer("Задание пропало", show_alert=True)
        return
    await state.update_data(edit_target=f"{tid}:{field}")
    prompt = "Введи новое значение:"
    if field == "min_price":
        prompt = "Введи новую минимальную цену (0 = без минимума)"
    if field == "max_price":
        prompt = "Введи новую максимальную цену"
    if field == "url":
        prompt = "Введи новый URL (ссылка на страницу поиска Avito)"
    await cb.message.edit_text(prompt)
    await state.set_state(EditTask.value)

@dp.message(EditTask.value)
async def edit_value(m: types.Message, state: FSMContext):
    data = await state.get_data()
    target = data.get("edit_target")
    if not target:
        await m.answer("Ошибка состояния.")
        await state.clear()
        return
    tid, field = target.split(":", 1)
    if tid not in tasks:
        await m.answer("Задание не найдено.")
        await state.clear()
        return

    val = m.text.strip()
    if field in ("min_price", "max_price"):
        p = val.replace(" ", "").replace("₽", "")
        if not p.isdigit():
            await m.answer("Нужно число.")
            return
        num = int(p)
        if field == "min_price" and num == 0:
            tasks[tid]["min_price"] = None
        else:
            tasks[tid][field] = num
    elif field == "name":
        tasks[tid]["name"] = val
    elif field == "url":
        if "avito.ru" not in val:
            await m.answer("Нужна ссылка avito.ru")
            return
        tasks[tid]["url"] = val
    else:
        await m.answer("Неизвестное поле.")
        await state.clear()
        return

    await save_tasks_async(tasks)
    await m.answer("Сохранено.", reply_markup=main_kb())
    await state.clear()

# ---------- show single task (from list) ----------
@dp.callback_query(lambda c: c.data and c.data.startswith("show:"))
async def show_task(cb: types.CallbackQuery):
    _, tid = cb.data.split(":", 1)
    t = tasks.get(tid)
    if not t:
        await cb.answer("Не найдено")
        return
    mn = f"от {t.get('min_price'):,} ₽ " if t.get("min_price") else ""
    txt = f"<b>{t['name']}</b>\n{mn}— {t['max_price']:,} ₽\n{t['url']}"
    await cb.message.edit_text(txt, reply_markup=task_kb(tid, t))

# ---------- watcher ----------
async def fetch_html(session: aiohttp.ClientSession, url: str) -> Optional[str]:
    try:
        headers = {"User-Agent": USER_AGENT, "Accept-Language": "ru-RU,ru;q=0.9"}
        async with session.get(url, timeout=25, headers=headers) as r:
            if r.status != 200:
                logger.warning("Bad status %s for %s", r.status, url)
                return None
            return await r.text()
    except Exception as e:
        logger.exception("fetch error: %s", e)
        return None

def extract_ad_id_from_link(link: str) -> Optional[str]:
    # Avito sometimes has /item/xxxxx or other patterns — try multiple ways
    # Try explicit digits at end
    m = re.search(r"-(\d+)$", link)
    if m:
        return m.group(1)
    m = re.search(r"_(\d+)", link)
    if m:
        return m.group(1)
    # fallback: any long sequence of digits
    m = re.search(r"(\d{6,})", link)
    return m.group(1) if m else None

async def process_task(session: aiohttp.ClientSession, t_id: str, t: dict):
    if not t.get("active", True):
        return False
    html = await fetch_html(session, t["url"])
    if not html:
        return False
    soup = BeautifulSoup(html, "html.parser")
    new_seen = False

    # Avito uses many different containers; the selector from your original approach:
    items = soup.find_all("div", {"data-marker": "item"})
    # fallback: search for links with item-title
    if not items:
        items = soup.find_all("a", {"data-marker": "item-title"})

    # iterate reversed to get oldest first -> prevents bursts
    for item in reversed(items):
        try:
            a = item.find("a", {"data-marker": "item-title"}) or item.find("a", href=True)
            if not a:
                continue
            href = a.get("href") or a["href"]
            link = href if href.startswith("http") else "https://www.avito.ru" + href
            ad_id = extract_ad_id_from_link(link)
            if not ad_id:
                continue
            if ad_id in t.get("seen", []):
                continue

            # price
            pr = item.find("meta", {"itemprop": "price"})
            if pr:
                try:
                    price = int(pr["content"])
                except:
                    continue
            else:
                # try to parse from text
                price_text = item.get_text(" ", strip=True)
                m = re.search(r"(\d[\d\s]*?)\s*₽", price_text)
                if m:
                    price = int(m.group(1).replace(" ", ""))
                else:
                    continue

            if t.get("min_price") and price < t.get("min_price"):
                continue
            if t.get("max_price") and price > t.get("max_price"):
                continue

            title = a.get("title") or a.get_text(strip=True)
            loc = item.find("div", {"data-marker": "item-address"}) or item.find("span", {"class": "location"})
            location = loc.get_text(strip=True) if loc else ""

            photo = item.find("img", {"itemprop": "image"}) or item.find("img")
            photo_url = None
            if photo:
                src = photo.get("src") or photo.get("data-src") or photo.get("data-original")
                if src and "stub" not in src:
                    if src.startswith("//"):
                        src = "https:" + src
                    photo_url = src

            msg = f"<b>Новое • {t['name']}</b>\n\n<b>{title}</b>\n<b>{price:,} ₽</b>\n{location}\n\n{link}"

            # send
            try:
                if photo_url:
                    await bot.send_photo(ADMIN_ID, photo_url, caption=msg)
                else:
                    await bot.send_message(ADMIN_ID, msg)
            except Exception as e:
                logger.exception("send error: %s", e)
                # fallback to message
                try:
                    await bot.send_message(ADMIN_ID, msg)
                except:
                    pass

            # mark seen and keep size reasonable
            seen = t.get("seen", [])
            seen.append(ad_id)
            if len(seen) > 2500:
                seen = seen[-2000:]
            t["seen"] = seen
            new_seen = True

            # be gentle between messages
            await asyncio.sleep(1.2)
        except Exception:
            continue

    return new_seen

async def watcher():
    # session setup with optional proxy via bot session config if needed
    conn = aiohttp.TCPConnector(limit_per_host=8)
    timeout = aiohttp.ClientTimeout(total=30)
    async with aiohttp.ClientSession(connector=conn, timeout=timeout) as session:
        while True:
            try:
                any_changed = False
                # iterate over a snapshot of tasks to avoid runtime dict change
                for tid, t in list(tasks.items()):
                    if not t.get("active", True):
                        continue
                    try:
                        changed = await process_task(session, tid, t)
                        if changed:
                            any_changed = True
                            # save after each changed task to persist seen state incrementally
                            await save_tasks_async(tasks)
                    except Exception:
                        logger.exception("Error processing task %s", tid)
                        continue
                # small sleep between full cycles
                await asyncio.sleep(60)
            except Exception:
                logger.exception("Watcher crashed, restarting loop")
                await asyncio.sleep(5)

# ---------- startup ----------
async def on_startup(_):
    try:
        await bot.send_message(ADMIN_ID, "Я живой и начал мониторить Avito", reply_markup=main_kb())
    except Exception:
        logger.exception("Cannot send startup message")

async def main():
    dp.startup.register(on_startup)
    # run watcher as background task
    task = asyncio.create_task(watcher())
    # run polling (aiogram will handle graceful shutdown)
    await dp.start_polling(bot)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Stopped by user")
