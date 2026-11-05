#!/usr/bin/env python3
"""selfIE 的 tag 門檻評估：用 Open Images V7（Google 公開資料集，有人工確認的照片標籤）幫每個 tag 找門檻。

App 判斷一張照片是不是某個 tag：照片向量和這個 tag 每條提示詞（"a photo of …"）的相似度取最高分，
分數 ≥ 門檻（目前全部共用 0.25）就標上。不同 tag 的分數分布差很多，所以要各自量一次。

    python3 tag_threshold_eval.py check            下載標籤清單（一兩百 MB，不含照片），看每個 tag 在 Open Images 有沒有對應、有幾張照片
    python3 tag_threshold_eval.py run              下載照片、算向量、找出每個 tag 的建議門檻，輸出報表
    python3 tag_threshold_eval.py labels           下載照片、算向量，輸出成「協助訓練分類」的標記檔（公開資料集_OpenImages.json），
                                                   放進桌面的 selfIE標記資料 資料夾，給 train_tag_classifiers.py 一起訓練判斷器
    python3 tag_threshold_eval.py folder-labels ~/Desktop/相簿主題設定 "~/Desktop/相簿主題設定 2"
                                                   「相簿主題設定」資料夾裡你放的照片 → 標記檔（selfIE標記_相簿主題設定照片.json），
                                                   照片在哪個小分類資料夾就算那個分類的「是」，給 train_tag_classifiers.py 一起訓練
    python3 tag_threshold_eval.py run --write-folder ~/Desktop/相簿主題設定
                                                   另外把建議門檻寫進「相簿主題設定」資料夾，
                                                   再執行 taxonomy_folder.py apply 套用到 App

自己收集的照片：放進「相簿主題設定」資料夾裡那個小分類的資料夾（和 設定.json 放在一起），
執行 run 時加上 --local-folder ~/Desktop/相簿主題設定，就會當成那個 tag 的正確答案一起評估。
Open Images 沒有的 tag（截圖、小卡、手搖飲…）只能靠這種方式。

需求（在 Mac 上執行；照片向量用 App 內附的同一個模型，需要 macOS 才能跑 Core ML）：
    pip3 install numpy pillow coremltools
    pip3 install pillow-heif     （選用：自己收集的照片是 HEIC 時）

輸出（預設在 ~/selfIE_tag_eval/）：
    tag_coverage.md         每個 tag 在 Open Images 的對應與照片數，以及沒有對應、要自己收集照片的 tag
    tag_report.md / .csv    每個 tag 的建議門檻、在目前門檻下的準確率與漏抓率
    suggested_thresholds.json

只讀取：App 的分類目錄與模型、PhotoAI.sqlite（預先算好的分類文字向量）、你放進資料夾的照片。
只寫入：輸出資料夾；加上 --write-folder 時才改「相簿主題設定」資料夾裡各小分類設定.json 的「門檻」欄位。
labels 另外只寫入一個標記檔：桌面 selfIE標記資料／公開資料集_OpenImages.json（只有向量和答案，不含照片）。
不會碰手機、相簿或 App 的資料庫。
"""
import argparse
import csv
import json
import os
import random
import sqlite3
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import taxonomy_folder as tf  # noqa: E402  分類目錄解析（和「相簿主題設定」同一套）

IOS_APP = SCRIPT_DIR.parent.parent
APP_DIR = IOS_APP / "MobileCLIPExplore"
IMAGE_MODEL = APP_DIR / "Models" / "mobileclip_s2_image.mlpackage"
TEXT_MODEL = APP_DIR / "Models" / "mobileclip_s2_text.mlpackage"
APP_DB = APP_DIR / "SQLite" / "PhotoAI.sqlite"
TOKENIZER_DIR = APP_DIR / "Resources"
MAP_FILE = SCRIPT_DIR / "openimages_tag_map.json"

OI = "https://storage.googleapis.com/openimages/v7/"
CLASS_CSV = OI + "oidv7-class-descriptions.csv"
LABEL_CSV = {
    "validation": OI + "oidv7-val-annotations-human-imagelabels.csv",
    "test": OI + "oidv7-test-annotations-human-imagelabels.csv",
}
# 和官方 downloader.py 同一個公開儲存空間（open-images-dataset/<split>/<id>.jpg）
IMAGE_URL = "https://open-images-dataset.s3.amazonaws.com/{split}/{image_id}.jpg"
# 物件框（用來數照片裡有幾張臉：雙人合照、多人合照）
BBOX_CSV = {
    "validation": "https://storage.googleapis.com/openimages/v5/validation-annotations-bbox.csv",
    "test": "https://storage.googleapis.com/openimages/v5/test-annotations-bbox.csv",
}

# 用人臉框推出來的標籤（Open Images 沒有「兩個人合照」這種類別，但每張臉都有框）
# 寫在對應表裡，和一般的類別名稱一樣使用
DERIVED_FACES = {
    "@兩張臉": "兩個人的合照（照片裡剛好兩張清楚的臉）",
    "@三張以上的臉": "三人以上的合照（3～20 張清楚的臉）",
}
FACE_MAIN = 0.06    # 臉的寬度佔照片 6% 以上：照片的主角
FACE_SMALL = 0.03   # 小於 3%：背景路人，不算

PROMPT_TEMPLATE = "a photo of "
IMAGE_SIZE = 256
LOCAL_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp"}

# ───────────────────────── tag ↔ Open Images 類別 ─────────────────────────
# 值是 Open Images 的類別名稱（DisplayName，不分大小寫）。找不到的名稱會在 check 時列出，並建議相近的名稱。
# 第一次執行會把這份對應寫成 openimages_tag_map.json，之後改那個檔案就好（不用改程式）。
# 空清單 = Open Images 沒有合適的類別（例如截圖、小卡），要自己收集照片。
DEFAULT_MAP = {
    "restaurant_meal": ["Meal", "Dish", "Cuisine"],
    "noodle_dish": ["Noodle", "Ramen", "Noodle soup", "Udon", "Spaghetti"],
    "bento": ["Bento", "Rice", "Steamed rice", "Fried rice"],
    "sushi": ["Sushi", "Sashimi"],
    "bbq": ["Barbecue", "Grilling", "Steak", "Barbecue grill"],
    "pizza_burger": ["Pizza", "Hamburger"],
    "fried_chicken": ["Fried chicken", "Fried food", "Deep frying", "French fries"],
    "hotpot": ["Hot pot"],
    "menu": ["Menu"],
    "night_market": ["Street food", "Flea market"],
    "cake": ["Cake", "Birthday cake", "Cheesecake"],
    "ice_cream": ["Ice cream", "Frozen dessert", "Ice pop"],
    "bakery": ["Bakery", "Bread", "Pastry", "Baked goods", "Croissant"],
    "coffee": ["Coffee cup", "Latte", "Cappuccino", "Iced coffee"],
    "bubble_tea": [],
    "cocktail": ["Cocktail", "Wine", "Wine glass", "Alcoholic beverage"],
    "cafe": ["Coffeehouse"],
    "cat": ["Cat"],
    "dog": ["Dog"],
    "rabbit": ["Rabbit", "Domestic rabbit"],
    "small_pet": ["Hamster", "Guinea pig", "Rodent", "Gerbil"],
    "reptile": ["Reptile", "Lizard", "Turtle", "Tortoise", "Snake", "Frog"],
    "bird": ["Bird"],
    "aquarium": ["Aquarium", "Fish"],
    "zoo_animal": ["Zoo"],
    "farm_animal": ["Livestock", "Sheep", "Cattle", "Goat", "Pig", "Horse"],
    "sunset": ["Sunset", "Sunrise"],
    "starry_sky": ["Star", "Milky Way", "Astronomical object"],
    "beach": ["Beach"],
    "mountain": ["Mountain", "Mountain range"],
    "forest": ["Forest", "Woodland"],
    "lake_river": ["Lake", "River"],
    "flowers": ["Flower", "Bouquet", "Flower Arranging", "Cherry blossom"],
    "autumn_leaves": ["Autumn", "Maple leaf"],
    "snow": ["Snow"],
    # v17：自拍改用系統「自拍」相簿（不評估）；單人、雙人、多人合照合併成「人物照」
    "portrait": ["Portrait", "Portrait photography", "Selfie", "Friendship", "Social group"],
    "baby": ["Baby"],
    "party": ["Birthday", "Birthday cake"],
    "home_daily": ["Living room", "Room"],
    "landmark": ["Landmark", "Tourist attraction"],
    "temple": ["Temple", "Shrine", "Shinto shrine"],
    "castle": ["Castle"],
    "city_street": ["Street", "Road"],
    "night_view": ["Night", "Cityscape", "Skyline"],
    "architecture": ["Architecture", "Building", "Facade"],
    "transport_vehicle": ["Train", "Airplane", "Bus", "Rolling stock"],
    "airport": ["Airport", "Airport terminal"],
    "hotel_room": ["Hotel", "Bedroom", "Suite"],
    "boarding_pass": ["Boarding pass", "Airline ticket"],
    "movie": ["Movie theater", "Movie palace"],
    "poster": ["Poster"],
    "exhibition": ["Exhibition", "Science fair"],
    "museum": ["Museum", "Art gallery", "Art exhibition"],
    "theater_show": ["Theatre", "Musical theatre", "Performing arts"],
    "books": ["Book", "Bookcase", "Library"],
    # v25：音樂祭、Live House 併入演唱會
    "concert": ["Concert", "Rock concert", "Music venue", "Nightclub"],
    "instrument": ["Musical instrument", "Guitar", "Piano"],
    "cheering_goods": [],
    "tv_screen": [],
    "manga": ["Comics", "Manga", "Comic book"],
    "anime_art": ["Anime", "Cartoon"],
    "video_game": ["Video game", "PC game"],
    "board_game": ["Board game", "Tabletop game"],
    "arcade": ["Arcade game"],
    "cosplay": ["Cosplay"],
    "comic_convention": ["Convention"],
    # v21：小卡、卡冊、壓克力立牌、徽章、吊飾合併成「周邊小物」
    "merch": ["Badge", "Pin", "Keychain"],
    "figure": ["Figurine", "Action figure"],
    "stuffed_toy": ["Stuffed toy", "Teddy bear", "Plush", "Doll"],
    "model_kit": ["Scale model", "Model"],
    "lego": ["Lego"],
    "photo_sticker": [],
    "stationery": ["Stationery", "Pen", "Notebook"],
    "journal": [],
    "handcraft": ["Craft"],
    "painting": ["Painting", "Drawing"],
    "gadgets": ["Laptop", "Mobile phone", "Gadget", "Tablet computer"],
    "camera_gear": ["Camera", "Camera lens", "Digital camera"],
    "theme_park": ["Amusement park", "Roller coaster", "Amusement ride"],
    "fireworks": ["Fireworks"],
    "lantern_festival": ["Lantern", "Festival"],
    "christmas": ["Christmas", "Christmas tree", "Christmas decoration"],
    "workout": ["Physical fitness", "Exercise", "Gym"],
    "weight_training": ["Weight training", "Dumbbell", "Barbell"],
    "cardio_machine": ["Treadmill", "Stationary bicycle", "Exercise machine"],
    "running": ["Running", "Marathon", "Jogging"],
    "ball_sports": ["Badminton", "Ball game", "Basketball hoop", "Volleyball (ball)", "Beach volleyball"],
    "swimming": ["Swimming", "Swimming pool"],
    "cycling": ["Cycling", "Bicycle"],
    "sports_game": ["Stadium", "Baseball park", "Baseball field"],
    "sports_gear": ["Sports equipment", "Racket"],
    "hiking": ["Hiking"],
    "camping": ["Camping", "Tent"],
    "skiing": ["Skiing", "Ski"],
    "diving": ["Snorkeling", "Underwater diving", "Scuba diving"],
    "outfit": ["Fashion"],
    "shoes": ["Footwear", "Shoe", "Sneakers"],
    "bags": ["Handbag", "Bag"],
    "accessories": ["Jewellery", "Fashion accessory", "Necklace"],
    "cosmetics": ["Cosmetics", "Lipstick"],
    "nails": ["Manicure", "Nail polish", "Nail care"],
    "hairstyle": ["Hairstyle"],
    "document": ["Document", "Paper"],
    "handwritten_notes": ["Handwriting", "Whiteboard"],
    "slides": ["Presentation"],
    "textbook": [],
    "id_card": ["Identity document", "Debit card"],
    "chat_screenshot": [],
    "desk_setup": ["Desk", "Computer desk"],
    "receipt": ["Receipt"],
    "product_photo": [],
    "clothing": ["Clothing", "Boutique", "Clothes hanger"],
    "groceries": ["Grocery store", "Supermarket", "Produce"],
    "furniture": ["Furniture"],
    "houseplants": ["Houseplant", "Flowerpot"],
}

# 為什麼沒有對應（給報表說明）
NO_MATCH_REASON = {
    "cheering_goods": "沒有「應援手燈」類別",
    "tv_screen": "沒有「翻拍螢幕」類別",
    "chat_screenshot": "沒有聊天截圖",
    "product_photo": "「商品照」太廣，沒有對應的單一類別",
    "bubble_tea": "Open Images 只有一般的「茶」，沒有手搖飲",
    "journal": "手帳照片太少（只有 4 張）",
    "textbook": "沒有「課本」類別",
    "photo_sticker": "沒有拍貼（明信片只有 10 張）",
}


# ───────────────────────── 下載 ─────────────────────────

def download(url, path, quiet=False):
    path = Path(path)
    if path.exists() and path.stat().st_size > 0:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".part")
    if not quiet:
        print(f"下載 {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "selfIE-tag-eval"})
    with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    tmp.rename(path)
    return path


def load_classes(cache):
    """DisplayName（小寫）→ [MID]；以及 MID → DisplayName"""
    path = download(CLASS_CSV, cache / "oidv7-class-descriptions.csv")
    by_name, names = {}, {}
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            by_name.setdefault(row["DisplayName"].strip().lower(), []).append(row["LabelName"])
            names[row["LabelName"]] = row["DisplayName"]
    for token, label in DERIVED_FACES.items():
        by_name[token.lower()] = [token]
        names[token] = label
    return by_name, names


def suggest_names(name, by_name, limit=4):
    """找不到的類別名稱：列出含有同樣單字的類別，方便改對應表"""
    words = [w for w in name.lower().replace("-", " ").split() if len(w) >= 3]
    hits = []
    for display in by_name:
        if any(w in display.split() for w in words):
            hits.append(display)
    hits.sort(key=lambda d: (len(d), d))
    return hits[:limit]


def face_labels(cache, splits, face_mids):
    """用人臉框推出「雙人合照」「多人合照」：(split, image_id) → {"@兩張臉": 1/0, "@三張以上的臉": 1/0}
    - 主角的臉（寬度 ≥ 6%）剛好 2 張 → 兩張臉＝是；1 張或 3 張以上 → 不是
    - 主角的臉 3～20 張 → 三張以上＝是；1、2 張 → 不是
    - 有一群人的框（IsGroupOf）、或有中等大小、分不出是不是主角的臉：不標（不確定）
    - 畫的臉（IsDepiction，例如海報、雕像）不算"""
    faces = {}
    for split in splits:
        path = download(BBOX_CSV[split], cache / Path(BBOX_CSV[split]).name)
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                if row["LabelName"] not in face_mids:
                    continue
                stat = faces.setdefault((split, row["ImageID"]), {"main": 0, "medium": 0, "crowd": False})
                if row.get("IsDepiction") == "1":
                    continue
                if row.get("IsGroupOf") == "1":
                    stat["crowd"] = True
                    continue
                width = float(row["XMax"]) - float(row["XMin"])
                if width >= FACE_MAIN:
                    stat["main"] += 1
                elif width >= FACE_SMALL:
                    stat["medium"] += 1
    out = {}
    for key, stat in faces.items():
        if stat["crowd"] or stat["medium"] or stat["main"] == 0:
            continue
        n = stat["main"]
        out[key] = {"@兩張臉": 1 if n == 2 else 0, "@三張以上的臉": 1 if 3 <= n <= 20 else 0}
    return out


def load_labels(cache, splits, mids_of_interest, by_name=None):
    """人工確認的照片標籤：(split, image_id) → {MID: 1 或 0}（只留需要的 MID），以及所有照片清單"""
    labels, all_images = {}, set()
    for split in splits:
        path = download(LABEL_CSV[split], cache / Path(LABEL_CSV[split]).name)
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                key = (split, row["ImageID"])
                all_images.add(key)
                mid = row["LabelName"]
                if mid in mids_of_interest:
                    labels.setdefault(key, {})[mid] = 1 if float(row["Confidence"]) >= 0.5 else 0
    derived = [t for t in DERIVED_FACES if t in mids_of_interest]
    if derived and by_name:
        face_mids = set(by_name.get("human face", []))
        if face_mids:
            for key, marks in face_labels(cache, splits, face_mids).items():
                all_images.add(key)
                for token in derived:
                    labels.setdefault(key, {})[token] = marks[token]
        else:
            print("找不到 Human face 類別，略過用人臉數判斷的合照")
    return labels, sorted(all_images)


# ───────────────────────── 分類目錄與對應 ─────────────────────────

def load_nodes():
    """App 實際使用的分類（內建目錄＋已套用的主題設定調整）"""
    _, nodes = tf.parse_catalog()
    nodes = tf.effective_nodes(nodes, tf.read_tuning())
    defaults = tf.effective_thresholds(tf.parse_threshold_defaults(), tf.read_tuning())
    by_id = {n["id"]: n for n in nodes}
    return nodes, by_id, defaults


def node_path_text(node, by_id):
    trail, cur = [], node
    while cur["parentId"]:
        cur = by_id[cur["parentId"]]
        trail.insert(0, cur["nameZh"])
    return " › ".join(trail + [node["nameZh"]])


def load_map():
    if MAP_FILE.exists():
        data = json.loads(MAP_FILE.read_text(encoding="utf-8"))
        return {k: v for k, v in data.items() if not k.startswith("_")}
    doc = {"_說明": "tag id → Open Images 類別名稱（DisplayName）。空清單代表 Open Images 沒有，要自己收集照片。改完重新執行即可。"}
    doc.update(DEFAULT_MAP)
    MAP_FILE.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已建立對應表：{MAP_FILE}")
    return dict(DEFAULT_MAP)


def scorable(node):
    return node["level"] == 3 and node["recognition"] in ("visual", "assisted") and node["prompts"]


def resolve_map(nodes, mapping, by_name):
    """每個 tag 的 MID，以及找不到的類別名稱"""
    resolved, missing = {}, {}
    for n in nodes:
        if not scorable(n):
            continue
        mids = []
        for name in mapping.get(n["id"], []):
            found = by_name.get(name.strip().lower())
            if found:
                mids += found
            else:
                missing.setdefault(n["id"], []).append(name)
        resolved[n["id"]] = sorted(set(mids))
    return resolved, missing


def counts_for(mids, labels):
    pos = neg = 0
    for marks in labels.values():
        values = [marks[m] for m in mids if m in marks]
        if not values:
            continue
        if any(values):
            pos += 1
        else:
            neg += 1
    return pos, neg


# ───────────────────────── check ─────────────────────────

def cmd_check(args):
    cache = Path(args.cache).expanduser()
    out = Path(args.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    nodes, by_id, defaults = load_nodes()
    mapping = load_map()
    by_name, names = load_classes(cache)
    resolved, missing = resolve_map(nodes, mapping, by_name)
    wanted = {m for mids in resolved.values() for m in mids}
    labels, _ = load_labels(cache, args.splits, wanted, by_name)
    local = scan_local(args.local_folder) if args.local_folder else {}

    rows = []
    for n in nodes:
        if not scorable(n):
            continue
        mids = resolved.get(n["id"], [])
        pos, neg = counts_for(mids, labels) if mids else (0, 0)
        mine = len(local.get(n["id"], []))
        if pos >= args.min_positives:
            status = "可以評估"
        elif pos + mine >= args.min_positives:
            status = "可以評估（含你的照片）"
        elif mids:
            status = "照片太少，要補"
        elif mapping.get(n["id"]):
            status = "對應的類別名稱找不到"
        else:
            status = "Open Images 沒有，要自己收集"
        rows.append(dict(id=n["id"], path=node_path_text(n, by_id), labels=[names[m] for m in mids],
                         missing=missing.get(n["id"], []), pos=pos, neg=neg, mine=mine, status=status))

    lines = ["# tag 在 Open Images 的對應", "",
             f"人工確認標籤：{'、'.join(args.splits)}；至少要 {args.min_positives} 張正確答案才評估。", ""]
    need = [r for r in rows if r["status"] in ("Open Images 沒有，要自己收集", "照片太少，要補", "對應的類別名稱找不到")]
    if need:
        lines += ["## 要自己收集照片的 tag", "",
                  f"把照片放進「相簿主題設定」資料夾裡那個小分類的資料夾（每個至少 {args.min_positives} 張，"
                  "越像你平常拍的越好），再用 --local-folder 執行。", "",
                  "| tag | 位置 | 原因 | Open Images 張數 | 你的照片 |", "|---|---|---|---|---|"]
        for r in need:
            reason = NO_MATCH_REASON.get(r["id"]) or ("對應的類別名稱都找不到（見最下面的建議，改對應表後再跑一次）"
                                                      if r["missing"] and not r["labels"] else
                                                      "Open Images 照片太少" if r["labels"] else "沒有設定對應")
            lines.append(f"| {r['id']} | {r['path']} | {reason} | {r['pos']} | {r['mine']} |")
        lines.append("")
    lines += ["## 全部 tag", "", "| tag | 位置 | Open Images 類別 | 正確 | 確認不是 | 你的照片 | 狀態 |",
              "|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['id']} | {r['path']} | {'、'.join(r['labels']) or '—'} | {r['pos']} | {r['neg']} | "
                     f"{r['mine']} | {r['status']} |")
    if missing:
        lines += ["", "## 對應表裡找不到的類別名稱", "",
                  f"改 {MAP_FILE.name}：換成右邊建議的名稱，或刪掉。", ""]
        for nid, bad in missing.items():
            for name in bad:
                hint = "、".join(suggest_names(name, by_name)) or "（沒有相近的）"
                lines.append(f"- {nid}：「{name}」→ 相近：{hint}")
    (out / "tag_coverage.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    ok = sum(r["status"].startswith("可以評估") for r in rows)
    print(f"\n{len(rows)} 個 tag：{ok} 個可以評估、{len(need)} 個要自己收集或補照片")
    for r in need:
        print(f"  - {r['path']}（{r['id']}）：{r['status']}")
    print(f"\n報表：{out / 'tag_coverage.md'}")
    return 0


# ───────────────────────── 自己收集的照片 ─────────────────────────

def scan_local(folder):
    """「相簿主題設定」資料夾：每個小分類資料夾裡的照片 → tag id"""
    folder = Path(folder).expanduser()
    result = {}
    for nid, settings in tf._scan_ids(folder).items():
        if settings.name != "設定.json":
            continue
        photos = [p for p in sorted(settings.parent.iterdir())
                  if p.is_file() and p.suffix.lower() in LOCAL_EXTS and not p.name.startswith(".")]
        if photos:
            result[nid] = photos
    return result


# ───────────────────────── 向量 ─────────────────────────

def center_square(img, size=IMAGE_SIZE):
    """和 App 一樣：等比例縮放填滿正方形，裁掉多出來的部分（aspectFill）"""
    from PIL import Image, ImageOps
    img = ImageOps.exif_transpose(img).convert("RGB")
    w, h = img.size
    scale = size / min(w, h)
    img = img.resize((max(size, round(w * scale)), max(size, round(h * scale))), Image.BICUBIC)
    w, h = img.size
    left, top = (w - size) // 2, (h - size) // 2
    return img.crop((left, top, left + size, top + size))


def normalize(v):
    v = np.asarray(v, dtype=np.float32).reshape(-1)
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def load_mlmodel(ct, path):
    """載入 Core ML 模型；coremltools 不支援這個 Python 版本時，說明怎麼換"""
    try:
        return ct.models.MLModel(str(path))
    except Exception as e:
        v = sys.version_info
        sys.exit(f"\n載入模型失敗：{e}\n"
                 f"目前是 Python {v.major}.{v.minor}。coremltools 只支援到 Python 3.12，請用 3.12 或 3.11 建立虛擬環境：\n"
                 "  brew install python@3.12\n"
                 "  python3.12 -m venv .venv312 && source .venv312/bin/activate\n"
                 "  pip install numpy pillow coremltools\n"
                 "  python tag_threshold_eval.py run --local-folder ~/Desktop/相簿主題設定\n")


class ImageEncoder:
    """App 內附的 mobileclip_s2_image.mlpackage（需要 macOS）"""

    def __init__(self):
        try:
            import coremltools as ct
        except ImportError:
            sys.exit("需要 coremltools：pip3 install coremltools（而且要在 Mac 上執行）")
        if sys.platform != "darwin":
            sys.exit("照片向量要用 Core ML 計算，只能在 Mac 上執行。")
        self.model = load_mlmodel(ct, IMAGE_MODEL)

    def __call__(self, path):
        with open_image(path) as img:
            square = center_square(img)
        out = self.model.predict({"image": square})
        return normalize(out["final_emb_1"])


def open_image(path):
    """打開照片。HEIC（iPhone 預設格式）：有裝 pillow-heif 就直接讀，
    沒有就用 Mac 內建的 sips 轉成 JPEG 暫存檔再讀（不會改到原本的照片）"""
    from PIL import Image
    path = Path(path)
    if path.suffix.lower() in (".heic", ".heif"):
        try:
            import pillow_heif
            pillow_heif.register_heif_opener()
            return Image.open(path)
        except ImportError:
            pass
        import subprocess
        import tempfile
        tmp = Path(tempfile.gettempdir()) / f"selfie_eval_{abs(hash(str(path)))}.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", str(path), "--out", str(tmp)],
                       check=True, capture_output=True)
        img = Image.open(tmp)
        img.load()
        tmp.unlink(missing_ok=True)
        return img
    return Image.open(path)


class EmbeddingCache:
    def __init__(self, path):
        self.path = Path(path)
        self.data = {}
        if self.path.exists():
            with np.load(self.path) as z:
                self.data = {k: z[k] for k in z.files}
        self.dirty = 0

    def get(self, key):
        return self.data.get(key)

    def put(self, key, vec):
        self.data[key] = vec
        self.dirty += 1
        if self.dirty >= 200:
            self.save()

    def save(self):
        if self.dirty:
            tmp = self.path.with_suffix(".tmp.npz")
            np.savez(tmp, **self.data)
            tmp.replace(self.path)
            self.dirty = 0


def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, [chr(c) for c in cs]))


class Tokenizer:
    """App 的 CLIPTokenizer.swift（和 precompute_prompt_embeddings.py 相同）"""

    def __init__(self):
        import re
        lines = [l for l in (TOKENIZER_DIR / "clip-merges.txt").read_text(encoding="utf-8").split("\n") if l != ""]
        self.ranks = {tuple(lines[i].split(" ")): i - 1 for i in range(1, len(lines))}
        self.encoder = json.loads((TOKENIZER_DIR / "clip-vocab.json").read_text(encoding="utf-8"))
        self.byte_encoder = bytes_to_unicode()
        self.pat = re.compile(r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[^\W\d_]+|\d|[^\s\w]+|_+")

    def bpe(self, token):
        if len(token) <= 1:
            return token + "</w>"
        word = list(token[:-1]) + [token[-1] + "</w>"]
        while True:
            pairs = {(word[i], word[i + 1]) for i in range(len(word) - 1)}
            cand = [p for p in pairs if p in self.ranks]
            if not cand:
                break
            first, second = min(cand, key=lambda p: self.ranks[p])
            new, i = [], 0
            while i < len(word):
                try:
                    j = word.index(first, i)
                    new.extend(word[i:j])
                    i = j
                except ValueError:
                    new.extend(word[i:])
                    break
                if word[i] == first and i < len(word) - 1 and word[i + 1] == second:
                    new.append(first + second)
                    i += 2
                else:
                    new.append(word[i])
                    i += 1
            word = new
            if len(word) == 1:
                break
        return " ".join(word)

    def encode_full(self, text):
        ids = []
        for tok in self.pat.findall(text.lower()):
            enc = "".join(self.byte_encoder[b] for b in tok.encode("utf-8"))
            ids += [self.encoder[t] for t in self.bpe(enc).split(" ") if t in self.encoder]
        ids = ids[:75]
        full = [0] * 77
        full[0] = self.encoder["<|startoftext|>"]
        full[1:1 + len(ids)] = ids
        full[len(ids) + 1] = self.encoder["<|endoftext|>"]
        return full


def prompt_vectors(nodes):
    """分類提示詞的文字向量：先用 PhotoAI.sqlite 預先算好的（和 App 相同），沒有的再用文字模型算"""
    prompts = sorted({p.strip() for n in nodes if scorable(n) for p in n["prompts"]})
    vectors = {}
    if APP_DB.exists():
        con = sqlite3.connect(f"file:{APP_DB}?mode=ro", uri=True)
        try:
            for prompt, blob in con.execute(
                    "SELECT prompt, embedding FROM PrecomputedPromptEmbeddings WHERE template = 'a photo of'"):
                vectors[prompt.strip()] = normalize(np.frombuffer(blob, dtype="<f4"))
        except sqlite3.Error:
            pass
        con.close()
    todo = [p for p in prompts if p not in vectors]
    if todo:
        print(f"PhotoAI.sqlite 沒有 {len(todo)} 條提示詞的向量，用文字模型計算…")
        try:
            import coremltools as ct
        except ImportError:
            sys.exit("需要 coremltools：pip3 install coremltools")
        model = load_mlmodel(ct, TEXT_MODEL)
        tok = Tokenizer()
        for p in todo:
            tokens = np.array(tok.encode_full(PROMPT_TEMPLATE + p), dtype=np.int32).reshape(1, 77)
            vectors[p] = normalize(model.predict({"text": tokens})["final_emb_1"])
    return {p: vectors[p] for p in prompts}


def node_scores(image_matrix, nodes, vectors):
    """每張照片 × 每個 tag 的分數（和 App 相同：所有提示詞取最高分）"""
    scores = {}
    for n in nodes:
        if not scorable(n):
            continue
        rows = np.stack([vectors[p.strip()] for p in n["prompts"]])
        scores[n["id"]] = (image_matrix @ rows.T).max(axis=1)
    return scores


# ───────────────────────── 門檻 ─────────────────────────

def sweep(pos_scores, neg_scores, prevalence, grid):
    """每個門檻的抓到率（recall）、誤判率（FPR），以及依實際比例換算的準確率（precision）"""
    pos = np.asarray(pos_scores)
    neg = np.asarray(neg_scores)
    out = []
    for t in grid:
        tpr = float((pos >= t).mean()) if len(pos) else 0.0
        fpr = float((neg >= t).mean()) if len(neg) else 0.0
        hit = prevalence * tpr
        false = (1 - prevalence) * fpr
        precision = hit / (hit + false) if hit + false > 0 else 0.0   # 一張都沒標上：不算準
        out.append((float(t), tpr, fpr, precision))
    return out


def average_precision(pos_scores, neg_scores, prevalence):
    """依實際比例加權的 AP：0～1，越高代表這個 tag 分得越開"""
    pos = np.sort(np.asarray(pos_scores))[::-1]
    neg = np.asarray(neg_scores)
    if not len(pos) or not len(neg):
        return float("nan")
    ap = 0.0
    for k, t in enumerate(pos, 1):
        tpr = k / len(pos)
        fpr = float((neg >= t).mean())
        hit = prevalence * tpr
        precision = hit / (hit + (1 - prevalence) * fpr)
        ap += precision / len(pos)
    return ap


MIN_RECALL = 0.2   # 抓到率太低（正確的照片 5 張只標到不到 1 張）就算準也沒有用


def choose_threshold(rows, target_precision, lo, hi):
    """達到目標準確率、而且至少抓到兩成的最低門檻（抓得最多）；達不到時取準確率最高的門檻"""
    ok = [r for r in rows if r[3] >= target_precision and r[1] >= MIN_RECALL and lo <= r[0] <= hi]
    if ok:
        best = min(ok, key=lambda r: r[0])
        return best, True
    inside = [r for r in rows if lo <= r[0] <= hi and r[1] > 0] or [r for r in rows if lo <= r[0] <= hi]
    best = max(inside, key=lambda r: (r[3], -r[0]))
    return best, False


def at(rows, t):
    return min(rows, key=lambda r: abs(r[0] - t))


# ───────────────────────── run ─────────────────────────

def cmd_run(args):
    cache = Path(args.cache).expanduser()
    out = Path(args.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)

    nodes, by_id, defaults = load_nodes()
    mapping = load_map()
    by_name, names = load_classes(cache)
    resolved, missing = resolve_map(nodes, mapping, by_name)
    wanted = {m for mids in resolved.values() for m in mids}
    labels, all_images = load_labels(cache, args.splits, wanted, by_name)
    local = scan_local(args.local_folder) if args.local_folder else {}

    # 1. 要下載的照片：每個 tag 的正確答案、確認不是的照片，加上隨機的其他照片
    pool = set()
    for nid, mids in resolved.items():
        pos = [k for k, v in labels.items() if any(v.get(m) == 1 for m in mids)]
        pos_set = set(pos)
        neg = [k for k, v in labels.items() if k not in pos_set and any(m in v for m in mids)]
        pool.update(rng.sample(pos, min(len(pos), args.per_tag)))
        pool.update(rng.sample(neg, min(len(neg), args.per_tag // 2)))
    pool.update(rng.sample(all_images, min(len(all_images), args.background)))
    pool = sorted(pool)
    if args.max_images and len(pool) > args.max_images:
        pool = sorted(rng.sample(pool, args.max_images))
    print(f"Open Images 照片：{len(pool)} 張；你的照片：{sum(len(v) for v in local.values())} 張")

    image_dir = cache / "images"

    def fetch(key):
        split, image_id = key
        path = image_dir / split / f"{image_id}.jpg"
        try:
            download(IMAGE_URL.format(split=split, image_id=image_id), path, quiet=True)
            return key, path
        except Exception:
            return key, None

    todo = [k for k in pool if not (image_dir / k[0] / f"{k[1]}.jpg").exists()]
    if todo:
        print(f"下載 {len(todo)} 張照片…")
    paths, failed = {}, 0
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        for i, (key, path) in enumerate(ex.map(fetch, pool), 1):
            if path:
                paths[key] = path
            else:
                failed += 1
            if i % 500 == 0:
                print(f"  {i}/{len(pool)}")
    if failed:
        print(f"有 {failed} 張下載失敗（略過）")

    # 2. 照片向量（存在快取，下次不用重算）
    emb_cache = EmbeddingCache(cache / "image_embeddings.npz")
    encoder = None
    items = [("oi", f"{k[0]}/{k[1]}", p) for k, p in paths.items()]
    for nid, photos in local.items():
        items += [("local", f"{nid}/{p.name}", p) for p in photos]
    keys, vecs = [], []
    start = time.time()
    for i, (kind, key, path) in enumerate(items, 1):
        cache_key = key if kind == "oi" else f"local:{key}:{int(path.stat().st_mtime)}"
        vec = emb_cache.get(cache_key)
        if vec is None:
            if encoder is None:
                encoder = ImageEncoder()
            try:
                vec = encoder(path)
            except Exception as e:
                print(f"  略過 {path.name}：{e}")
                continue
            emb_cache.put(cache_key, vec)
        keys.append((kind, key))
        vecs.append(vec)
        if i % 500 == 0:
            print(f"  向量 {i}/{len(items)}（{time.time() - start:.0f} 秒）")
    emb_cache.save()
    if not vecs:
        sys.exit("沒有任何照片向量，無法評估。")
    matrix = np.stack(vecs)

    # 3. 每張照片 × 每個 tag 的分數
    vectors = prompt_vectors(nodes)
    scores = node_scores(matrix, nodes, vectors)
    index = {k: i for i, k in enumerate(keys)}

    # 4. 每個 tag 找門檻
    grid = np.round(np.arange(0.10, 0.45001, 0.0025), 4)
    results = []
    for n in nodes:
        if not scorable(n):
            continue
        nid = n["id"]
        mids = resolved.get(nid, [])
        s = scores[nid]
        pos_idx, neg_idx = [], []
        for (kind, key), i in index.items():
            if kind == "local":
                owner = key.split("/", 1)[0]
                if owner == nid:
                    pos_idx.append(i)
                elif by_id[owner]["parentId"] != n["parentId"]:
                    neg_idx.append(i)       # 你放在別的中分類的照片：當成「不是」
                continue
            split, image_id = key.split("/", 1)
            marks = labels.get((split, image_id), {})
            values = [marks[m] for m in mids if m in marks]
            if any(values):
                pos_idx.append(i)
            elif values or args.negatives == "all":
                neg_idx.append(i)           # 人工確認不是，或（all）沒有這個標籤的隨機照片
        current = n["acceptScore"] if n.get("acceptScore") is not None else defaults["acceptScore"]
        row = dict(id=nid, path=node_path_text(n, by_id), recognition=n["recognition"],
                   labels="、".join(names[m] for m in mids), pos=len(pos_idx), neg=len(neg_idx),
                   mine=len(local.get(nid, [])), current=current)
        if len(pos_idx) < args.min_positives or len(neg_idx) < args.min_positives:
            row.update(status="資料不夠", suggested=None)
            results.append(row)
            continue
        pos_s, neg_s = s[pos_idx], s[neg_idx]
        rows = sweep(pos_s, neg_s, args.prevalence, grid)
        best, reached = choose_threshold(rows, args.precision, args.min_threshold, args.max_threshold)
        cur = at(rows, current)
        row.update(
            ap=average_precision(pos_s, neg_s, args.prevalence),
            pos_median=float(np.median(pos_s)), neg_p95=float(np.percentile(neg_s, 95)),
            cur_precision=cur[3], cur_recall=cur[1],
            suggested=round(best[0] * 200) / 200, new_precision=best[3], new_recall=best[1],
            status="建議" if reached else "分不好")
        results.append(row)

    write_reports(results, out, args)
    if args.write_folder:
        write_folder(results, Path(args.write_folder).expanduser())
    return 0


# ───────────────────────── labels：輸出成訓練用的標記檔 ─────────────────────────

LABEL_FORMAT = "selfie-labels-1"
PUBLIC_CONTRIBUTOR = "公開資料集：Open Images V7"
DEFAULT_LABEL_DIR = Path.home() / "Desktop" / "selfIE標記資料"


def fetch_open_images(pool, cache, workers):
    """下載 Open Images 照片（已下載的跳過）：(split, image_id) → 檔案路徑"""
    image_dir = cache / "images"

    def fetch(key):
        split, image_id = key
        path = image_dir / split / f"{image_id}.jpg"
        try:
            download(IMAGE_URL.format(split=split, image_id=image_id), path, quiet=True)
            return key, path
        except Exception:
            return key, None

    todo = [k for k in pool if not (image_dir / k[0] / f"{k[1]}.jpg").exists()]
    if todo:
        print(f"下載 {len(todo)} 張照片（已下載的 {len(pool) - len(todo)} 張跳過）…")
    paths, failed = {}, 0
    start = time.time()
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for i, (key, path) in enumerate(ex.map(fetch, pool), 1):
            if path:
                paths[key] = path
            else:
                failed += 1
            if i % 500 == 0:
                print(f"  {i}/{len(pool)}（{time.time() - start:.0f} 秒）")
    if failed:
        print(f"有 {failed} 張下載失敗（略過）")
    return paths


def embed_open_images(paths, cache):
    """照片向量（和 run 共用快取 image_embeddings.npz，算過的不用重算）：(split, image_id) → 向量"""
    emb_cache = EmbeddingCache(cache / "image_embeddings.npz")
    encoder = None
    out = {}
    start = time.time()
    for i, (key, path) in enumerate(sorted(paths.items()), 1):
        cache_key = f"{key[0]}/{key[1]}"
        vec = emb_cache.get(cache_key)
        if vec is None:
            if encoder is None:
                encoder = ImageEncoder()
            try:
                vec = encoder(path)
            except Exception as e:
                print(f"  略過 {path.name}：{e}")
                continue
            emb_cache.put(cache_key, vec)
        out[key] = np.asarray(vec, dtype=np.float32).reshape(-1)
        if i % 500 == 0:
            print(f"  向量 {i}/{len(paths)}（{time.time() - start:.0f} 秒）")
    emb_cache.save()
    return out


def cmd_labels(args):
    """把 Open Images 人工確認過的照片輸出成「協助訓練分類」同格式的標記檔：
    - 是：照片有這個 tag 對應的類別（人工確認）
    - 不是：人工確認「沒有」這個類別的照片——這些多半是 Google 的模型以為有、人工看過說沒有的照片，
      正好是容易搞混的例子（比隨機照片更有用）
    檔案只有照片向量和答案，不含照片。"""
    import base64
    import datetime

    cache = Path(args.cache).expanduser()
    out_dir = Path(args.output_dir).expanduser()
    rng = random.Random(args.seed)

    nodes, by_id, _ = load_nodes()
    version, _ = tf.parse_catalog()
    mapping = load_map()
    by_name, names = load_classes(cache)
    resolved, missing = resolve_map(nodes, mapping, by_name)
    # 用人臉數推出來的標籤（@兩張臉…）只適合評估門檻，不拿來訓練
    resolved = {nid: [m for m in mids if not m.startswith("@")] for nid, mids in resolved.items()}
    if args.only:
        resolved = {nid: mids for nid, mids in resolved.items() if nid in set(args.only)}
    wanted = {m for mids in resolved.values() for m in mids}
    labels, _ = load_labels(cache, args.splits, wanted)
    # 之前跑 run 算過向量的照片優先用（不用重新下載）；--cached-only 只用這些
    cache_path = cache / "image_embeddings.npz"
    cached = set()
    if cache_path.exists():
        with np.load(cache_path) as z:
            cached = {tuple(k.split("/", 1)) for k in z.files if not k.startswith("local:")}
    if args.cached_only:
        labels = {k: v for k, v in labels.items() if k in cached}
        print(f"只用已經算好向量的照片：{len(labels)} 張有需要的標籤")

    def pick(keys, n):
        """先拿算過向量的，不夠再隨機補"""
        have = [k for k in keys if k in cached]
        rest = [k for k in keys if k not in cached]
        chosen = rng.sample(have, min(len(have), n))
        return chosen + rng.sample(rest, min(len(rest), n - len(chosen)))

    plan, too_few = {}, []
    for nid, mids in sorted(resolved.items()):
        if not mids:
            continue
        pos = sorted(k for k, v in labels.items() if any(v.get(m) == 1 for m in mids))
        if len(pos) < args.min_positives:
            too_few.append((nid, len(pos)))
            continue
        pos_set = set(pos)
        neg = sorted(k for k, v in labels.items() if k not in pos_set and any(m in v for m in mids))
        plan[nid] = (pick(pos, args.per_tag), pick(neg, args.per_tag // 2))
    pool = sorted({k for p, n in plan.values() for k in p + n})
    if args.max_images and len(pool) > args.max_images:
        keep = set(rng.sample(pool, args.max_images))
        plan = {nid: ([k for k in p if k in keep], [k for k in n if k in keep]) for nid, (p, n) in plan.items()}
        pool = sorted(keep)
    print(f"\n{len(plan)} 個 tag 有足夠的 Open Images 照片，共 {len(pool)} 張（每張約 0.2～0.4 MB）")
    for nid, count in too_few:
        print(f"  ・{node_path_text(by_id[nid], by_id)}（{nid}）：只有 {count} 張，略過")

    if args.cached_only:
        with np.load(cache_path) as z:
            vectors = {k: np.asarray(z[f"{k[0]}/{k[1]}"], dtype=np.float32).reshape(-1) for k in pool}
    else:
        paths = fetch_open_images(pool, cache, args.workers)
        vectors = embed_open_images(paths, cache)

    items, counts = [], {}
    for nid, (p, n) in plan.items():
        for key, label in [(k, 1) for k in p] + [(k, 0) for k in n]:
            vec = vectors.get(key)
            if vec is None:
                continue
            items.append({"id": f"oi-{key[0]}-{key[1]}", "node": nid, "label": label,
                          "e": base64.b64encode(vec.astype("<f4").tobytes()).decode()})
            c = counts.setdefault(nid, [0, 0])
            c[0 if label else 1] += 1
    if not items:
        sys.exit("沒有任何照片向量，沒有輸出。")
    doc = {"format": LABEL_FORMAT, "contributor": PUBLIC_CONTRIBUTOR, "source": "public-dataset",
           "catalogVersion": version, "dimension": int(len(next(iter(vectors.values())))),
           "exportedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "items": items}
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "公開資料集_OpenImages.json"
    path.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

    print("\n每個 tag 的張數（是／不是）：")
    for nid, (pos, neg) in sorted(counts.items()):
        print(f"  {node_path_text(by_id[nid], by_id)}（{nid}）：{pos}／{neg}")
    print(f"\n✅ 已輸出 {len(items)} 筆到 {path}（{path.stat().st_size / 1e6:.0f} MB）")
    if not args.cached_only:
        print(f"下載的照片在 {cache / 'images'}，訓練完可以刪掉（之後要重跑會再下載）。")
    print("下一步：python3 train_tag_classifiers.py")
    return 0


# ───────────────────────── 報表 ─────────────────────────

def pct(v):
    return "—" if v is None or v != v else f"{v * 100:.0f}%"


def write_reports(results, out, args):
    fields = ["id", "path", "recognition", "labels", "pos", "neg", "mine", "current", "cur_precision",
              "cur_recall", "suggested", "new_precision", "new_recall", "ap", "pos_median", "neg_p95", "status"]
    with open(out / "tag_report.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in results:
            w.writerow(r)

    suggested = {r["id"]: r["suggested"] for r in results if r["status"] == "建議"}
    (out / "suggested_thresholds.json").write_text(json.dumps(suggested, ensure_ascii=False, indent=2) + "\n",
                                                    encoding="utf-8")

    lines = ["# tag 門檻評估", "",
             f"- 目標準確率：{args.precision:.0%}（標上的照片裡，真的是這個 tag 的比例）",
             f"- 假設一般相簿裡約 {args.prevalence:.0%} 的照片屬於某一個 tag（用來換算準確率；Open Images 的照片比例和你的相簿不同）",
             f"- 門檻範圍：{args.min_threshold}～{args.max_threshold}；分數＝照片和提示詞的相似度（所有提示詞取最高）",
             "- 「抓到率」：真的是這個 tag 的照片，有多少會被標上。",
             "- App 還有其他規則（每張最多 3 個、要接近這張照片的最高分、容易誤認的畫面會排除），實際標上的會再少一些。",
             ""]
    bad = [r for r in results if r["status"] == "分不好"]
    if bad:
        lines += ["## 分不好的 tag（調門檻也達不到目標，要改提示詞或名稱）", "",
                  "| tag | 位置 | 正確照片的中位分數 | 不是的照片前 5% 分數 | AP |", "|---|---|---|---|---|"]
        for r in sorted(bad, key=lambda r: r.get("ap", 0)):
            lines.append(f"| {r['id']} | {r['path']} | {r['pos_median']:.3f} | {r['neg_p95']:.3f} | {r['ap']:.2f} |")
        lines.append("")
    lines += ["## 每個 tag", "",
              "| tag | 位置 | 正確／不是／你的 | 目前門檻 | 目前準確／抓到 | 建議門檻 | 建議後準確／抓到 | 狀態 |",
              "|---|---|---|---|---|---|---|---|"]
    for r in results:
        sug = f"{r['suggested']:.3f}" if r.get("suggested") is not None else "—"
        lines.append(
            f"| {r['id']} | {r['path']} | {r['pos']}／{r['neg']}／{r['mine']} | {r['current']:.3f} | "
            f"{pct(r.get('cur_precision'))}／{pct(r.get('cur_recall'))} | {sug} | "
            f"{pct(r.get('new_precision'))}／{pct(r.get('new_recall'))} | {r['status']} |")
    missing = [r for r in results if r["status"] == "資料不夠"]
    if missing:
        lines += ["", "## 資料不夠、沒有評估的 tag", "",
                  f"每個至少要 {args.min_positives} 張正確答案；請把照片放進「相簿主題設定」裡那個小分類的資料夾，"
                  "再加上 --local-folder 執行。", ""]
        lines += [f"- {r['path']}（{r['id']}）：Open Images {r['pos']} 張、你的照片 {r['mine']} 張" for r in missing]
    (out / "tag_report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"\n建議 {len(suggested)} 個、分不好 {len(bad)} 個、資料不夠 {len(missing)} 個")
    print(f"報表：{out / 'tag_report.md'}")


def write_folder(results, folder):
    """把建議門檻寫進「相簿主題設定」資料夾（只改小分類設定.json 的「門檻」）"""
    files = tf._scan_ids(folder)
    if not files:
        print(f"\n{folder} 裡沒有分類設定檔。先執行：python3 taxonomy_folder.py export {folder}")
        return
    changed = 0
    for r in results:
        if r["status"] != "建議" or r["id"] not in files:
            continue
        path = files[r["id"]]
        doc = json.loads(path.read_text(encoding="utf-8"))
        if doc.get("門檻") == r["suggested"]:
            continue
        doc["門檻"] = r["suggested"]
        tf.write_json(path, doc)
        changed += 1
    print(f"\n已更新 {changed} 個分類的門檻。檢查後套用到 App：")
    print(f"  python3 {SCRIPT_DIR / 'taxonomy_folder.py'} check {folder}")
    print(f"  python3 {SCRIPT_DIR / 'taxonomy_folder.py'} apply {folder}")


def cmd_folder_labels(args):
    """「相簿主題設定」資料夾裡你放的照片 → 訓練判斷器用的標記檔（只有照片向量和「是」，不含照片）。
    - 照片放在哪個小分類資料夾，就算那個分類的「是」；舊版資料夾的分類（例如「小卡」）訓練時會自動搬到合併後的分類
    - 可以一次給好幾個資料夾（例如組員各自整理的一份）；同一張照片在同一個分類只算一次
    - 照片向量用 App 內附的同一個模型（Core ML，需要 macOS），算過的存在快取，下次不用重算
    只讀取照片，不會修改或移動照片。"""
    import base64
    import datetime
    import hashlib

    local = {}
    for folder in args.folders:
        folder = Path(folder).expanduser()
        if not folder.exists():
            print(f"⚠️ 找不到資料夾：{folder}")
            continue
        found = scan_local(folder)
        print(f"{folder}：{len(found)} 個分類、{sum(len(v) for v in found.values())} 張照片")
        for nid, photos in found.items():
            local.setdefault(nid, []).extend(photos)
    if not local:
        print("沒有找到照片。照片要放在小分類資料夾裡（和 設定.json 放在一起）。")
        return 1

    emb_cache = EmbeddingCache(Path(args.cache).expanduser() / "image_embeddings.npz")
    encoder = None
    items, counts, seen, failed = [], {}, set(), 0
    dimension = None
    start = time.time()
    total = sum(len(v) for v in local.values())
    done = 0
    for nid, photos in sorted(local.items()):
        for path in photos:
            done += 1
            digest = hashlib.md5(path.read_bytes()).hexdigest()
            if (digest, nid) in seen:
                continue
            seen.add((digest, nid))
            key = f"local:md5:{digest}"
            vec = emb_cache.get(key)
            if vec is None:
                if encoder is None:
                    encoder = ImageEncoder()
                try:
                    vec = encoder(path)
                except Exception as error:
                    print(f"  ⚠️ 讀不到 {path.name}：{error}")
                    failed += 1
                    continue
                emb_cache.put(key, vec)
            vec = np.asarray(vec, dtype=np.float32).reshape(-1)
            dimension = int(vec.size)
            items.append({"id": f"folder-{digest}", "node": nid, "label": 1,
                          "e": base64.b64encode(vec.astype("<f4").tobytes()).decode()})
            counts[nid] = counts.get(nid, 0) + 1
            if done % 50 == 0:
                print(f"  {done}/{total}（{time.time() - start:.0f} 秒）")
    emb_cache.save()
    if not items:
        print("沒有可以用的照片。")
        return 1

    version, _ = tf.parse_catalog()
    doc = {"format": LABEL_FORMAT, "contributor": args.contributor, "catalogVersion": version,
           "dimension": dimension,
           "exportedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "items": items}
    out_dir = Path(args.output_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"selfIE標記_{args.contributor}.json"
    path.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"\n✅ 已輸出 {len(items)} 筆到 {path}" + (f"（{failed} 張讀不到，略過）" if failed else ""))
    for nid, count in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {nid}：{count} 張")
    print("\n接著執行 train_tag_classifiers.py 重新訓練分類判斷器。")
    return 0


# ───────────────────────── main ─────────────────────────

def main(argv=None):
    p = argparse.ArgumentParser(description="selfIE tag 門檻評估（Open Images V7）")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("check", "run"):
        s = sub.add_parser(name)
        s.add_argument("--cache", default="~/selfIE_tag_eval/cache", help="下載的資料與照片放這裡")
        s.add_argument("--out", default="~/selfIE_tag_eval", help="報表輸出資料夾")
        s.add_argument("--splits", nargs="+", default=["validation", "test"], choices=["validation", "test"])
        s.add_argument("--min-positives", type=int, default=20, help="至少幾張正確答案才評估")
        s.add_argument("--local-folder", help="「相簿主題設定」資料夾：小分類資料夾裡你自己放的照片")
    r = sub.choices["run"]
    r.add_argument("--per-tag", type=int, default=60, help="每個 tag 最多下載幾張正確答案（確認不是的再一半）")
    r.add_argument("--background", type=int, default=800, help="另外隨機下載幾張其他照片")
    r.add_argument("--max-images", type=int, default=0, help="Open Images 照片上限（0＝不限）")
    r.add_argument("--precision", type=float, default=0.9, help="目標準確率（標錯太多就調高）")
    r.add_argument("--prevalence", type=float, default=0.03, help="一般相簿裡屬於某個 tag 的比例")
    r.add_argument("--min-threshold", type=float, default=0.18)
    r.add_argument("--max-threshold", type=float, default=0.40)
    r.add_argument("--negatives", choices=["verified", "all"], default="all",
                   help="verified：只用人工確認「不是」的照片；all：沒有這個標籤的隨機照片也當成「不是」")
    r.add_argument("--workers", type=int, default=16)
    r.add_argument("--seed", type=int, default=7)
    r.add_argument("--write-folder", help="把建議門檻寫進這個「相簿主題設定」資料夾")
    lab = sub.add_parser("labels", help="輸出成訓練判斷器用的標記檔")
    lab.add_argument("--cache", default="~/selfIE_tag_eval/cache", help="下載的資料與照片放這裡")
    lab.add_argument("--splits", nargs="+", default=["validation", "test"], choices=["validation", "test"])
    lab.add_argument("--per-tag", type=int, default=100, help="每個 tag 最多幾張「是」（「不是」再一半）")
    lab.add_argument("--min-positives", type=int, default=20, help="Open Images 至少有幾張「是」才輸出")
    lab.add_argument("--max-images", type=int, default=15000, help="照片總數上限（0＝不限）")
    lab.add_argument("--only", nargs="+", help="只輸出這些 tag（tag id）")
    lab.add_argument("--cached-only", action="store_true",
                     help="只用之前 run 已經算好向量的照片：不下載、不用 Core ML（不是 Mac 也能跑）")
    lab.add_argument("--output-dir", default=str(DEFAULT_LABEL_DIR), help="標記檔輸出資料夾")
    lab.add_argument("--workers", type=int, default=16)
    lab.add_argument("--seed", type=int, default=7)
    fl = sub.add_parser("folder-labels", help="「相簿主題設定」資料夾裡的照片 → 訓練判斷器用的標記檔")
    fl.add_argument("folders", nargs="+", help="一個或多個「相簿主題設定」資料夾")
    fl.add_argument("--cache", default="~/selfIE_tag_eval/cache", help="照片向量快取放這裡")
    fl.add_argument("--output-dir", default=str(DEFAULT_LABEL_DIR), help="標記檔輸出資料夾")
    fl.add_argument("--contributor", default="相簿主題設定照片", help="標記檔的名稱（報告上顯示）")
    args = p.parse_args(argv)
    if args.cmd == "folder-labels":
        return cmd_folder_labels(args)
    if args.cmd == "labels":
        return cmd_labels(args)
    return cmd_check(args) if args.cmd == "check" else cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
