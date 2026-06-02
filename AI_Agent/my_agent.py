# main.py
import ollama
import skills

available_tools = {
    "analyze_photo_content": skills.analyze_photo_content,
    "search_online_info": skills.search_online_info,
    "save_note": skills.save_note,
    "semantic_image_search": skills.semantic_image_search,
    "save_note_as_pdf" : skills.save_note_as_pdf
}

SYSTEM_INSTRUCTION = """
你是一個專業的本地端 iOS 相簿助手。
你擁有強大的工具，請務必按照使用者的要求『完整』執行所有步驟，絕對不能只做一半！

【標準作業流程 (SOP)】
1. 看照片：若使用者給了照片路徑，你必須優先呼叫 `analyze_photo_content` 工具。
2. 查資料：若需要了解評價或背景，必須呼叫 `search_online_info` 工具。
3. 存筆記 (最重要)：只要使用者提到「存成」、「筆記」、「存檔」或「PDF」，你收集完資訊後，【絕對必須】呼叫 `save_note_as_pdf` 工具將整理好的內容存檔！

【🚨 嚴重警告 🚨】
絕對禁止只把文字印在對話中叫使用者自己複製！你必須親自動手呼叫 `save_note_as_pdf` 工具完成存檔。不准找任何技術錯誤的藉口，在呼叫完存檔工具之前，不准結束任務！
請全程使用繁體中文回覆。
"""

def ask_local_agent(user_message: str, image_path: str = None):
    # 將圖片路徑轉化為文字提示，交給左腦
    if image_path:
        user_message += f"\n(系統提示：使用者提供了一張照片，路徑為 '{image_path}')"
        
    print(f"\n[使用者]: {user_message}")
    messages = [{'role': 'system', 'content': SYSTEM_INSTRUCTION}, {'role': 'user', 'content': user_message}]

    try:
        # 使用迴圈讓 Agent 可以連續執行多個步驟
        while True:
            response = ollama.chat(model='gemma4:e4b', messages=messages, tools=list(available_tools.values()))
            message = response['message']
            
            # 情況 A：如果模型決定不呼叫工具了，代表它準備好給出最終文字回答
            if not message.get('tool_calls'):
                print(f"\n[Agent 最終回答]: {message['content']}")
                break # 任務完成，跳出迴圈
                
            # 情況 B：模型決定呼叫工具 (可能是第一步，也可能是第二、第三步)
            messages.append(message) # 把模型的決定存入記憶，這步很重要！
            
            for tool_call in message['tool_calls']:
                tool_name = tool_call['function']['name']
                tool_args = tool_call['function']['arguments']
                
                print(f"\n🤖 [左腦思考中]: 決定指派任務給 '{tool_name}'，參數: {tool_args}")
                
                if tool_name in available_tools:
                    tool_result = available_tools[tool_name](**tool_args)
                    # 把工具執行的結果餵回去給模型
                    messages.append({'role': 'tool', 'content': str(tool_result), 'name': tool_name})
                    
    except Exception as e:
        print(f"\n[錯誤]: 發生異常 -> {e}")

if __name__ == "__main__":
    # 執行測試！請確保 P1030347.JPG 和 main.py 放在一起
# 測試情境：語氣更加明確、分步驟
    ask_local_agent(
        user_message="請幫我做三件事：1.看這張照片是什麼。2.上網查它的相關評價。3.將上述所有資訊，存成標題為『測試筆記』的PDF檔案。",
        image_path="002.jpg"
    )