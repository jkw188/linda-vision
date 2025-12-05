from ultralytics import YOLO
from transformers import BlipProcessor, BlipForConditionalGeneration
from PIL import Image
from deep_translator import GoogleTranslator
import torch

# Biến toàn cục lưu model
_yolo_model = None
_blip_processor = None
_blip_model = None
_translator = None

def load_vision_models():
    global _yolo_model, _blip_processor, _blip_model, _translator
    
    # 1. Load YOLO (Nhẹ)
    if _yolo_model is None:
        print("--- Loading YOLOv8...")
        _yolo_model = YOLO("yolov8n.pt")
        
    # 2. Load BLIP (Nặng - Khoảng 1GB)
    if _blip_model is None:
        print("--- Loading BLIP (Image Captioning)...")
        # Sử dụng model base của Salesforce
        _blip_processor = BlipProcessor.from_pretrained("Salesforce/blip-image-captioning-base")
        _blip_model = BlipForConditionalGeneration.from_pretrained("Salesforce/blip-image-captioning-base")
    
    # 3. Khởi tạo dịch giả (Anh -> Việt)
    if _translator is None:
        _translator = GoogleTranslator(source='auto', target='vi')
        
    return _yolo_model, _blip_processor, _blip_model, _translator

def estimate_distance(box_area, image_area):
    """
    Giả lập MiDaS: Ước lượng khoảng cách dựa trên diện tích chiếm dụng của vật thể
    """
    ratio = box_area / image_area
    if ratio > 0.5: return "rất gần (ngay trước mặt)"
    if ratio > 0.2: return "gần (khoảng 1-2 mét)"
    if ratio > 0.05: return "cách khoảng 3-5 mét"
    return "ở phía xa"

def analyze_image_multimodal(image_path: str) -> str:
    """
    Kết hợp YOLO + BLIP + Distance Heuristic
    """
    yolo, processor, blip_model, translator = load_vision_models()
    
    # --- PHẦN 1: MÔ TẢ NGỮ CẢNH (BLIP) ---
    try:
        raw_image = Image.open(image_path).convert('RGB')
        # Chuẩn bị ảnh cho BLIP
        inputs = processor(raw_image, return_tensors="pt")
        # Sinh câu mô tả (Tiếng Anh)
        out = blip_model.generate(**inputs, max_new_tokens=50)
        caption_en = processor.decode(out[0], skip_special_tokens=True)
        # Dịch sang Tiếng Việt
        caption_vi = translator.translate(caption_en)
    except Exception as e:
        print(f"Lỗi BLIP: {e}")
        caption_vi = "Tôi thấy một khung cảnh."

    # --- PHẦN 2: CHI TIẾT VẬT THỂ & KHOẢNG CÁCH (YOLO) ---
    results = yolo(image_path, conf=0.5, verbose=False)
    
    img_width, img_height = raw_image.size
    total_area = img_width * img_height
    
    detected_details = []
    
    for r in results:
        for box in r.boxes:
            # Lấy tên vật thể
            cls_id = int(box.cls[0])
            name_en = yolo.names[cls_id]
            
            # Tính diện tích box để đoán khoảng cách
            w_box = box.xywh[0][2]
            h_box = box.xywh[0][3]
            box_area = float(w_box * h_box)
            
            dist_desc = estimate_distance(box_area, total_area)
            
            # Dịch tên vật thể sang tiếng Việt (Sơ bộ)
            name_map = {"person": "người", "car": "xe hơi", "motorcycle": "xe máy", "dog": "chó", "cat": "mèo", "chair": "cái ghế"}
            name_vi = name_map.get(name_en, name_en)
            
            detected_details.append(f"một {name_vi} đang {dist_desc}")

    # --- TỔNG HỢP CÂU TRẢ LỜI ---
    # Ví dụ: "Khung cảnh là một người đàn ông đi trên phố. Cụ thể, tôi thấy: một người đang rất gần, một xe hơi ở xa."
    
    final_response = f"Khung cảnh chung là {caption_vi}."
    
    if detected_details:
        # Lấy tối đa 3 vật thể to nhất để không bị dài dòng
        details_text = ", ".join(detected_details[:3])
        final_response += f" Cụ thể, tôi thấy: {details_text}."
    
    return final_response