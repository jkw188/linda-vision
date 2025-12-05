from fastapi import FastAPI, File, UploadFile, Form
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import shutil
import os
from typing import Optional
import time

# Import các services
from app.services.vision_service import analyze_image_with_yolo
from app.services.speech_service import transcribe_audio
from app.services.speech_service import text_to_speech

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

UPLOAD_DIR = "uploaded_files"
os.makedirs(UPLOAD_DIR, exist_ok=True)

@app.get("/")
async def root():
    return {"message": "Linda Vision & Voice Server"}

@app.post("/chat-multimodal")
async def chat_multimodal(
    audio_file: UploadFile = File(...), 
    image_file: Optional[UploadFile] = File(None)
):
    """
    API nhận cả Âm thanh (lệnh) và Ảnh (ngữ cảnh)
    """
    response_text = ""
    
    # --- BƯỚC 1: XỬ LÝ ÂM THANH (STT) ---
    # Lưu file audio tạm thời
    audio_path = f"{UPLOAD_DIR}/{audio_file.filename}"
    with open(audio_path, "wb") as buffer:
        shutil.copyfileobj(audio_file.file, buffer)
        
    print(f"Đang nghe lệnh từ file: {audio_file.filename}...")
    user_command = transcribe_audio(audio_path)
    print(f"Người dùng nói: {user_command}")
    
    if not user_command:
        return {"reply": "Xin lỗi, tôi không nghe rõ bạn nói gì."}

    # --- BƯỚC 2: PHÂN TÍCH Ý ĐỊNH (Logic đơn giản) ---
    # Kiểm tra xem câu nói có từ khóa liên quan đến 'nhìn' không
    keywords_vision = ["nhìn", "thấy", "xem", "gì", "đâu", "trước mặt"]
    should_look = any(word in user_command.lower() for word in keywords_vision)

    vision_result = ""
    
    if should_look and image_file:
        # --- BƯỚC 3: NẾU CẦN NHÌN -> GỌI YOLO ---
        print("Phát hiện yêu cầu thị giác. Đang xử lý ảnh...")
        image_path = f"{UPLOAD_DIR}/{image_file.filename}"
        with open(image_path, "wb") as buffer:
            shutil.copyfileobj(image_file.file, buffer)
            
        vision_result = analyze_image_with_yolo(image_path)
        
        # Ghép câu trả lời
        response_text = f"Bạn vừa hỏi: '{user_command}'. {vision_result}"
    
    elif should_look and not image_file:
        response_text = "Bạn muốn tôi nhìn, nhưng tôi chưa nhận được hình ảnh nào cả."
        
    else:
        # Nếu chỉ chào hỏi bình thường
        response_text = f"Chào bạn, tôi đã nghe thấy bạn nói: '{user_command}'. Tôi có thể giúp gì?"

    audio_base64 = ""
    if response_text:
        # Tạo tên file unique dựa trên thời gian
        filename = f"reply_{int(time.time())}.mp3"
        audio_base64 = text_to_speech(response_text, filename)

    return {
        "user_text": user_command,
        "vision_info": vision_result,
        "reply": response_text,
        "audio_response": audio_base64  # <--- Gửi kèm cục âm thanh này về
    }

if __name__ == "__main__":
    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)