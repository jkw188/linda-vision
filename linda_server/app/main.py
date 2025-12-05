from fastapi import FastAPI, File, UploadFile, Form
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import shutil
import os
import time
from typing import Optional

# Import hàm mới (analyze_image_multimodal)
from app.services.vision_service import analyze_image_multimodal
from app.services.speech_service_with_pho import transcribe_audio, text_to_speech

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

@app.post("/chat-multimodal")
async def chat_multimodal(
    audio_file: UploadFile = File(...), 
    image_file: Optional[UploadFile] = File(None)
):
    # 1. Xử lý Audio (Đã bao gồm lọc nhiễu bên trong transcribe_audio)
    audio_path = f"{UPLOAD_DIR}/{audio_file.filename}"
    with open(audio_path, "wb") as buffer:
        shutil.copyfileobj(audio_file.file, buffer)
        
    print(f"--- Nhận lệnh: {audio_file.filename}")
    user_command = transcribe_audio(audio_path)
    print(f"--- Người dùng: {user_command}")
    
    if not user_command:
        return {"reply": "Tôi không nghe rõ."}

    # 2. Logic Trợ lý
    keywords_vision = ["nhìn", "thấy", "xem", "gì", "đâu", "trước mặt", "cảnh"]
    should_look = any(word in user_command.lower() for word in keywords_vision)

    vision_result = ""
    response_text = ""
    
    if should_look and image_file:
        print("--- Đang phân tích ảnh (BLIP + YOLO)...")
        image_path = f"{UPLOAD_DIR}/{image_file.filename}"
        with open(image_path, "wb") as buffer:
            shutil.copyfileobj(image_file.file, buffer)
            
        # Gọi hàm Vision mới
        vision_result = analyze_image_multimodal(image_path)
        response_text = f"{vision_result}" # Trả lời thẳng vào vấn đề
    
    elif should_look and not image_file:
        response_text = "Tôi cần nhìn, nhưng camera chưa gửi ảnh."
    else:
        response_text = f"Tôi đã nghe bạn nói: {user_command}"

    print(f"--- Linda trả lời: {response_text}")

    # 3. Sinh giọng nói (Voice Cloning hoặc Google)
    audio_base64 = ""
    if response_text:
        filename = f"reply_{int(time.time())}.mp3"
        audio_base64 = text_to_speech(response_text, filename)

    return {
        "user_text": user_command,
        "vision_info": vision_result,
        "reply": response_text,
        "audio_response": audio_base64
    }

if __name__ == "__main__":
    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)