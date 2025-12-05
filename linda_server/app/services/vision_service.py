from ultralytics import YOLO
import collections

# Khởi tạo model biến toàn cục (Global variable)
# Để tránh việc load lại model mỗi khi có request mới (rất chậm)
_model = None

def load_model():
    """
    Hàm này đảm bảo model chỉ được load 1 lần duy nhất khi server khởi động
    """
    global _model
    if _model is None:
        print("dang tai model YOLOv8...")
        _model = YOLO("yolov8n.pt") 
        print("Model YOLOv8 da san sang!")
    return _model

def analyze_image_with_yolo(image_path: str) -> str:
    """
    Input: Đường dẫn file ảnh
    Output: Câu mô tả các vật thể nhìn thấy (String)
    """
    model = load_model()
    
    # Chạy suy luận (Inference)
    # conf=0.5 nghĩa là chỉ lấy vật thể nào AI chắc chắn trên 50%
    results = model(image_path, conf=0.5) 
    
    detected_objects = []
    
    # Lấy danh sách tên các vật thể
    for result in results:
        for box in result.boxes:
            class_id = int(box.cls[0])
            class_name = model.names[class_id]
            detected_objects.append(class_name)
            
    # Nếu không thấy gì
    if not detected_objects:
        return "Linda không nhìn thấy vật thể nào rõ ràng."

    # Đếm số lượng: Counter({'person': 2, 'car': 1})
    counts = collections.Counter(detected_objects)
    
    # Tạo câu mô tả tiếng Việt (Tạm thời map tên tiếng Anh -> Việt đơn giản)
    # Sau này bạn có thể dùng Google Translate API ở đây nếu muốn xịn hơn
    description_parts = []
    for obj, count in counts.items():
        description_parts.append(f"{count} {obj}")
        
    description_text = ", ".join(description_parts)
    
    return f"Linda nhìn thấy: {description_text}"