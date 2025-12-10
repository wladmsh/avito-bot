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

def main_kb():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="Добавить задание", callback_data="add_task")],
        [InlineKeyboardButton(text="Список заданий", callback_data="list_tasks")]
    ])

@dp.message(Command("start"))
async def start(message: types.Message):
    if message.from_user.id != ADMIN_ID:
        return
    await message.answer("Avito-снайпер онлайн", reply_markup=main_kb())

@dp.callback_query(lambda c: c.data == "add_task")
async def cmd_add_task(callback: types.CallbackQuery, state: FSMContext):
    await callback.message.edit_text("Кидай ссылку Avito (с фильтрами и сортировкой «По дате»)")
    await state.set_state(AddTask.url)
    await callback.answer()

@dp.message(AddTask.url)
async def get_url(message: types.Message, state: FSMContext):
    if "avito.ru" not in message.text:
        await message.answer("Это не ссылка Avito")
        return
    await state.update_data(url=message.text.strip())
    await message.answer("Назови задание\n(например: 1-кк ЦАО до 70к)")
    await state.set_state(AddTask.name)

@dp.message(AddTask.name)
async def get_name(message: types.Message, state: FSMContext):
    await state.update_data(name=message.text.strip())
    await message.answer("Минимальная цена?\n(0 — если без ограничения")
    await state.set_state(AddTask.min_price)

@dp.message(AddTask.min_price)
async def get_min(message: types.Message, state: FSMContext):
    text = message.text.replace(" ", "").replace("₽", "")
    min_p = int(text) if text.isdigit() and int(text) > 0 else None
    await state.update_data(min_price=min_p)
    await message.answer("Максимальная цена?\n(обязательно число)")
    await state.set_state(AddTask.max_price)

@dp.message(AddTask.max_price)
async def get_max(message: types.Message, state: FSMContext):
    text = message.text.replace(" ", "")
    if not text.isdigit():
        await message.answer("Просто число, без букв")
        return
    data = await state.get_data()
    task_id = str(len(tasks) + 1)
    tasks[task_id] = {
        "name": data["name"],
        "url": data["url"],
        "min_price": data.get("min_price"),
        "max_price": int(text),
        "seen": [],
        "active": True
    }
    save_tasks()
    await message.answer(f"Задание «{data['name']}» запущено!", reply_markup=main_kb())
    await state.clear()

@dp.callback_query(lambda c: c.data == "list_tasks")
async def list_tasks(callback: types.CallbackQuery):
    if not tasks:
        await callback.message.edit_text("Пока пусто", reply_markup=main_kb())
        return
    text = "Активные задания:\n\n"
    for tid, t in tasks.items():
        minp = f"от {t['min_price']:,} ₽ " if t['min_price'] else ""
        text += f"<b>{tid}. {t['name']}</b>\n{minp}— {t['max_price']:,} ₽\n\n"
    await callback.message.edit_text(text, reply_markup=main_kb())

# Фоновый мониторинг
async def watcher():
    async with aiohttp.ClientSession() as session:
        while True:
            for task in tasks.values():
                if not task.get("active", True):
                    continue
                try:
                    async with session.get(task["url"], timeout=25) as r:
                        if r.status != 200: continue
                        html = await r.text()
                    soup = BeautifulSoup(html, "html.parser")
                    for item in reversed(soup.find_all("div", {"data-marker": "item"})):
                        try:
                            a = item.find("a", {"data-marker": "item-title"})
                            if not a: continue
                            link = "https://www.avito.ru" + a["href"]
                            ad_id = re.search(r"_(\d+)", link).group(1)
                            if ad_id in task["seen"]: continue

                            price_tag = item.find("meta", {"itemprop": "price"})
                            if not price_tag: continue
                            price = int(price_tag["content"])

                            if task["min_price"] and price < task["min_price"]: continue
                            if price > task["max_price"]: continue

                            title = a.get("title", "Без названия")
                            loc = item.find("div", {"data-marker": "item-address"})
                            location = loc.get_text(strip=True) if loc else ""

                            photo = item.find("img", {"itemprop": "image"})
                            photo_url = photo["src"] if photo and photo.get("src") and "stub" not in photo["src"] else None

                            msg = f"<b>Новое • {task['name']}</b>\n\n<b>{title}</b>\n<b>{price:,} ₽</b>\n{location}\n\n{link}"

                            if photo_url:
                                await bot.send_photo(ADMIN_ID, photo_url, caption=msg)
                            else:
                                await bot.send_message(ADMIN_ID, msg)

                            task["seen"].append(ad_id)
                            if len(task["seen"]) > 3000:
                                task["seen"] = task["seen"][-2000:]
                            save_tasks()
                            await asyncio.sleep(1.3)
                        except:
                            continue
                except:
                    pass
            await asyncio.sleep(75)

async def main():
    asyncio.create_task(watcher())
    await bot.send_message(ADMIN_ID, "Бот запустился и начал мониторить Avito")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
