import whisper
import os

def download_model_manually():
    print("Đang kiểm tra và tải model Whisper 'small'...")
    print("Việc này có thể mất vài phút tùy mạng của bạn (khoảng 461MB).")
    
    try:
        # Load thử model, nó sẽ tự kích hoạt download
        model = whisper.load_model("small")
        print("✅ Đã tải xong model 'small'! Bây giờ bạn có thể chạy server.")
    except RuntimeError as e:
        if "checksum" in str(e):
            print("❌ File bị lỗi checksum. Đang tìm cách xóa file cũ...")
            # Đường dẫn cache mặc định trên Windows
            cache_dir = os.path.join(os.path.expanduser("~"), ".cache", "whisper")
            print(f"Vui lòng vào thư mục này: {cache_dir}")
            print("Và xóa file 'small.pt' đi, sau đó chạy lại script này.")
        else:
            print(f"Lỗi khác: {e}")

if __name__ == "__main__":
    download_model_manually()