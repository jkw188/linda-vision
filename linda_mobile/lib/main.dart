import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// --- WEB ONLY IMPORT (Remove if building for Android/iOS) ---
import 'dart:html' as html;

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// --- CONFIGURATION ---
const String PICOVOICE_ACCESS_KEY = "YOUR_KEY_HERE";

List<CameraDescription> _cameras = [];
bool _isFirebaseReady = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    if (kIsWeb) {
      print("⚠️ WEB MODE: Firebase Logging disabled.");
    } else {
      await Firebase.initializeApp();
      _isFirebaseReady = true;
    }
  } catch (e) {
    print("⚠️ Offline Mode (Firebase Error: $e)");
  }

  // We do NOT init cameras here anymore to prevent startup crash.
  // We moved it to _initSystem inside the UI.

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Linda Vision Web',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyanAccent,
          brightness: Brightness.dark,
        ),
      ),
      home: const LindaWebOptimized(),
    );
  }
}

class LindaWebOptimized extends StatefulWidget {
  const LindaWebOptimized({super.key});

  @override
  State<LindaWebOptimized> createState() => _LindaWebOptimizedState();
}

class _LindaWebOptimizedState extends State<LindaWebOptimized>
    with WidgetsBindingObserver {
  String status = "INITIALIZING...";
  String lindaResponse = "Hello! Click the mic to start.";

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioPlayer _effectPlayer = AudioPlayer();
  CameraController? _cameraController;

  XFile? _imageFile;
  Uint8List? _imageBytes;
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
    _initSystem();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _effectPlayer.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _initSystem() async {
    await _initCameraSafely();
    if (mounted) setState(() => status = "READY");
  }

  // --- SAFE CAMERA INIT FOR WEB ---
  Future<void> _initCameraSafely() async {
    try {
      // 1. Try standard Flutter way first
      _cameras = await availableCameras();
    } catch (e) {
      print("⚠️ Standard Camera Init Failed: $e");
      // 2. Fallback: Use Browser Native API to find valid cameras
      _cameras = await _getBrowserCameras();
    }

    if (_cameras.isEmpty) {
      print("❌ No usable cameras found.");
      return;
    }

    // 3. Try to initialize the first valid camera
    for (var camera in _cameras) {
      try {
        print("📷 Attempting to open: ${camera.name}");
        _cameraController = CameraController(
          camera,
          ResolutionPreset.low, // Lowest resolution is safest for Web
          enableAudio: false,
        );
        await _cameraController!.initialize();
        if (mounted) setState(() {});
        print("✅ Success! Camera opened.");
        return;
      } catch (e) {
        print("⚠️ Failed to open ${camera.name}: $e");
      }
    }
  }

  // Helper: Manually get cameras via dart:html to bypass broken drivers (e.g. OBS)
  Future<List<CameraDescription>> _getBrowserCameras() async {
    List<CameraDescription> webCameras = [];
    try {
      // Access browser media devices directly
      final devices = await html.window.navigator.mediaDevices!
          .enumerateDevices();
      for (var device in devices) {
        if (device.kind == 'videoinput') {
          print("🔎 Found Web Device: ${device.label}");
          // SKIP Virtual Cameras which often cause crashes
          if (device.label!.toLowerCase().contains('virtual') ||
              device.label!.toLowerCase().contains('obs')) {
            print("🚫 Skipping Virtual Camera: ${device.label}");
            continue;
          }

          webCameras.add(
            CameraDescription(
              name: device.label ?? 'Web Camera',
              lensDirection: CameraLensDirection.front,
              sensorOrientation: 0,
            ),
          );
        }
      }
    } catch (e) {
      print("❌ Native Browser enumeration failed: $e");
    }
    return webCameras;
  }

  void startInteraction() async {
    if (_isProcessing || _isRecording) return;
    print("--- STARTING INTERACTION ---");

    setState(() => status = "LISTENING...");
    await _playEffect('sounds/ting.mp3');
    await _startRecordingAndCamera();
  }

  Future<void> _playEffect(String assetPath) async {
    try {
      await _effectPlayer.play(AssetSource(assetPath));
      if (kIsWeb) await Future.delayed(const Duration(milliseconds: 600));
    } catch (e) {
      print("Effect Error: $e");
    }
  }

  Future<void> _startRecordingAndCamera() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        setState(() {
          _isRecording = true;
          _imageFile = null;
          _imageBytes = null;
          status = "SPEAK NOW...";
          lindaResponse = "";
        });

        const config = RecordConfig(encoder: AudioEncoder.opus);
        await _audioRecorder.start(config, path: '');

        Future.delayed(const Duration(milliseconds: 1500), () {
          if (_isRecording) _captureSnapshot();
        });

        Future.delayed(const Duration(seconds: 4), _stopRecordingAndSend);
      }
    } catch (e) {
      print("Recording Error: $e");
      _resetSystem();
    }
  }

  Future<void> _captureSnapshot() async {
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      try {
        print("📸 Taking Snapshot...");
        final XFile photo = await _cameraController!.takePicture().timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException("Camera slow"),
        );

        final bytes = await photo.readAsBytes();
        if (mounted) {
          setState(() {
            _imageFile = photo;
            _imageBytes = bytes;
          });
        }
        print("✅ Snapshot Success");
      } catch (e) {
        print("⚠️ Snapshot Failed: $e");
      }
    } else {
      print("⚠️ Camera not ready. Skipping.");
    }
  }

  Future<void> _stopRecordingAndSend() async {
    if (!_isRecording) return;
    if (!mounted) return;

    try {
      final path = await _audioRecorder.stop();
      print("✅ Recording stopped. Blob URL: $path");

      setState(() {
        _isRecording = false;
        _isProcessing = true;
        status = "THINKING...";
      });

      if (_imageFile == null) await _captureSnapshot();

      if (path != null) {
        await _sendToBackend(path, _imageFile);
      } else {
        setState(() => status = "Error: Audio Failed");
        _resetSystem();
      }
    } catch (e) {
      print("❌ Stop Error: $e");
      _resetSystem();
    }
  }

  Future<void> _sendToBackend(String audioPathOrUrl, XFile? imageFile) async {
    print("--- PREPARING TO SEND ---");
    try {
      var request = http.MultipartRequest('POST', Uri.parse(serverUrl));

      if (kIsWeb) {
        print("Fetching audio blob: $audioPathOrUrl");
        final audioResponse = await http.get(
          Uri.parse(audioPathOrUrl),
          headers: {"Accept": "*/*"},
        );
        request.files.add(
          http.MultipartFile.fromBytes(
            'audio_file',
            audioResponse.bodyBytes,
            filename: 'command.webm',
          ),
        );
      } else {
        request.files.add(
          await http.MultipartFile.fromPath('audio_file', audioPathOrUrl),
        );
      }

      if (imageFile != null) {
        final imageBytes = await imageFile.readAsBytes();
        request.files.add(
          http.MultipartFile.fromBytes(
            'image_file',
            imageBytes,
            filename: 'image.jpg',
          ),
        );
      } else {
        print("⚠️ Sending Audio Only");
      }

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        String textReply = data['reply'] ?? "";

        setState(() {
          status = "REPLYING...";
          lindaResponse = textReply;
          _isProcessing = false;
        });

        if (data['audio_response'] != null &&
            data['audio_response'].isNotEmpty) {
          await _playAuthResponse(data['audio_response']);
        } else {
          Future.delayed(const Duration(seconds: 3), _resetSystem);
        }
      } else {
        setState(() => status = "Server Error: ${response.statusCode}");
        Future.delayed(const Duration(seconds: 3), _resetSystem);
      }
    } catch (e) {
      print("❌ ERROR: $e");
      setState(() => status = "Connection Failed");
      Future.delayed(const Duration(seconds: 3), _resetSystem);
    }
  }

  Future<void> _playAuthResponse(String base64String) async {
    try {
      Uint8List audioBytes = base64Decode(base64String);
      await _audioPlayer.play(BytesSource(audioBytes));

      final completer = Completer<void>();
      StreamSubscription? sub;
      sub = _audioPlayer.onPlayerComplete.listen((_) {
        if (!completer.isCompleted) completer.complete();
        sub?.cancel();
      });

      await completer.future;
      _resetSystem();
    } catch (e) {
      print("Playback Error: $e");
      _resetSystem();
    }
  }

  void _resetSystem() {
    if (mounted) {
      setState(() {
        _isProcessing = false;
        _isRecording = false;
        status = "READY";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            SizedBox(
              width: size.width,
              height: size.height,
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _cameraController!.value.previewSize!.width,
                  height: _cameraController!.value.previewSize!.height,
                  child: CameraPreview(_cameraController!),
                ),
              ),
            )
          else
            Positioned.fill(
              child: Container(
                color: Colors.grey[900],
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.videocam_off,
                      size: 50,
                      color: Colors.white24,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      "No Camera / Audio Only",
                      style: TextStyle(color: Colors.white38),
                    ),
                    if (_cameras.isEmpty)
                      TextButton(
                        onPressed: _initSystem,
                        child: const Text("Retry Camera"),
                      ),
                  ],
                ),
              ),
            ),

          Positioned.fill(
            child: Container(color: Colors.black.withOpacity(0.6)),
          ),

          Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_imageBytes != null)
                    Container(
                      height: 200,
                      width: 200,
                      margin: const EdgeInsets.only(bottom: 30),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.cyanAccent, width: 3),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.memory(_imageBytes!, fit: BoxFit.cover),
                      ),
                    ),

                  Text(
                    status,
                    style: TextStyle(
                      color: _isRecording
                          ? Colors.redAccent
                          : Colors.cyanAccent,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 40),

                  GestureDetector(
                    onTap: startInteraction,
                    child: Container(
                      padding: const EdgeInsets.all(30),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isRecording
                            ? Colors.red
                            : Colors.white.withOpacity(0.1),
                        border: Border.all(
                          color: _isRecording
                              ? Colors.redAccent
                              : Colors.white54,
                          width: 4,
                        ),
                        boxShadow: [
                          if (_isProcessing)
                            BoxShadow(
                              color: Colors.blueAccent.withOpacity(0.5),
                              blurRadius: 40,
                              spreadRadius: 10,
                            ),
                        ],
                      ),
                      child: Icon(
                        _isProcessing
                            ? Icons.sync
                            : (_isRecording ? Icons.stop : Icons.mic),
                        size: 60,
                        color: Colors.white,
                      ),
                    ),
                  ),

                  const SizedBox(height: 40),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      lindaResponse,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
