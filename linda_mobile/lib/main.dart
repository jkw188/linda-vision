import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
// --- THƯ VIỆN DATABASE (MỚI) ---
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> main() async {
  // Đảm bảo Flutter khởi tạo xong trước khi gọi Firebase
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Khởi tạo kết nối Database
    await Firebase.initializeApp();
    print("Kết nối Firebase thành công!");
  } catch (e) {
    print(
      "Cảnh báo: Chưa cấu hình Firebase (google-services.json). App sẽ chạy chế độ Offline Log.",
    );
    print("Lỗi chi tiết: $e");
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
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.black,
        primarySwatch: Colors.yellow,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const LindaSmartChat(),
    );
  }
}

class LindaSmartChat extends StatefulWidget {
  const LindaSmartChat({super.key});

  @override
  State<LindaSmartChat> createState() => _LindaSmartChatState();
}

class _LindaSmartChatState extends State<LindaSmartChat> {
  // Trạng thái hệ thống
  String trangThai = "CHẠM & GIỮ ĐỂ HỎI";
  String cauTraLoiCuaLinda = "";

  // Công cụ
  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();

  // Biến lưu file & Trạng thái
  String? _audioPath;
  File? _imageFile;
  bool _isRecording = false;
  bool _isProcessing = false;

  // Cấu hình URL Server
  String get serverUrl {
    String baseUrl = kIsWeb ? "http://127.0.0.1:8000" : "http://10.0.2.2:8000";
    return "$baseUrl/chat-multimodal";
  }

  @override
  void initState() {
    super.initState();
    _xinQuyenTruyCap();
  }

  Future<void> _xinQuyenTruyCap() async {
    await [Permission.microphone, Permission.camera].request();
  }

  Future<void> rungNhe() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 100);
    }
  }

  Future<void> rungDai() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 500);
    }
  }

  Future<void> phatAmThanh(String base64String) async {
    try {
      Uint8List audioBytes = base64Decode(base64String);
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/linda_reply.mp3';
      File file = File(filePath);
      await file.writeAsBytes(audioBytes);
      await _audioPlayer.play(DeviceFileSource(filePath));
    } catch (e) {
      print("Lỗi phát âm thanh: $e");
    }
  }

  // --- HÀM LƯU DATABASE (MỚI) ---
  Future<void> luuLichSuVaoFirestore(String cauHoi, String traLoi) async {
    try {
      // Tạo một document mới trong collection 'activity_logs'
      await FirebaseFirestore.instance.collection('activity_logs').add({
        'timestamp': FieldValue.serverTimestamp(), // Thời gian server
        'user_query': cauHoi, // Người dùng nói gì
        'ai_response': traLoi, // AI trả lời gì
        'device_type': Platform.isAndroid ? 'Android' : 'iOS',
        'status': 'success',
      });
      print("Đã lưu lịch sử vào Firestore!");
    } catch (e) {
      print("Không thể lưu log (Có thể do chưa setup Firebase): $e");
    }
  }

  Future<void> batDauGhiAm() async {
    if (_isProcessing) return;

    await rungNhe();

    try {
      if (await _audioRecorder.hasPermission()) {
        final directory = await getTemporaryDirectory();
        String path = '${directory.path}/lenh_cua_toi.m4a';

        const config = RecordConfig(encoder: AudioEncoder.aacLc);
        await _audioRecorder.start(config, path: path);

        setState(() {
          _isRecording = true;
          trangThai = "ĐANG NGHE...";
          cauTraLoiCuaLinda = "";
        });
      }
    } catch (e) {
      print("Lỗi ghi âm: $e");
    }
  }

  Future<void> dungGhiAmVaGui() async {
    if (!_isRecording) return;

    await rungNhe();

    final path = await _audioRecorder.stop();

    setState(() {
      _isRecording = false;
      _isProcessing = true;
      _audioPath = path;
      trangThai = "ĐANG QUAN SÁT...";
    });

    if (path == null) {
      setState(() => _isProcessing = false);
      return;
    }

    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 50,
        preferredCameraDevice: CameraDevice.rear,
      );

      if (photo != null) {
        setState(() {
          _imageFile = File(photo.path);
          trangThai = "ĐANG SUY NGHĨ...";
        });
        await guiDuLieuDaPhuongTien(File(path), File(photo.path));
      } else {
        setState(() {
          trangThai = "Chưa chụp được ảnh";
          _isProcessing = false;
        });
      }
    } catch (e) {
      setState(() {
        trangThai = "Lỗi Camera: $e";
        _isProcessing = false;
      });
    }
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

        String textUser = data['user_text'] ?? "";
        String textAI = data['reply'] ?? "";

        setState(() {
          trangThai = "HOÀN TẤT";
          cauTraLoiCuaLinda = textAI;
          _isProcessing = false;
        });

        // --- GỌI HÀM LƯU DATABASE ---
        luuLichSuVaoFirestore(textUser, textAI);

        await rungDai();

        if (data['audio_response'] != null &&
            data['audio_response'].toString().isNotEmpty) {
          await phatAmThanh(data['audio_response']);
        }
      } else {
        setState(() {
          trangThai = "LỖI SERVER: ${response.statusCode}";
          _isProcessing = false;
        });
      }
    } catch (e) {
      setState(() {
        trangThai = "MẤT KẾT NỐI";
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        onLongPress: batDauGhiAm,
        onLongPressUp: dungGhiAmVaGui,
        child: Container(
          width: double.infinity,
          height: double.infinity,
          color: Colors.black,
          child: Column(
            children: [
              Expanded(
                flex: 4,
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _isRecording
                          ? Colors.redAccent
                          : Colors.yellowAccent,
                      width: 4,
                    ),
                  ),
                  child: _imageFile != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.file(_imageFile!, fit: BoxFit.cover),
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.visibility,
                              size: 80,
                              color: _isRecording
                                  ? Colors.redAccent
                                  : Colors.yellowAccent,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _isRecording
                                  ? "ĐANG GHI ÂM..."
                                  : "CAMERA SẴN SÀNG",
                              style: const TextStyle(
                                color: Colors.white54,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                ),
              ),

              Expanded(
                flex: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  width: double.infinity,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        trangThai.toUpperCase(),
                        style: TextStyle(
                          color: _isRecording
                              ? Colors.redAccent
                              : Colors.yellowAccent,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 20),

                      Expanded(
                        child: SingleChildScrollView(
                          child: Text(
                            cauTraLoiCuaLinda.isEmpty
                                ? "Nhấn giữ màn hình để hỏi..."
                                : cauTraLoiCuaLinda,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      const Text(
                        "Giao diện hỗ trợ người khiếm thị",
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
