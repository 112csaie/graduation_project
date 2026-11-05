#!/usr/bin/env python3
"""selfIE：把 Food-101、Places365 這兩個公開資料集輸出成訓練判斷器用的標記檔（在 Mac 上執行）

和 tag_threshold_eval.py labels（Open Images）一樣：下載照片 → 用 App 內附的 Core ML 模型算向量 →
輸出「協助訓練分類」同格式的標記檔到桌面 selfIE標記資料 資料夾，再執行 train_tag_classifiers.py 一起訓練。

    .venv312/bin/python3 public_datasets.py places365        # 約 500 MB（Places365 驗證集，每類 100 張）
    .venv312/bin/python3 public_datasets.py food101          # 原始檔約 5 GB，但只解出需要的類別，湊滿就停止下載
    .venv312/bin/python3 public_datasets.py all
    .venv312/bin/python3 public_datasets.py places365 --per-tag 80

- 每個資料集的類別 ↔ App 的 tag 對應寫在 public_dataset_map.json（第一次執行會建立），改那個檔案就好。
- 「是」：那個 tag 對應的類別的照片。
- 「不是」：同一個資料集裡、對應到其他 tag 的類別的照片（例如「壽司」的照片當作「不是麵食」）。
  沒有對應到任何 tag 的類別不拿來當「不是」（例如 Places365 的「餐廳」可能其實就是咖啡廳）。
- 輸出的標記檔只有照片向量和答案，不含照片。照片和向量快取在 ~/selfIE_tag_eval/cache/<資料集>/，訓練完可以刪掉。
- 授權：兩個資料集都只限研究、教學使用（課堂專題可以用；要上架或商用請另外確認）。
"""

import argparse
import base64
import datetime
import json
import math
import random
import sys
import tarfile
import time
import urllib.request
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import tag_threshold_eval as te  # noqa: E402  共用 Core ML 向量、快取、分類目錄
import taxonomy_folder as tf  # noqa: E402

MAP_FILE = SCRIPT_DIR / "public_dataset_map.json"
DEFAULT_CACHE = Path.home() / "selfIE_tag_eval" / "cache"

FOOD101_URL = "http://data.vision.ee.ethz.ch/cvl/food-101.tar.gz"
PLACES_IMAGES_URL = "http://data.csail.mit.edu/places/places365/val_256.tar"
PLACES_LISTS_URL = "http://data.csail.mit.edu/places/places365/filelist_places365-standard.tar"

MIN_POSITIVES = 15

DATASETS = {
    "food101": {"name": "Food-101", "file": "公開資料集_Food101.json"},
    "places365": {"name": "Places365", "file": "公開資料集_Places365.json"},
}

# tag id → 資料集的類別名稱
# Food-101：images/<類別>/ 的資料夾名稱；Places365：categories_places365.txt 的名稱（去掉開頭的 /a/ 這種字母）
DEFAULT_MAP = {
    "food101": {
        "sushi": ["sushi", "sashimi"],
        "noodle_dish": ["ramen", "pho", "pad_thai", "spaghetti_bolognese", "spaghetti_carbonara"],
        "bento": ["fried_rice", "bibimbap", "paella", "risotto"],
        "bbq": ["steak", "filet_mignon", "baby_back_ribs", "prime_rib", "pork_chop"],
        "pizza_burger": ["pizza", "hamburger"],
        "fried_chicken": ["chicken_wings", "french_fries", "onion_rings", "fried_calamari", "fish_and_chips"],
        "cake": ["cheesecake", "chocolate_cake", "carrot_cake", "red_velvet_cake", "strawberry_shortcake", "cup_cakes"],
        "ice_cream": ["ice_cream", "frozen_yogurt"],
        "bakery": ["donuts", "garlic_bread", "churros", "beignets", "macarons"],
    },
    "places365": {
        "cafe": ["coffee_shop"],
        "beach": ["beach"],
        "mountain": ["mountain", "mountain_snowy"],
        "forest": ["forest/broadleaf", "forest_path", "rainforest"],
        "lake_river": ["lake/natural", "river"],
        "aquarium": ["aquarium"],
        "theme_park": ["amusement_park"],
        "arcade": ["amusement_arcade"],
        "museum": ["museum/indoor", "art_gallery", "natural_history_museum"],
        "movie": ["movie_theater/indoor"],
        "airport": ["airport_terminal"],
        "hotel_room": ["hotel_room"],
        "temple": ["temple/asia", "pagoda"],
        "castle": ["castle"],
        "city_street": ["street", "downtown", "crosswalk"],
        "bakery": ["bakery/shop"],
        "groceries": ["supermarket"],
        "night_market": ["bazaar/outdoor", "market/outdoor"],
        "sports_game": ["stadium/baseball", "baseball_field", "stadium/soccer"],
        "camping": ["campsite"],
        "skiing": ["ski_slope", "ski_resort"],
        "workout": ["gymnasium/indoor"],
        "books": ["library/indoor", "bookstore"],
        "clothing": ["clothing_store"],
        "home_daily": ["living_room"],
        "desk_setup": ["home_office"],
    },
}


# ───────────── 共用 ─────────────

def load_map():
    if MAP_FILE.exists():
        data = json.loads(MAP_FILE.read_text(encoding="utf-8"))
        return {k: v for k, v in data.items() if not k.startswith("_")}
    doc = {"_說明": "資料集 → {tag id: [資料集的類別名稱]}。類別名稱見各資料集的類別清單；改完重新執行即可。"}
    doc.update(DEFAULT_MAP)
    MAP_FILE.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已建立對應表：{MAP_FILE}")
    return json.loads(json.dumps(DEFAULT_MAP))


def open_url(url):
    req = urllib.request.Request(url, headers={"User-Agent": "selfIE-public-datasets"})
    return urllib.request.urlopen(req, timeout=120)


class Progress:
    """下載進度（讀取串流時順便顯示）"""

    def __init__(self, response, label):
        self.r = response
        self.label = label
        self.total = int(response.headers.get("Content-Length") or 0)
        self.read_bytes = 0
        self.last = time.time()

    def read(self, n=-1):
        chunk = self.r.read(n)
        self.read_bytes += len(chunk)
        if time.time() - self.last > 10:
            self.last = time.time()
            total = f" / {self.total / 1e9:.2f} GB" if self.total else ""
            print(f"  {self.label}：已下載 {self.read_bytes / 1e9:.2f} GB{total}")
        return chunk


def plan_counts(mapping, per_tag):
    """每個類別要幾張：tag 的張數平均分給它對應的類別"""
    need = {}
    for nid, classes in mapping.items():
        if not classes:
            continue
        each = math.ceil(per_tag / len(classes))
        for c in classes:
            need[c] = max(need.get(c, 0), each)
    return need


def check_tags(mapping, by_id):
    known = {k: v for k, v in mapping.items() if k in by_id}
    for k in mapping:
        if k not in by_id:
            print(f"⚠️ 對應表裡的 tag「{k}」不在 App 的分類目錄裡（可能改名或移除了），略過")
    return known


def embed(paths, cache_file):
    """(類別, 檔名) → 向量；算過的存在快取"""
    cache = te.EmbeddingCache(cache_file)
    encoder = None
    out = {}
    start = time.time()
    for i, (key, path) in enumerate(sorted(paths.items()), 1):
        ck = f"{key[0]}/{key[1]}"
        vec = cache.get(ck)
        if vec is None:
            if encoder is None:
                encoder = te.ImageEncoder()
            try:
                vec = encoder(path)
            except Exception as e:
                print(f"  略過 {path.name}：{e}")
                continue
            cache.put(ck, vec)
        out[key] = np.asarray(vec, dtype=np.float32).reshape(-1)
        if i % 500 == 0:
            print(f"  向量 {i}/{len(paths)}（{time.time() - start:.0f} 秒）")
    cache.save()
    return out


def write_labels(ds, mapping, by_class, vectors, per_tag, out_dir, rng, by_id):
    """by_class：類別 → [(類別, 檔名)]。是＝自己的類別；不是＝對應到其他 tag 的類別"""
    version, _ = tf.parse_catalog()
    items, counts = [], {}
    for nid, classes in sorted(mapping.items()):
        own = set(classes)
        pos = [k for c in classes for k in by_class.get(c, []) if k in vectors]
        pos = rng.sample(pos, min(len(pos), per_tag))
        if len(pos) < MIN_POSITIVES:
            if pos or classes:
                print(f"  ・{te.node_path_text(by_id[nid], by_id)}（{nid}）：只有 {len(pos)} 張，略過")
            continue
        other_classes = sorted({c for t, cs in mapping.items() if t != nid for c in cs} - own)
        neg_pool = [k for c in other_classes for k in by_class.get(c, []) if k in vectors]
        neg = rng.sample(neg_pool, min(len(neg_pool), per_tag // 2))
        for key, label in [(k, 1) for k in pos] + [(k, 0) for k in neg]:
            items.append({"id": f"{ds}-{key[0].replace('/', '_')}-{key[1]}", "node": nid, "label": label,
                          "e": base64.b64encode(vectors[key].astype("<f4").tobytes()).decode()})
        counts[nid] = (len(pos), len(neg))
    if not items:
        sys.exit("沒有任何照片向量，沒有輸出。")
    info = DATASETS[ds]
    doc = {"format": te.LABEL_FORMAT, "contributor": f"公開資料集：{info['name']}", "source": "public-dataset",
           "catalogVersion": version, "dimension": int(len(next(iter(vectors.values())))),
           "exportedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "items": items}
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / info["file"]
    path.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"\n{info['name']}：每個 tag 的張數（是／不是）")
    for nid, (p, n) in counts.items():
        print(f"  {te.node_path_text(by_id[nid], by_id)}（{nid}）：{p}／{n}")
    print(f"✅ 已輸出 {len(items)} 筆到 {path}（{path.stat().st_size / 1e6:.1f} MB）")


# ───────────── Food-101 ─────────────

def run_food101(args, mapping, by_id):
    root = Path(args.cache).expanduser() / "food101"
    image_dir = root / "images"
    need = plan_counts(mapping, args.per_tag)
    have = {c: sorted((image_dir / c).glob("*.jpg")) if (image_dir / c).exists() else [] for c in need}
    # 之前完整讀過一次的話，記得資料集裡有哪些類別：名稱打錯的類別不會害每次都重新下載 5 GB
    seen_file = root / "classes_seen.json"
    seen = set(json.loads(seen_file.read_text())) if seen_file.exists() else None
    missing = {c: n - len(have[c]) for c, n in need.items() if len(have[c]) < n and (seen is None or c in seen)}
    if missing:
        print(f"Food-101：要 {len(need)} 個類別、每類最多 {max(need.values())} 張；從 {FOOD101_URL} 串流下載，只解出需要的照片，湊滿就停止")
        # 從頭讀串流：之前解出來的照片讀到時也會算進去（不會重複計算）
        got = {c: 0 for c in need}
        classes = set()
        finished = True
        with open_url(FOOD101_URL) as r, tarfile.open(fileobj=Progress(r, "Food-101"), mode="r|gz") as tar:
            for member in tar:
                parts = member.name.split("/")
                # food-101/images/<類別>/<編號>.jpg
                if len(parts) != 4 or parts[1] != "images" or not member.isfile():
                    continue
                c = parts[2]
                classes.add(c)
                if c not in need or got[c] >= need[c]:
                    continue
                dest = image_dir / c / parts[3]
                if not dest.exists():
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    src = tar.extractfile(member)
                    tmp = dest.with_suffix(".part")
                    tmp.write_bytes(src.read())
                    tmp.rename(dest)
                got[c] += 1
                if all(got[k] >= need[k] for k in need):
                    print("  需要的照片都有了，停止下載")
                    finished = False
                    break
        if finished:
            seen_file.write_text(json.dumps(sorted(classes)))
        unknown = [c for c in need if got[c] == 0 and (seen is None or c not in seen)]
        if unknown:
            print(f"⚠️ Food-101 沒有這些類別（檢查 {MAP_FILE.name} 的名稱）：{'、'.join(unknown)}")
        have = {c: sorted((image_dir / c).glob("*.jpg")) if (image_dir / c).exists() else [] for c in need}
    paths = {(c, p.name): p for c, files in have.items() for p in files[:need[c]]}
    print(f"Food-101：{len(paths)} 張照片，算向量…")
    vectors = embed(paths, root / "embeddings.npz")
    by_class = {}
    for key in paths:
        by_class.setdefault(key[0], []).append(key)
    write_labels("food101", mapping, by_class, vectors, args.per_tag, Path(args.output_dir).expanduser(),
                 random.Random(args.seed), by_id)


# ───────────── Places365 ─────────────

def places_lists(root):
    """類別名稱 → 編號；驗證集檔名 → 編號"""
    lists = root / "filelist_places365-standard.tar"
    te.download(PLACES_LISTS_URL, lists)
    categories, val = {}, {}
    with tarfile.open(lists) as tar:
        for member in tar.getmembers():
            name = Path(member.name).name
            if name not in ("categories_places365.txt", "places365_val.txt"):
                continue
            text = tar.extractfile(member).read().decode("utf-8")
            for line in text.splitlines():
                if not line.strip():
                    continue
                left, idx = line.rsplit(" ", 1)
                if name == "categories_places365.txt":
                    # /a/airfield → airfield；/f/forest/broadleaf → forest/broadleaf
                    categories[left.strip("/").split("/", 1)[1]] = int(idx)
                else:
                    val[left.strip("/")] = int(idx)
    if not categories or not val:
        sys.exit("Places365 的類別清單讀不到，請刪掉快取裡的 filelist_places365-standard.tar 再試一次。")
    return categories, val


def run_places365(args, mapping, by_id):
    root = Path(args.cache).expanduser() / "places365"
    image_dir = root / "val_256"
    categories, val = places_lists(root)
    bad = sorted({c for cs in mapping.values() for c in cs if c not in categories})
    if bad:
        print(f"⚠️ Places365 沒有這些類別（檢查 {MAP_FILE.name}）：{'、'.join(bad)}")
        mapping = {t: [c for c in cs if c in categories] for t, cs in mapping.items()}
        mapping = {t: cs for t, cs in mapping.items() if cs}
    need = plan_counts(mapping, args.per_tag)
    index_to_class = {categories[c]: c for c in need}
    rng = random.Random(args.seed)
    files_by_class = {}
    for fname, idx in sorted(val.items()):
        if idx in index_to_class:
            files_by_class.setdefault(index_to_class[idx], []).append(fname)
    wanted = {}
    for c, files in files_by_class.items():
        for f in rng.sample(files, min(len(files), need[c])):
            wanted[f] = c
    todo = {f for f in wanted if not (image_dir / f).exists()}
    if todo:
        print(f"Places365：要 {len(need)} 個類別、{len(wanted)} 張；從 {PLACES_IMAGES_URL} 串流下載（約 500 MB），只解出需要的照片")
        with open_url(PLACES_IMAGES_URL) as r, tarfile.open(fileobj=Progress(r, "Places365"), mode="r|") as tar:
            for member in tar:
                name = Path(member.name).name
                if name not in todo or not member.isfile():
                    continue
                dest = image_dir / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                tmp = dest.with_suffix(".part")
                tmp.write_bytes(tar.extractfile(member).read())
                tmp.rename(dest)
                todo.discard(name)
                if not todo:
                    print("  需要的照片都有了，停止下載")
                    break
    paths = {(c, f): image_dir / f for f, c in wanted.items() if (image_dir / f).exists()}
    print(f"Places365：{len(paths)} 張照片，算向量…")
    vectors = embed(paths, root / "embeddings.npz")
    by_class = {}
    for key in paths:
        by_class.setdefault(key[0], []).append(key)
    write_labels("places365", mapping, by_class, vectors, args.per_tag, Path(args.output_dir).expanduser(),
                 random.Random(args.seed), by_id)


def main(argv=None):
    p = argparse.ArgumentParser(description="Food-101、Places365 → 訓練判斷器用的標記檔")
    p.add_argument("dataset", choices=["food101", "places365", "all"])
    p.add_argument("--per-tag", type=int, default=150, help="每個 tag 最多幾張「是」（「不是」再一半）")
    p.add_argument("--cache", default=str(DEFAULT_CACHE), help="照片與向量快取")
    p.add_argument("--output-dir", default=str(te.DEFAULT_LABEL_DIR), help="標記檔輸出資料夾")
    p.add_argument("--seed", type=int, default=7)
    args = p.parse_args(argv)

    nodes, by_id, _ = te.load_nodes()
    full = load_map()
    for ds in (["places365", "food101"] if args.dataset == "all" else [args.dataset]):
        mapping = check_tags(full.get(ds, {}), by_id)
        if ds == "food101":
            run_food101(args, mapping, by_id)
        else:
            run_places365(args, mapping, by_id)
    print("\n下一步：.venv312/bin/python3 train_tag_classifiers.py（會讀桌面 selfIE標記資料 裡所有標記檔）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
