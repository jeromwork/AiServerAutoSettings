#!/usr/bin/env bash
# Сайт-прикрытие для точки входа: правдоподобный сервис хранения файлов и совместной работы.
# Объясняет большой трафик в обе стороны. Картинки рисует PIL, видеоинструкцию собирает ffmpeg.
# Использование: build-decoy.sh <домен> [каталог]. Повторный запуск пересобирает сайт.
set -euo pipefail
DOMAIN="${1:?домен}"; WEB="${2:-/var/www/rd-decoy}"
export DEBIAN_FRONTEND=noninteractive
need=(); command -v ffmpeg >/dev/null || need+=(ffmpeg); python3 -c 'import PIL' 2>/dev/null || need+=(python3-pil); [[ -f /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf ]] || need+=(fonts-dejavu-core)
if ((${#need[@]})); then apt-get update -qq && apt-get install -y -qq "${need[@]}" >/dev/null; fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/site/img" "$TMP/site/media" "$TMP/site/blog"

python3 - "$TMP/site" "$DOMAIN" <<'PY'
import random, sys, os, datetime
from PIL import Image, ImageDraw, ImageFont, ImageFilter
out, domain = sys.argv[1], sys.argv[2]
F = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'; FB = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
font = lambda s, b=False: ImageFont.truetype(FB if b else F, s)
rnd = random.Random(domain)
BRAND, ACC, ACC2 = 'CoreNet', (37, 99, 235), (16, 185, 129)

def grad(w, h, c1, c2):
    im = Image.new('RGB', (w, h)); d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / h; d.line([(0, y), (w, y)], fill=tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3)))
    return im

files = ['Договор_поставки_2026.pdf', 'Квартальный отчёт Q3.xlsx', 'Презентация_для_инвесторов.pptx', 'Фото_объекта_0412.jpg', 'Смета_ремонт_офиса.xlsx',
         'Макет_сайта_v7.fig', 'Видео_обучение_склад.mp4', 'Пакет_документов_ООО.zip', 'Регламент_ИТ.docx', 'Резервная_копия_1С.bak', 'План_продаж_2027.xlsx', 'Интервью_клиенты.m4a']
people = ['Анна Смирнова', 'Игорь Петров', 'Мария Козлова', 'Дмитрий Волков', 'Елена Новикова', 'Сергей Морозов']

def screenshot(i, title):
    W, H = 1280, 720; im = Image.new('RGB', (W, H), (247, 248, 250)); d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 240, H], fill=(17, 24, 39)); d.text((28, 26), BRAND, font=font(26, True), fill='white')
    for j, item in enumerate(['Все файлы', 'Общий доступ', 'Недавние', 'Избранное', 'Корзина', 'Команда', 'Настройки']):
        y = 100 + j * 46
        if j == i % 7: d.rounded_rectangle([14, y - 8, 226, y + 30], 8, fill=(31, 41, 55))
        d.text((32, y), item, font=font(17), fill=(229, 231, 235))
    d.rectangle([240, 0, W, 70], fill='white'); d.text((270, 22), title, font=font(24, True), fill=(17, 24, 39))
    d.rounded_rectangle([W - 380, 18, W - 120, 52], 17, fill=(243, 244, 246)); d.text((W - 360, 26), 'Поиск по файлам', font=font(15), fill=(156, 163, 175))
    d.ellipse([W - 70, 16, W - 32, 54], fill=ACC); d.text((W - 60, 24), 'АС', font=font(16, True), fill='white')
    rows = rnd.sample(files, 9)
    d.text((270, 92), 'Имя', font=font(15, True), fill=(107, 114, 128)); d.text((820, 92), 'Изменён', font=font(15, True), fill=(107, 114, 128)); d.text((1050, 92), 'Размер', font=font(15, True), fill=(107, 114, 128))
    for j, name in enumerate(rows):
        y = 130 + j * 62; d.rounded_rectangle([260, y - 10, W - 30, y + 46], 10, fill='white')
        ext = name.rsplit('.', 1)[-1]; col = {'pdf': (220, 38, 38), 'xlsx': (22, 163, 74), 'docx': (37, 99, 235), 'pptx': (234, 88, 12), 'mp4': (147, 51, 234)}.get(ext, (75, 85, 99))
        d.rounded_rectangle([276, y, 312, y + 36], 6, fill=col); d.text((280, y + 9), ext[:4].upper(), font=font(11, True), fill='white')
        d.text((330, y + 6), name, font=font(18), fill=(17, 24, 39))
        dt = datetime.date(2026, 10, 1) + datetime.timedelta(days=rnd.randint(0, 38))
        d.text((820, y + 6), dt.strftime('%d.%m.%Y') + f'  {rnd.choice(people).split()[0]}', font=font(16), fill=(75, 85, 99))
        d.text((1050, y + 6), f'{rnd.uniform(0.2, 480):.1f} МБ', font=font(16), fill=(75, 85, 99))
    if i % 3 == 1:
        d.rounded_rectangle([W - 470, H - 170, W - 30, H - 30], 14, fill='white', outline=(229, 231, 235), width=2)
        d.text((W - 450, H - 152), 'Синхронизация: 3 устройства', font=font(18, True), fill=(17, 24, 39))
        d.rounded_rectangle([W - 450, H - 110, W - 50, H - 94], 8, fill=(229, 231, 235)); d.rounded_rectangle([W - 450, H - 110, W - 50 - rnd.randint(40, 220), H - 94], 8, fill=ACC2)
        d.text((W - 450, H - 80), 'Загружено 1,8 ГБ из 2,3 ГБ', font=font(15), fill=(107, 114, 128))
    return im

titles = ['Все файлы', 'Общий доступ', 'Недавние', 'Проект «Склад»', 'Команда маркетинга', 'Отчёты 2026', 'Архив договоров', 'Резервные копии']
for i, t in enumerate(titles): screenshot(i, t).save(f'{out}/img/screen{i + 1}.jpg', quality=84, optimize=True, progressive=True)
hero = grad(1600, 700, (30, 58, 138), (15, 118, 110)); d = ImageDraw.Draw(hero)
for _ in range(60):
    x, y, r = rnd.randint(0, 1600), rnd.randint(0, 700), rnd.randint(20, 140); d.ellipse([x - r, y - r, x + r, y + r], outline=(255, 255, 255, 40), width=1)
hero = hero.filter(ImageFilter.GaussianBlur(1)); hero.paste(screenshot(0, 'Все файлы').resize((900, 506)), (640, 120)); hero.save(f'{out}/img/hero.jpg', quality=82, optimize=True, progressive=True)
for i, p in enumerate(people):
    im = grad(240, 240, tuple(rnd.randint(60, 200) for _ in range(3)), tuple(rnd.randint(20, 120) for _ in range(3))); d = ImageDraw.Draw(im)
    ini = ''.join(w[0] for w in p.split()); d.text((120, 120), ini, font=font(84, True), fill='white', anchor='mm'); im.save(f'{out}/img/team{i + 1}.jpg', quality=85)
for i in range(3):
    im = grad(1200, 630, tuple(rnd.randint(20, 90) for _ in range(3)), tuple(rnd.randint(90, 200) for _ in range(3))); d = ImageDraw.Draw(im)
    im.paste(screenshot(i + 3, titles[i + 3]).resize((760, 428)), (400, 120)); im.save(f'{out}/img/post{i + 1}.jpg', quality=82, optimize=True)
logo = Image.new('RGBA', (64, 64), (0, 0, 0, 0)); d = ImageDraw.Draw(logo); d.rounded_rectangle([0, 0, 63, 63], 14, fill=ACC); d.text((32, 32), 'C', font=font(40, True), fill='white', anchor='mm')
logo.save(f'{out}/favicon.ico', sizes=[(32, 32), (64, 64)]); logo.save(f'{out}/img/logo.png')
# кадры видеоинструкции: заставка + экраны с подписями
os.makedirs(f'{out}/../frames', exist_ok=True)
steps = ['Как начать работу в CoreNet', 'Шаг 1. Установите приложение на компьютер', 'Шаг 2. Выберите папки для синхронизации', 'Шаг 3. Пригласите коллег в общий доступ',
         'Шаг 4. Файлы доступны на всех устройствах', 'Резервные копии создаются автоматически', 'Готово! Удачной работы']
for i, s in enumerate(steps):
    im = screenshot(i, titles[i % len(titles)]) if 0 < i < len(steps) - 1 else grad(1280, 720, (30, 58, 138), (15, 118, 110))
    d = ImageDraw.Draw(im); d.rectangle([0, 620, 1280, 720], fill=(17, 24, 39)); d.text((640, 670), s, font=font(32, True), fill='white', anchor='mm')
    im.save(f'{out}/../frames/f{i:02d}.png')
PY

# Видео: ~70 с, 720p, H.264 + тихая дорожка; плавное приближение кадров
ffmpeg -loglevel error -y -framerate 1/10 -i "$TMP/frames/f%02d.png" -f lavfi -i anullsrc=r=44100:cl=stereo \
  -vf "zoompan=z='min(zoom+0.0007,1.08)':d=250:s=1280x720:fps=25,format=yuv420p" -c:v libx264 -preset veryfast -crf 26 -c:a aac -b:a 64k -shortest -movflags +faststart "$TMP/site/media/corenet-intro.mp4"
ffmpeg -loglevel error -y -i "$TMP/site/media/corenet-intro.mp4" -ss 3 -frames:v 1 -q:v 4 "$TMP/site/img/video-poster.jpg"

python3 - "$TMP/site" "$DOMAIN" <<'PY'
import sys, datetime, html
out, domain = sys.argv[1], sys.argv[2]
css = """*{box-sizing:border-box}body{margin:0;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#111827;background:#fff;line-height:1.6}
a{color:#2563eb;text-decoration:none}header{position:sticky;top:0;background:#fff;border-bottom:1px solid #e5e7eb;z-index:5}
.w{max-width:1120px;margin:0 auto;padding:0 24px}.nav{display:flex;align-items:center;gap:28px;height:64px}.nav .b{font-weight:700;font-size:20px;color:#111827;display:flex;gap:10px;align-items:center}
.nav .sp{flex:1}.btn{display:inline-block;background:#2563eb;color:#fff;padding:10px 20px;border-radius:10px;font-weight:600}.btn.o{background:#fff;color:#2563eb;border:1px solid #2563eb}
.hero{background:#0f172a url(/img/hero.jpg) center/cover;color:#fff;padding:120px 0}.hero h1{font-size:48px;margin:0 0 16px;max-width:640px;line-height:1.15}.hero p{font-size:20px;max-width:560px;opacity:.9}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:24px;margin:48px 0}.card{border:1px solid #e5e7eb;border-radius:16px;padding:24px}.card img{width:100%;border-radius:10px}
section{padding:64px 0}h2{font-size:34px;margin:0 0 12px}.muted{color:#6b7280}footer{background:#111827;color:#9ca3af;padding:48px 0;margin-top:40px}footer a{color:#d1d5db}
.price{font-size:40px;font-weight:700}.team img{width:96px;height:96px;border-radius:50%}video{width:100%;border-radius:16px;background:#000}
form.login{max-width:380px;margin:80px auto;border:1px solid #e5e7eb;border-radius:16px;padding:32px}form.login input{width:100%;padding:12px;margin:8px 0 16px;border:1px solid #d1d5db;border-radius:10px;font-size:16px}"""
open(f'{out}/style.css', 'w').write(css)
nav = '<header><div class="w nav"><a class="b" href="/"><img src="/img/logo.png" width="28" height="28" alt="">CoreNet</a><a href="/features.html">Возможности</a><a href="/pricing.html">Тарифы</a><a href="/video.html">Видео</a><a href="/blog/">Блог</a><a href="/about.html">О компании</a><span class="sp"></span><a class="btn o" href="/login">Войти</a></div></header>'
foot = f'<footer><div class="w"><b style="color:#fff">CoreNet</b> — облачное хранилище и синхронизация файлов для команд.<br>© 2024–2026 владелец домена. <a href="/privacy.html">Политика конфиденциальности</a> · <a href="mailto:support@{domain}">support@{domain}</a></div></footer>'
def page(name, title, body, desc='Облачное хранилище и синхронизация файлов для команд'):
    open(f'{out}/{name}', 'w').write(f'<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title><meta name="description" content="{desc}"><link rel="icon" href="/favicon.ico"><link rel="stylesheet" href="/style.css"></head><body>{nav}{body}{foot}</body></html>')
feat = [('Синхронизация папок', 'Изменения появляются на всех компьютерах команды за секунды. Работает и при плохом интернете — докачивает сама.', 1),
        ('Общий доступ', 'Ссылки с паролем и сроком действия, права на просмотр и редактирование.', 2), ('История версий', 'Любой файл можно вернуть к состоянию до 180 дней назад.', 3),
        ('Резервные копии', 'Ежедневные копии 1С, баз и рабочих папок с шифрованием.', 8), ('Удалённый рабочий стол', 'Рабочее место в облаке открывается с любого устройства.', 5), ('Видеозвонки', 'Созвоны прямо из папки проекта, с демонстрацией экрана.', 4)]
cards = ''.join(f'<div class="card"><img src="/img/screen{i}.jpg" alt="" loading="lazy"><h3>{t}</h3><p class="muted">{d}</p></div>' for t, d, i in feat)
page('index.html', 'CoreNet — облачное хранилище и синхронизация файлов для команд', f'<div class="hero"><div class="w"><h1>Файлы команды всегда под рукой</h1><p>Синхронизация папок, общий доступ и резервные копии на серверах в России. Без ограничений на размер файлов.</p><p><a class="btn" href="/pricing.html">Попробовать 30 дней бесплатно</a> &nbsp; <a class="btn o" style="background:transparent;color:#fff;border-color:#fff" href="/video.html">Смотреть видео</a></p></div></div><section><div class="w"><h2>Всё для совместной работы</h2><p class="muted">Более 1 200 компаний хранят у нас документы, сметы, фото объектов и видео.</p><div class="grid">{cards}</div></div></section>')
page('features.html', 'Возможности — CoreNet', '<section><div class="w"><h2>Возможности</h2>' + ''.join(f'<div class="card" style="margin:24px 0;display:grid;grid-template-columns:1fr 1fr;gap:24px;align-items:center"><div><h3>{t}</h3><p>{d}</p><p class="muted">Доступно на всех тарифах.</p></div><img src="/img/screen{i}.jpg" alt="" loading="lazy" style="width:100%;border-radius:10px"></div>' for t, d, i in feat) + '</div></section>')
plans = [('Старт', '0 ₽', '5 ГБ, 2 устройства'), ('Команда', '390 ₽', '1 ТБ, 10 пользователей, история 90 дней'), ('Бизнес', '1 490 ₽', '5 ТБ, без ограничений устройств, резервные копии 1С')]
page('pricing.html', 'Тарифы — CoreNet', '<section><div class="w"><h2>Тарифы</h2><p class="muted">Цена за пользователя в месяц при оплате за год.</p><div class="grid">' + ''.join(f'<div class="card"><h3>{n}</h3><div class="price">{p}</div><p>{d}</p><a class="btn" href="/login">Выбрать</a></div>' for n, p, d in plans) + '</div></div></section>')
page('video.html', 'Видеоинструкция — CoreNet', '<section><div class="w"><h2>Как начать работу за 2 минуты</h2><p class="muted">Установка, выбор папок и приглашение коллег.</p><video controls preload="metadata" poster="/img/video-poster.jpg"><source src="/media/corenet-intro.mp4" type="video/mp4"></video></div></section>')
people = ['Анна Смирнова — генеральный директор', 'Игорь Петров — технический директор', 'Мария Козлова — поддержка клиентов', 'Дмитрий Волков — инфраструктура', 'Елена Новикова — продукт', 'Сергей Морозов — продажи']
page('about.html', 'О компании — CoreNet', '<section><div class="w"><h2>О компании</h2><p>CoreNet работает с 2024 года. Наши серверы находятся в дата-центрах Москвы и Санкт-Петербурга, данные хранятся в России в соответствии с 152-ФЗ.</p><div class="grid team">' + ''.join(f'<div class="card"><img src="/img/team{i + 1}.jpg" alt=""><p><b>{p.split(" — ")[0]}</b><br><span class="muted">{p.split(" — ")[1]}</span></p></div>' for i, p in enumerate(people)) + '</div></div></section>')
page('privacy.html', 'Политика конфиденциальности — CoreNet', '<section><div class="w"><h2>Политика конфиденциальности</h2><p>владелец домена обрабатывает персональные данные пользователей исключительно для оказания услуг хранения и синхронизации файлов. Данные не передаются третьим лицам, кроме случаев, предусмотренных законодательством РФ.</p><p>Файлы пользователей шифруются при передаче и хранении. Доступ сотрудников к содержимому файлов отсутствует.</p></div></section>')
posts = [('kak-ne-poteryat-faily', 'Как не потерять файлы при поломке ноутбука', 'Три простых правила резервного копирования для небольшой компании.', '12 октября 2026'),
         ('sinhronizaciya-1s', 'Синхронизация баз 1С между офисами', 'Разбираем, как настроить ежедневные копии и не мешать бухгалтерии.', '24 октября 2026'),
         ('rabota-pri-plohom-internete', 'Работа при плохом мобильном интернете', 'Почему докачка важнее скорости и как CoreNet переживает обрывы связи.', '3 ноября 2026')]
lorem = 'Когда команда растёт, документы начинают жить в мессенджерах, на флешках и в почте. Найти последнюю версию сметы становится отдельной задачей. Мы собрали практики, которые помогают нашим клиентам. Главное — одна папка на проект, понятные права доступа и автоматические копии. '
for i, (slug, t, d, dt) in enumerate(posts):
    page(f'blog/{slug}.html', f'{t} — Блог CoreNet', f'<section><div class="w" style="max-width:760px"><p class="muted">{dt}</p><h2>{t}</h2><img src="/img/post{i + 1}.jpg" alt="" style="width:100%;border-radius:12px"><p><b>{d}</b></p>' + ''.join(f'<p>{lorem}</p>' for _ in range(4)) + '</div></section>', d)
page('blog/index.html', 'Блог — CoreNet', '<section><div class="w"><h2>Блог</h2><div class="grid">' + ''.join(f'<a class="card" href="/blog/{s}.html" style="color:inherit"><img src="/img/post{i + 1}.jpg" alt="" loading="lazy"><p class="muted">{dt}</p><h3>{t}</h3><p class="muted">{d}</p></a>' for i, (s, t, d, dt) in enumerate(posts)) + '</div></div></section>')
page('login.html', 'Вход — CoreNet', '<form class="login" method="post" action="/login"><h2>Вход в CoreNet</h2><label>Почта</label><input name="email" type="email" required><label>Пароль</label><input name="password" type="password" required><button class="btn" style="width:100%;border:0;font-size:16px">Войти</button><p class="muted" style="text-align:center"><a href="/login">Забыли пароль?</a></p></form>')
page('login-error.html', 'Вход — CoreNet', '<form class="login" method="post" action="/login"><h2>Вход в CoreNet</h2><p style="color:#dc2626">Неверная почта или пароль.</p><label>Почта</label><input name="email" type="email" required><label>Пароль</label><input name="password" type="password" required><button class="btn" style="width:100%;border:0;font-size:16px">Войти</button></form>')
page('404.html', 'Страница не найдена — CoreNet', '<section><div class="w"><h2>Страница не найдена</h2><p>Возможно, ссылка устарела. <a href="/">На главную</a></p></div></section>')
open(f'{out}/robots.txt', 'w').write(f'User-agent: *\nDisallow: /login\nSitemap: https://{domain}/sitemap.xml\n')
urls = ['', 'features.html', 'pricing.html', 'video.html', 'about.html', 'blog/'] + [f'blog/{p[0]}.html' for p in posts]
open(f'{out}/sitemap.xml', 'w').write('<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + ''.join(f'<url><loc>https://{domain}/{u}</loc></url>' for u in urls) + '</urlset>')
PY

rm -rf "$WEB.new"; mv "$TMP/site" "$WEB.new"; chmod -R a+rX "$WEB.new"
rm -rf "$WEB.old"; [[ -d "$WEB" ]] && mv "$WEB" "$WEB.old"; mv "$WEB.new" "$WEB"; rm -rf "$WEB.old"
du -sh "$WEB" | cut -f1; ls "$WEB" "$WEB/media"
