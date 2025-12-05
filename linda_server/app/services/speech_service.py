import whisper
import os
import base64
import noisereduce as nr
import soundfile as sf
import librosa
from gtts import gTTS

# Biến toàn cục
_stt_model = None

def load_stt_model():
    global _stt_model
    if _stt_model is None:
        print("--- Loading Whisper (STT)...")
        # Dùng model 'base' cho nhanh. Nếu máy mạnh có thể đổi thành 'small'
        _stt_model = whisper.load_model("base") 
    return _stt_model

# --- 1. LỌC NHIỄU (Điểm cộng kỹ thuật) ---
def clean_audio(file_path: str):
    """
    Sử dụng thư viện noisereduce để làm sạch tạp âm nền
    trước khi đưa vào nhận dạng.
    """
    try:
        # Đọc file audio
        data, rate = librosa.load(file_path, sr=None)
        
        # Giảm nhiễu (Stationary noise reduction)
        # prop_decrease=0.75 nghĩa là giảm 75% tiếng ồn nền tìm thấy
        reduced_noise = nr.reduce_noise(y=data, sr=rate, stationary=True, prop_decrease=0.75)
        
        # Lưu đè lại file đã sạch
        sf.write(file_path, reduced_noise, rate)
    except Exception as e:
        print(f"Lỗi lọc nhiễu (bỏ qua): {e}")

# --- 2. NHẬN DẠNG GIỌNG NÓI (WHISPER) ---
def transcribe_audio(audio_path: str) -> str:
    # Bước 1: Tiền xử lý (Lọc nhiễu)
    clean_audio(audio_path)
    
    # Bước 2: Load model và nhận dạng
    model = load_stt_model()
    try:
        # fp16=False để chạy ổn định trên CPU
        result = model.transcribe(audio_path, fp16=False, language="vi")
        text = result["text"].strip()
        return text
    except Exception as e:
        print(f"Lỗi STT Whisper: {e}")
        return ""

# --- 3. TỔNG HỢP GIỌNG NÓI (GOOGLE TTS) ---
def text_to_speech(text: str, output_filename: str) -> str:
    """
    Sử dụng Google TTS API - Ổn định và nhanh nhất cho demo.
    """
    save_path = f"uploaded_files/{output_filename}"
    
    try:
        print(f"Đang sinh giọng nói (Google): {text[:30]}...")
        
        # Gọi Google API
        tts = gTTS(text=text, lang='vi')
        tts.save(save_path)
        
        # Đọc file vừa lưu và mã hóa Base64 để gửi về App
        with open(save_path, "rb") as audio_file:
            audio_bytes = audio_file.read()
            base64_string = base64.b64encode(audio_bytes).decode('utf-8')
            
        return base64_string
        
    except Exception as e:
        print(f"Lỗi TTS: {e}")
        return ""