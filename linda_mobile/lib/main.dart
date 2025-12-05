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

const String PICOVOICE_ACCESS_KEY = "90LGHncAk9HhZ1zv/MauEm6nbhdzB1Pw/0i8ZgCzNJ06387D/kN74Q==";

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    print("Offline Mode");
  }
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
  final AudioPlayer _audioPlayer = AudioPlayer();

  // Camera và Porcupine
  CameraController? _cameraController;
  PorcupineManager? _porcupineManager;

  File? _imageFile;
  bool _isRecording = false;
  bool _isProcessing = false;

  String get serverUrl {
    String baseUrl = kIsWeb ? "http://127.0.0.1:8000" : "http://10.0.2.2:8000";
    return "$baseUrl/chat-multimodal";
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _khoiTaoHeThong();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _porcupineManager?.delete();
    _disposeCamera(); // Đảm bảo tắt cam khi thoát
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // --- QUẢN LÝ CAMERA (BẬT/TẮT) ---
  Future<void> _khoiTaoCamera() async {
    if (_cameras.isEmpty ||
        (_cameraController != null && _cameraController!.value.isInitialized))
      return;

    print("--- ĐANG BẬT CAMERA NGẦM ---");
    _cameraController = CameraController(
      _cameras.first,
      // TỐI ƯU 1: ResolutionPreset.low (320x240)
      // Đây là mức thấp nhất, giúp ảnh nhẹ, gửi nhanh, AI vẫn nhận diện tốt vật thể lớn.
      ResolutionPreset.low,
      enableAudio: false,
    );

    try {
      await _cameraController!.initialize();
      // TỐI ƯU 2: Tắt Flash để tiết kiệm pin & tránh phản sáng
      await _cameraController!.setFlashMode(FlashMode.off);
    } catch (e) {
      print("Lỗi bật Camera: $e");
    }
  }

  Future<void> _disposeCamera() async {
    if (_cameraController != null) {
      print("--- ĐANG TẮT CAMERA ĐỂ TIẾT KIỆM TÀI NGUYÊN ---");
      await _cameraController!.dispose();
      _cameraController = null;
    }
  }

  Future<void> _khoiTaoHeThong() async {
    await [Permission.microphone, Permission.camera].request();
    // Chỉ khởi tạo Porcupine lúc đầu, KHÔNG bật Camera vội
    await _initPorcupine();
  }

  Future<void> _initPorcupine() async {
    try {
      _porcupineManager = await PorcupineManager.fromKeywordPaths(
        PICOVOICE_ACCESS_KEY,
        ["assets/porcupine/hey_linda_android.ppn"],
        _wakeWordCallback,
        modelPath: "assets/porcupine/porcupine_params.pv",
        sensitivities: [1.0],
      );
      await _startWakeWordListener();
      setState(() => trangThai = "SẴN SÀNG! NÓI 'HEY LINDA'");
    } on PorcupineException catch (err) {
      setState(() => trangThai = "Lỗi Porcupine: ${err.message}");
    }
  }

  Future<void> _startWakeWordListener() async {
    try {
      if (_porcupineManager != null) {
        await _porcupineManager!.start();
      }
    } catch (e) {
      print("Lỗi Start Mic: $e");
    }
  }

  Future<void> _stopWakeWordListener() async {
    await _porcupineManager?.stop();
  }

  void _wakeWordCallback(int keywordIndex) async {
    await _stopWakeWordListener();
    print("ĐÃ NGHE THẤY HEY LINDA!");
    await rungNhe();

    // KÍCH HOẠT QUY TRÌNH SONG SONG
    batDauGhiAmVaBatCamera();
  }

  // --- LOGIC TỐI ƯU SONG SONG ---
  Future<void> batDauGhiAmVaBatCamera() async {
    try {
      // 1. BẮT ĐẦU BẬT CAMERA NGAY (Chạy ngầm trong lúc người dùng đang nói)
      // Trên Emulator mất khoảng 1-2s để bật, trên máy thật <1s.
      // Việc này giúp khi nói xong là Camera đã sẵn sàng.
      _khoiTaoCamera();

      // 2. BẮT ĐẦU GHI ÂM
      if (await _audioRecorder.hasPermission()) {
        final directory = await getTemporaryDirectory();
        String path = '${directory.path}/lenh.m4a';
        const config = RecordConfig(encoder: AudioEncoder.aacLc);

        await _audioRecorder.start(config, path: path);

        setState(() {
          _isRecording = true;
          _imageFile = null;
          trangThai = "MỜI BẠN NÓI...";
          cauTraLoiCuaLinda = "";
        });

        // 3. Đợi 4 giây (Người dùng nói câu lệnh)
        Future.delayed(const Duration(seconds: 4), dungGhiAmVaChupAnh);
      }
    } catch (e) {
      print("Lỗi: $e");
      _startWakeWordListener();
    }
  }

  Future<void> dungGhiAmVaChupAnh() async {
    if (!_isRecording) return;

    // 1. Dừng ghi âm
    final path = await _audioRecorder.stop();
    await rungNhe();

    setState(() {
      _isRecording = false;
      _isProcessing = true;
      trangThai = "ĐANG SUY NGHĨ...";
    });

    // 2. CHỤP ẢNH NGAY
    try {
      // Kiểm tra xem Camera đã kịp khởi động xong chưa
      if (_cameraController != null && _cameraController!.value.isInitialized) {
        final XFile photo = await _cameraController!.takePicture();

        // Hiện ảnh lên màn hình cho ngầu (dù người khiếm thị ko thấy)
        setState(() => _imageFile = File(photo.path));

        // 3. TẮT CAMERA NGAY LẬP TỨC (Giải phóng tài nguyên)
        _disposeCamera();

        // 4. Gửi lên Server
        await guiDuLieuDaPhuongTien(File(path!), File(photo.path));
      } else {
        print("Camera khởi động không kịp!");
        // Nếu máy quá lag khởi động ko kịp, ta gửi audio không ảnh hoặc báo lỗi
        _disposeCamera();
        _khoiPhucTrangThaiCho();
      }
    } catch (e) {
      print("Lỗi chụp: $e");
      _disposeCamera();
      _khoiPhucTrangThaiCho();
    }
  }

  void _khoiPhucTrangThaiCho() {
    setState(() {
      _isProcessing = false;
      _isRecording = false;
    });
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

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          trangThai = "ĐANG TRẢ LỜI...";
          cauTraLoiCuaLinda = data['reply'] ?? "";
          _isProcessing = false;
        });
        if (data['audio_response'] != null)
          await phatAmThanh(data['audio_response']);
      } else {
        setState(() => trangThai = "Lỗi Server: ${response.statusCode}");
        _startWakeWordListener();
      }
    } catch (e) {
      setState(() => trangThai = "Mất kết nối Server");
      _startWakeWordListener();
    }
  }

  Future<void> rungNhe() async {
    if (await Vibration.hasVibrator() ?? false)
      Vibration.vibrate(duration: 100);
  }

  Future<void> phatAmThanh(String base64String) async {
    try {
      Uint8List audioBytes = base64Decode(base64String);
      final dir = await getTemporaryDirectory();
      File file = File('${dir.path}/reply.mp3');
      await file.writeAsBytes(audioBytes);
      await _audioPlayer.play(DeviceFileSource(file.path));
      _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted && !_isRecording) _startWakeWordListener();
      });
    } catch (e) {
      _startWakeWordListener();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Vẫn giữ nút bấm khẩn cấp
      floatingActionButton: FloatingActionButton(
        backgroundColor: _isRecording ? Colors.red : Colors.blueGrey,
        onPressed: () {
          if (!_isRecording && !_isProcessing) {
            _stopWakeWordListener();
            batDauGhiAmVaBatCamera();
          }
        },
        child: Icon(_isRecording ? Icons.stop : Icons.mic),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,

      body: Container(
        color: Colors.black,
        child: Column(
          children: [
            // Preview camera 1x1 pixel (Chỉ hiện khi camera đang bật)
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
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_imageFile != null)
                      Container(
                        height: 200,
                        width: 200,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white),
                        ),
                        child: Image.file(_imageFile!, fit: BoxFit.cover),
                      ),

                    Icon(
                      _isRecording ? Icons.mic : Icons.hearing,
                      size: 100,
                      color: _isRecording
                          ? Colors.redAccent
                          : Colors.greenAccent,
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
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        cauTraLoiCuaLinda,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
