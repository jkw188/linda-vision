import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// --- CẤU HÌNH ---
const String PICOVOICE_ACCESS_KEY =
    "90LGHncAk9HhZ1zv/MauEm6nbhdzB1Pw/0i8ZgCzNJ06387D/kN74Q=="; // Key của bạn

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Khôi phục Firebase
  try {
    await Firebase.initializeApp();
    print("Kết nối Firebase thành công!");
  } catch (e) {
    print("Chế độ Offline (Lỗi Firebase: $e)");
  }

  // 2. Lấy danh sách Camera
  try {
    _cameras = await availableCameras();
  } catch (e) {
    print("Lỗi Cam: $e");
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Linda Vision',
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
      home: const LindaOptimized(),
    );
  }
}

class LindaOptimized extends StatefulWidget {
  const LindaOptimized({super.key});
  @override
  State<LindaOptimized> createState() => _LindaOptimizedState();
}

class _LindaOptimizedState extends State<LindaOptimized>
    with WidgetsBindingObserver {
  String trangThai = "ĐANG KHỞI TẠO...";
  String cauTraLoiCuaLinda = "";

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer(); // Player cho giọng nói AI
  final AudioPlayer _effectPlayer = AudioPlayer(); // Player cho tiếng Ting Ting

  // Camera và Porcupine
  CameraController? _cameraController;
  PorcupineManager? _porcupineManager;

  File? _imageFile;
  bool _isRecording = false; // Trạng thái đang ghi âm
  bool _isProcessing = false; // Trạng thái đang xử lý (gửi server/nhận về)

  String get serverUrl {
    // 10.0.2.2 là localhost của máy tính khi chạy trên máy ảo Android
    String baseUrl = kIsWeb ? "http://127.0.0.1:8000" : "http://10.0.2.2:8000";
    return "$baseUrl/chat-multimodal";
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable(); // Giữ màn hình sáng
    _khoiTaoHeThong();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _porcupineManager?.delete();
    _disposeCamera();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _effectPlayer.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // --- XỬ LÝ BACKGROUND ---
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Khi quay lại app, nếu hệ thống đang rảnh thì bật lại mic nghe
      if (!_isRecording && !_isProcessing && _porcupineManager != null) {
        _startWakeWordListener();
      }
    }
  }

  // --- QUẢN LÝ CAMERA ---
  Future<void> _khoiTaoCamera() async {
    if (_cameras.isEmpty ||
        (_cameraController != null && _cameraController!.value.isInitialized)) {
      return;
    }
    print("--- ĐANG BẬT CAMERA NGẦM ---");
    _cameraController = CameraController(
      _cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    try {
      await _cameraController!.initialize();
      await _cameraController!.setFlashMode(FlashMode.off);
      if (mounted) setState(() {});
    } catch (e) {
      print("Lỗi bật Camera: $e");
    }
  }

  Future<void> _disposeCamera() async {
    if (_cameraController != null) {
      await _cameraController!.dispose();
      _cameraController = null;
    }
  }

  Future<void> _khoiTaoHeThong() async {
    await [Permission.microphone, Permission.camera].request();
    await _initPorcupine();
  }

  Future<void> _initPorcupine() async {
    try {
      _porcupineManager = await PorcupineManager.fromKeywordPaths(
        PICOVOICE_ACCESS_KEY,
        ["assets/porcupine/hey_linda_android.ppn"],
        _wakeWordCallback,
        modelPath: "assets/porcupine/porcupine_params.pv",
        sensitivities: [1.0], // Nhạy tối đa
      );
      await _startWakeWordListener();
      if (mounted) setState(() => trangThai = "SẴN SÀNG! NÓI 'HEY LINDA'");
    } on PorcupineException catch (err) {
      if (mounted) setState(() => trangThai = "Lỗi Porcupine: ${err.message}");
    }
  }

  Future<void> _startWakeWordListener() async {
    try {
      if (_porcupineManager != null) {
        await _porcupineManager!.start();
        print("Đang lắng nghe Hey Linda...");
      }
    } catch (e) {
      print("Lỗi Start Mic: $e");
    }
  }

  Future<void> _stopWakeWordListener() async {
    await _porcupineManager?.stop();
  }

  // --- LOGIC CHÍNH: KHI NGHE THẤY TỪ KHÓA ---
  void _wakeWordCallback(int keywordIndex) async {
    print("1. ĐÃ NGHE THẤY HEY LINDA!");

    // B1: Dừng nghe từ khóa ngay lập tức để giải phóng Mic
    await _stopWakeWordListener();

    if (mounted) setState(() => trangThai = "LINDA ĐANG NGHE...");

    // B2: Phát tiếng Ting và CHỜ nó kết thúc (Khắc phục lỗi ghi âm dính tiếng Ting)
    await _playTingSoundAndWait();

    // B3: Rung nhẹ báo hiệu
    await rungNhe();

    // B4: Bắt đầu ghi âm và chụp ảnh
    batDauGhiAmVaBatCamera();
  }

  // Hàm phát âm thanh có cơ chế chờ (Blocking wait)
  Future<void> _playTingSoundAndWait() async {
    try {
      final completer = Completer<void>();

      // Set source
      await _effectPlayer.setSource(AssetSource('sounds/ting.mp3'));

      // Lắng nghe sự kiện hoàn thành
      StreamSubscription? subscription;
      subscription = _effectPlayer.onPlayerComplete.listen((event) {
        if (!completer.isCompleted) completer.complete();
        subscription?.cancel();
      });

      // Bắt đầu phát
      await _effectPlayer.resume();

      // Fallback: Tự ngắt sau 1.5s phòng trường hợp lỗi không có event complete
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (!completer.isCompleted) {
          completer.complete();
          subscription?.cancel();
        }
      });

      await completer.future; // Code sẽ dừng ở đây cho đến khi ting xong
    } catch (e) {
      print("Lỗi phát Ting: $e");
    }
  }

  Future<void> batDauGhiAmVaBatCamera() async {
    try {
      _khoiTaoCamera(); // Bật cam ngầm song song

      if (await _audioRecorder.hasPermission()) {
        final directory = await getTemporaryDirectory();
        String path = '${directory.path}/lenh.wav';

        // --- CẤU HÌNH ĐÃ SỬA ---
        const config = RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          // Đã xóa các tham số noiseSuppression/echoCancellation gây lỗi
        );

        if (mounted) {
          setState(() {
            _isRecording = true;
            _imageFile = null;
            trangThai = "MỜI BẠN NÓI...";
            cauTraLoiCuaLinda = "";
          });
        }

        // --- Delay quan trọng để OS chuyển Mic mode ---
        await Future.delayed(const Duration(milliseconds: 300));

        // Đảm bảo không có tiến trình ghi âm nào đang chạy
        if (await _audioRecorder.isRecording()) {
          await _audioRecorder.stop();
        }

        await _audioRecorder.start(config, path: path);
        print("2. Đang ghi âm...");

        // Ghi âm trong 4 giây rồi tự dừng
        Future.delayed(const Duration(seconds: 4), dungGhiAmVaChupAnh);
      }
    } catch (e) {
      print("Lỗi ghi âm: $e");
      _resetHeThongDeLangNgheTiep();
    }
  }

  Future<void> dungGhiAmVaChupAnh() async {
    if (!_isRecording) return; // Tránh gọi 2 lần
    if (!mounted) return;

    try {
      print("3. Dừng ghi âm...");
      final path = await _audioRecorder.stop();
      await rungNhe();

      if (mounted) {
        setState(() {
          _isRecording = false;
          _isProcessing = true;
          trangThai = "ĐANG SUY NGHĨ...";
        });
      }

      // Chụp ảnh
      if (_cameraController != null && _cameraController!.value.isInitialized) {
        final XFile photo = await _cameraController!.takePicture();
        print("4. Đã chụp ảnh");

        if (mounted) {
          setState(() => _imageFile = File(photo.path));
        }

        _disposeCamera(); // Tắt cam ngay để tiết kiệm pin

        // Gửi lên server
        if (path != null) {
          await guiDuLieuDaPhuongTien(File(path), File(photo.path));
        } else {
          print("File ghi âm bị null");
          _resetHeThongDeLangNgheTiep();
        }
      } else {
        print("Camera chưa sẵn sàng");
        _disposeCamera();
        _resetHeThongDeLangNgheTiep();
      }
    } catch (e) {
      print("Lỗi quy trình dừng: $e");
      _disposeCamera();
      _resetHeThongDeLangNgheTiep();
    }
  }

  // --- HÀM RESET HỆ THỐNG ---
  void _resetHeThongDeLangNgheTiep() {
    print("--- RESET: LẮNG NGHE LẠI ---");
    if (mounted) {
      setState(() {
        _isProcessing = false;
        _isRecording = false;
        trangThai = "SẴN SÀNG! NÓI 'HEY LINDA'";
      });
    }
    // Chỉ bật lại Wake Word khi không bận
    _startWakeWordListener();
  }

  Future<void> guiDuLieuDaPhuongTien(File audio, File image) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse(serverUrl));

      request.files.add(
        await http.MultipartFile.fromPath('audio_file', audio.path),
      );
      request.files.add(
        await http.MultipartFile.fromPath('image_file', image.path),
      );

      print("5. Đang gửi server...");
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        String aiResponse = data['reply'] ?? "";

        if (mounted) {
          setState(() {
            trangThai = "ĐANG TRẢ LỜI...";
            cauTraLoiCuaLinda = aiResponse;
            _isProcessing = false;
          });
        }

        // Lưu Log
        luuLichSuVaoFirestore("Audio Command", aiResponse);

        // Phát âm thanh trả lời
        if (data['audio_response'] != null) {
          await phatAmThanhVaCho(data['audio_response']);
        } else {
          // Nếu server không trả về audio thì chờ 3s rồi reset
          Future.delayed(
            const Duration(seconds: 3),
            _resetHeThongDeLangNgheTiep,
          );
        }
      } else {
        if (mounted)
          setState(() => trangThai = "Lỗi Server: ${response.statusCode}");
        Future.delayed(const Duration(seconds: 2), _resetHeThongDeLangNgheTiep);
      }
    } catch (e) {
      print("Lỗi kết nối Server: $e");
      if (mounted) setState(() => trangThai = "Mất kết nối Server");
      Future.delayed(const Duration(seconds: 2), _resetHeThongDeLangNgheTiep);
    }
  }

  Future<void> luuLichSuVaoFirestore(String cauHoi, String traLoi) async {
    try {
      await FirebaseFirestore.instance.collection('activity_logs').add({
        'timestamp': FieldValue.serverTimestamp(),
        'user_query': cauHoi,
        'ai_response': traLoi,
        'device_type': Platform.isAndroid ? 'Android' : 'iOS',
        'status': 'success',
      });
    } catch (e) {
      print("Lỗi lưu log Firebase: $e");
    }
  }

  Future<void> rungNhe() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 100);
    }
  }

  // Hàm phát âm thanh trả lời cũng cần cơ chế Wait
  Future<void> phatAmThanhVaCho(String base64String) async {
    try {
      Uint8List audioBytes = base64Decode(base64String);
      final dir = await getTemporaryDirectory();
      File file = File('${dir.path}/reply.mp3');
      await file.writeAsBytes(audioBytes);

      final completer = Completer<void>();

      await _audioPlayer.play(DeviceFileSource(file.path));

      // Lắng nghe khi phát xong
      StreamSubscription? sub;
      sub = _audioPlayer.onPlayerComplete.listen((_) {
        if (!completer.isCompleted) completer.complete();
        sub?.cancel();
      });

      await completer.future; // Chờ Linda nói xong

      // Nói xong mới Reset để nghe lệnh tiếp theo
      _resetHeThongDeLangNgheTiep();
    } catch (e) {
      print("Lỗi phát reply: $e");
      _resetHeThongDeLangNgheTiep();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        backgroundColor: _isRecording ? Colors.red : Colors.blueGrey,
        onPressed: () {
          // Cho phép kích hoạt bằng nút bấm thủ công
          if (!_isRecording && !_isProcessing) {
            _wakeWordCallback(0); // Giả lập như nghe thấy từ khóa
          }
        },
        child: Icon(_isRecording ? Icons.stop : Icons.mic),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,

      body: Container(
        color: Colors.black,
        child: Column(
          children: [
            // Preview Camera ẩn (1x1 pixel)
            SizedBox(
              width: 1,
              height: 1,
              child:
                  (_cameraController != null &&
                      _cameraController!.value.isInitialized)
                  ? CameraPreview(_cameraController!)
                  : Container(),
            ),

            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  // Thêm scroll để không bị lỗi overflow khi text dài
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_imageFile != null)
                        Container(
                          height: 200,
                          width: 200,
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(13),
                            child: Image.file(_imageFile!, fit: BoxFit.cover),
                          ),
                        ),

                      Icon(
                        _isRecording
                            ? Icons.mic
                            : (_isProcessing ? Icons.sync : Icons.hearing),
                        size: 100,
                        color: _isRecording
                            ? Colors.redAccent
                            : (_isProcessing
                                  ? Colors.blueAccent
                                  : Colors.greenAccent),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        trangThai,
                        style: TextStyle(
                          color: _isRecording ? Colors.red : Colors.greenAccent,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          cauTraLoiCuaLinda,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
