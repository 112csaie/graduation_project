# main.py
import ollama
import skills

available_tools = {
    "analyze_photo_content": skills.analyze_photo_content,
    "search_online_info": skills.search_online_info,
    "save_note": skills.save_note,
    "semantic_image_search": skills.semantic_image_search
}

SYSTEM_INSTRUCTION = """
你是一個專業的本地端 iOS 相簿助手。
你擁有強大的工具，請務必按照使用者的要求『完整』執行所有步驟，絕對不能只做一半！

【標準作業流程 (SOP)】
1. 看照片：若使用者給了照片路徑，你必須優先呼叫 `analyze_photo_content` 工具。
2. 查資料：若需要了解評價或背景，必須呼叫 `search_online_info` 工具。
3. 存筆記 (最重要)：只要使用者提到「存成」、「筆記」、「存檔」，你收集完資訊後，【絕對必須】呼叫 `save_note` 工具將整理好的 Markdown 內容存檔！

警告：在呼叫完 save_note 存檔成功之前，不准結束任務！
請全程使用繁體中文回覆。
"""

def ask_local_agent(user_message: str, image_path: str = None):
    # 將圖片路徑轉化為文字提示，交給左腦
    if image_path:
        user_message += f"\n(系統提示：使用者提供了一張照片，路徑為 '{image_path}')"
        
    print(f"\n[使用者]: {user_message}")
    messages = [{'role': 'system', 'content': SYSTEM_INSTRUCTION}, {'role': 'user', 'content': user_message}]

    try:
        # 左腦 (llama3.1) 開始思考
        response = ollama.chat(model='qwen2.5:3b', messages=messages, tools=list(available_tools.values()))
        message = response['message']
        
        # 檢查左腦是否決定呼叫工具
        if message.get('tool_calls'):
            for tool_call in message['tool_calls']:
                tool_name = tool_call['function']['name']
                tool_args = tool_call['function']['arguments']
                
                print(f"\n🤖 [左腦思考中]: 決定指派任務給 '{tool_name}'，參數: {tool_args}")
                
                if tool_name in available_tools:
                    tool_result = available_tools[tool_name](**tool_args)
                    messages.append(message) 
                    messages.append({'role': 'tool', 'content': str(tool_result), 'name': tool_name})
            
            # 左腦看著工具回傳的結果，給出最終回答
            final_response = ollama.chat(model='qwen2.5:3b', messages=messages)
            print(f"\n[Agent 最終回答]: {final_response['message']['content']}")
        else:
            print(f"\n[Agent]: {message['content']}")

    except Exception as e:
        print(f"\n[錯誤]: 發生異常 -> {e}")

if __name__ == "__main__":
    # 執行測試！請確保 P1030347.JPG 和 main.py 放在一起
# 測試情境：語氣更加明確、分步驟
    ask_local_agent(
        user_message="請幫我做三件事：1.看這張照片是什麼。2.上網查它的相關評價。3.將上述所有資訊，存成標題為『測試筆記』的筆記。",
        image_path="2020121501-12.jpg"
    )