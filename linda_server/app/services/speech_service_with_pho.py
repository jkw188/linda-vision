from transformers import pipeline 
import warnings

stt_model = None
warnings.filterwarnings("ignore")

def load_model():
    stt_model = pipeline("automatic-speech-recognition", model="vinai/PhoWhisper-large", device="cuda")
    return stt_model

def stt_with_pho(audio_path):
    model = load_model()
    result = model(audio_path)
    return result['text']

res = stt_with_pho("./uploaded_files/linda.mp3")
print(res)