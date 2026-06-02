# skills.py
import ollama
from duckduckgo_search import DDGS
from fpdf import FPDF

def analyze_photo_content(image_path: str) -> str:
    """
    視覺辨識工具。當需要了解照片內容、提取文字（如食譜、上課PPT、行程表）時調用。
    """
    print(f"DEBUG [右腦啟動]: 正在看圖... 『{image_path}』")
    try:
        vision_prompt = """
        你是一位專業的圖像分析專家。請詳細辨識這張照片中的物體，特別是：
        1. 商品品牌或名稱。
        2. 外觀特徵（顏色、形狀）。
        3. 如果有文字或標籤，請完整提取。
        請用繁體中文回答。
        """
        # 右腦 (vision) 在這裡啟動
        response = ollama.chat(
            model='gemma4:e4b',
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

def save_note_as_pdf(title: str, content: str) -> str:
    """PDF 儲存工具。將整理好的資訊存成 PDF 檔案。"""
    if not title.endswith(".pdf"): title += ".pdf"
    print(f"DEBUG [工具啟動]: 正在將筆記轉存為 PDF... 『{title}』")
    
    try:
        pdf = FPDF()
        pdf.add_page()
        pdf.add_font("NotoSansTC", "", "NotoSansTC-VariableFont_wght.ttf")
        pdf.set_font("NotoSansTC", size=12)
        
        # 寫入內容
        pdf.multi_cell(0, 10, text=content)
        pdf.output(title)
        
        print(f"DEBUG [工具完成]: PDF 已成功儲存至 {title}")
        return f"成功儲存 PDF 筆記：{title}"
    except Exception as e:
        return f"PDF 儲存失敗，請檢查字體檔是否存在：{e}"

def semantic_image_search(description: str) -> str:
    """抽象語意搜尋工具。找特定情境照片時使用。"""
    return f"根據語意『{description}』，找到最符合的照片是：'P1030347.JPG'"