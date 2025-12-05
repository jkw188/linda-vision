from transformers import pipeline 
import warnings
import base64
import noisereduce as nr
import soundfile as sf
import librosa
from gtts import gTTS

stt_model = None
warnings.filterwarnings("ignore")

def load_model():
    global stt_model
    if stt_model is None:
        print("--- Loading Pho Whisper...")
        stt_model = pipeline("automatic-speech-recognition", model="vinai/PhoWhisper-small", device="cuda")
    return stt_model

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

def transcribe_audio(audio_path):
    clean_audio(audio_path)
    model = load_model()
    result = model(audio_path)
    return result['text']

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