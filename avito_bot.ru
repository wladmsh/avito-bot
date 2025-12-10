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

load_dotenv()

TOKEN = os.getenv("TELEGRAM_TOKEN")
ADMIN_ID = int(os.getenv("CHAT_ID"))

bot = Bot(token=TOKEN, parse_mode="HTML")
storage = MemoryStorage()
dp = Dispatcher(storage=storage)
logging.basicConfig(level=logging.INFO)

class AddTask(StatesGroup):
    url = State()
    name = State()
    min_price = State()
    max_price = State()

tasks = {}
TASKS_FILE = "tasks.json"

def load_tasks():
    if os.path.exists(TASKS_FILE):
        with open(TASKS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

def save_tasks():
    with open(TASKS_FILE, "w", encoding="utf-8") as f:
        json.dump(tasks, f, ensure_ascii=False, indent=2)

tasks = load_tasks()

def main_keyboard():
    kb = [
        [InlineKeyboardButton(text="Добавить задание", callback_data="add_task")],
        [InlineKeyboardButton(text="Список заданий", callback_data="list_tasks")],
        [InlineKeyboardButton(text="Обновить всё сейчас", callback_data="force_check")]
    ]
    return InlineKeyboardMarkup(inline_keyboard=kb)

@dp.message(Command("start"))
async def start(message: types.Message):
    if message.from_user.id != ADMIN_ID:
        return
    await message.answer("Привет! Я твой Avito-снайпер", reply_markup=main_keyboard())

@dp.callback_query(lambda c: c.data == "add_task")
async def add_task(callback: types.CallbackQuery, state: FSMContext):
    await callback.message.edit_text("Пришли ссылку Avito с фильтрами и сортировкой «По дате»")
    await state.set_state(AddTask.url)
    await callback.answer()

@dp.message(AddTask.url)
async def get_url(message: types.Message, state: FSMContext):
    if "avito.ru" not in message.text:
        await message.answer("Это не ссылка Avito, попробуй ещё раз")
        return
    await state.update_data(url=message.text.strip())
    await message.answer("Как назовём задание? (например: 1-к квартира ЦАО до 60к)")
    await state.set_state(AddTask.name)

@dp.message(AddTask.name)
async def get_name(message: types.Message, state: FSMContext):
    await state.update_data(name=message.text)
    await message.answer("Минимальная цена (или 0 — без ограничения)")
    await state.set_state(AddTask.min_price)

@dp.message(AddTask.min_price)
async def get_min(message: types.Message, state: FSMContext):
    text = message.text.replace(" ", "").replace("₽", "")
    min_p = int(text) if text.isdigit() and int(text) > 0 else None
    await state.update_data(min_price=min_p)
    await message.answer("Максимальная цена (обязательно, например 65000)")
    await state.set_state(AddTask.max_price)

@dp.message(AddTask.max_price)
async def get_max(message: types.Message, state: FSMContext):
    if not message.text.replace(" ", "").isdigit():
        await message.answer("Напиши просто число")
        return
    data = await state.get_data()
    task_id = str(len(tasks) + 1)
    tasks[task_id] = {
        "name": data["name"],
        "url": data["url"],
        "min_price": data["min_price"],
        "max_price": int(message.text.replace(" ", "")),
        "seen": [],
        "active": True
    }
    save_tasks()
    await message.answer(f"Задание «{data['name']}» создано и запущено!", reply_markup=main_keyboard())
    await state.clear()

@dp.callback_query(lambda c: c.data == "list_tasks")
async def list_tasks(callback: types.CallbackQuery):
    if not tasks:
        await callback.message.edit_text("Нет заданий", reply_markup=main_keyboard())
        return
    text = "Твои задания:\n\n"
    kb = []
    for tid, t in tasks.items():
        status = "ВКЛ" if t.get("active", True) else "ВЫКЛ"
        text += f"<b>{tid}. {t['name']}</b> — до {t['max_price']:,} ₽ — {status}\n"
        kb.append([InlineKeyboardButton(text=f"{tid}. {t['name'][:35]}…", callback_data=f"show_{tid}")])
    kb.append([InlineKeyboardButton(text="Назад", callback_data="back")])
    await callback.message.edit_text(text, reply_markup=InlineKeyboardMarkup(inline_keyboard=kb))

@dp.callback_query(lambda c: c.data == "back")
async def back(callback: types.CallbackQuery):
    await callback.message.edit_text("Главное меню", reply_markup=main_keyboard())

async def checker():
    async with aiohttp.ClientSession() as session:
        while True:
            for task_id, task in tasks.items():
                if not task.get("active", True):
                    continue
                try:
                    async with session.get(task["url"], timeout=20) as resp:
                        if resp.status != 200:
                            continue
                        html = await resp.text()
                    soup = BeautifulSoup(html, "html.parser")
                    items = soup.find_all("div", {"data-marker": "item"})
                    for item in reversed(items):
                        a = item.find("a", {"data-marker": "item-title"})
                        if not a:
                            continue
                        link = "https://www.avito.ru" + a["href"]
                        ad_id = re.search(r"_(\d+)", link).group(1)
                        if ad_id in task["seen"]:
                            continue
                        price_tag = item.find("meta", {"itemprop": "price"})
                        if not price_tag:
                            continue
                        price = int(price_tag["content"])
                        if task["min_price"] and price < task["min_price"]:
                            continue
                        if price > task["max_price"]:
                            continue
                        title = a.get("title", "Без названия")
                        location = item.find("div", {"data-marker": "item-address"})
                        location = location.get_text(strip=True) if location else ""
                        photo = item.find("img", {"itemprop": "image"})
                        photo_url = photo["src"] if photo and "stub" not in photo.get("src", "") else None

                        msg = f"<b>Новое • {task['name']}</b>\n\n<b>{title}</b>\n<b>{price:,} ₽</b>\n{location}\n\n{link}"

                        if photo_url:
                            await bot.send_photo(ADMIN_ID, photo_url, caption=msg)
                        else:
                            await bot.send_message(ADMIN_ID, msg)

                        task["seen"].append(ad_id)
                        if len(task["seen"]) > 3000:
                            task["seen"] = task["seen"][-2000:]
                        save_tasks()
                        await asyncio.sleep(1.5)
                except:
                    continue
            await asyncio.sleep(70)

async def main():
    asyncio.create_task(checker())
    await bot.send_message(ADMIN_ID, "Бот запущен и следит за Avito")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
