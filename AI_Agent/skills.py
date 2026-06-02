# skills.py
import ollama
from duckduckgo_search import DDGS

def analyze_photo_content(image_path: str) -> str:
    """
    視覺辨識工具。當需要了解照片內容、提取文字（如食譜、上課PPT、行程表）時調用。
    """
    print(f"DEBUG [右腦啟動]: 正在看圖... 『{image_path}』")
    try:
        vision_prompt = """
        請詳細描述這張圖片的內容。如果有文字請提取出來，如果是食譜或筆記請列出重點。請用繁體中文回答。
        """
        # 右腦 (vision) 在這裡啟動
        response = ollama.chat(
            model='llava',
            messages=[{'role': 'user', 'content': vision_prompt, 'images': [image_path]}]
        )
        print("DEBUG [右腦完成]: 照片內容已解析完畢！")
        return response['message']['content']
    except Exception as e:
        return f"照片分析失敗，請檢查檔案：{e}"

def search_online_info(query: str) -> str:
    """聯網搜尋工具。當需要查找外部資料或評價時調用。"""
    print(f"DEBUG [工具啟動]: 使用 DuckDuckGo 搜尋... 『{query}』")
    try:
        results = DDGS().text(query, max_results=3) 
        if not results: return "找不到相關結果。"
        return "\n".join([f"標題: {r.get('title')}\n摘要: {r.get('body')}" for r in results])
    except Exception as e:
        return f"搜尋失敗：{e}"

def save_note(title: str, content: str) -> str:
    """筆記儲存工具。將資訊存成 Markdown 檔案。"""
    if not title.endswith(".md"): title += ".md"
    with open(title, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"DEBUG [工具啟動]: 筆記已儲存至 {title}")
    return f"成功儲存筆記：{title}"

def semantic_image_search(description: str) -> str:
    """抽象語意搜尋工具。找特定情境照片時使用。"""
    return f"根據語意『{description}』，找到最符合的照片是：'P1030347.JPG'"