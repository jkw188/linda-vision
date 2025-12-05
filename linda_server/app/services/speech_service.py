import whisper
import os
from gtts import gTTS
import base64

# Biến toàn cục lưu model
_stt_model = None

def load_stt_model():
    """
    Load model Whisper (chỉ load 1 lần)
    """
    global _stt_model
    if _stt_model is None:
        print("Đang tải model Whisper (Speech-to-Text)...")
        # Sử dụng model 'base' cho nhanh. Nếu máy mạnh có thể đổi thành 'small'
        # _stt_model = whisper.load_model("base") 
        _stt_model = whisper.load_model("small") 
        print("Model Whisper đã sẵn sàng!")
    return _stt_model

def transcribe_audio(audio_path: str) -> str:
    """
    Input: Đường dẫn file âm thanh (.wav, .mp3, .m4a...)
    Output: Văn bản tiếng Việt
    """
    model = load_stt_model()
    
    try:
        # Chạy nhận dạng
        # fp16=False để tránh lỗi nếu chạy trên CPU (không có GPU NVIDIA)
        result = model.transcribe(
            audio_path, 
            fp16=False, 
            language="vi",
            temperature=0, # chọn kết quả có xác suất cao nhất, không random
            condition_on_previous_text=False, # không dựa vào ngữ cảnh cũ (tránh lặp từ)
            best_of=1, # chỉ lấy 1 mẫu tốt nhất
            beam_size=1  # giảm beam search để chạy nhanh và bớt "ảo giác"
        ) 
        text = result["text"].strip()
        
        # Kiểm tra nếu text trả về là các cụm từ ảo giác phổ biến của Whisper thì loại bỏ
        hallucinations = ["Subtitles by", "Amara.org", "bối rối", "Copyright"]
        if any(h in text for h in hallucinations):
            return ""

        if not text:
            return ""
            
        return text
    except Exception as e:
        print(f"Lỗi STT: {e}")
        return ""
    

def text_to_speech(text: str, output_filename: str) -> str:
    """
    Input: Văn bản tiếng Việt
    Output: Chuỗi Base64 của file âm thanh (để gửi qua JSON)
    """
    try:
        print(f"Đang sinh giọng nói cho: {text}")
        # 1. Sinh file mp3 từ text
        tts = gTTS(text=text, lang='vi')
        
        # Lưu tạm vào file
        save_path = f"uploaded_files/{output_filename}"
        tts.save(save_path)
        
        # 2. Đọc file vừa sinh ra và mã hóa thành Base64
        # (Lý do: Để gửi kèm luôn trong cục JSON trả về cho tiện)
        with open(save_path, "rb") as audio_file:
            audio_bytes = audio_file.read()
            base64_string = base64.b64encode(audio_bytes).decode('utf-8')
            
        return base64_string
    except Exception as e:
        print(f"Lỗi TTS: {e}")
        return ""