import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:audioplayers/audioplayers.dart';

class PotholeDetectionScreen extends StatefulWidget {
  const PotholeDetectionScreen({super.key});

  @override
  State<PotholeDetectionScreen> createState() => _PotholeDetectionScreenState();
}

class _PotholeDetectionScreenState extends State<PotholeDetectionScreen> {
  CameraController? _cameraController;
  bool _isDetecting = false;
  late Position _currentPosition;
  late StreamSubscription<AccelerometerEvent> _accelerometerSubscription;
  
  final double _impactThreshold = 40.0; 
  //But : différencier les vrais chocs des simples vibrations normales.
  final double _vibrationThreshold = 10;
  // But : capter non seulement les gros chocs, mais aussi les dégradations continues de la route.
  final int _impactDurationMs = 100;
   // But : filtrer les événements trop longs pour être de vrais "chocs".
  final int _cooldownDurationMs = 2000;
   //But : éviter d'enregistrer plusieurs fois le même nid-de-poule ou les vibrations tout de suite après un choc.
  
  DateTime _lastDetectionTime = DateTime.now();
  List<double> _accelHistory = [];
  final int _historySize = 10;
  double _noLevel = 0.0;

  AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _getCurrentPosition();
    _startAccelerometerMonitoring();
    _calibrateSensors();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere((cam) => cam.lensDirection == CameraLensDirection.back);
      _cameraController = CameraController(camera, ResolutionPreset.medium);
      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      print("Erreur d'initialisation de la caméra: $e");
    }
  }

  Future<void> _calibrateSensors() async {
    // Calibration pendant 1 seconde pour déterminer le niveau de bruit
    await Future.delayed(Duration(seconds: 1));
    if (_accelHistory.isNotEmpty) {
      _noLevel = _accelHistory.reduce((a, b) => a + b) / _accelHistory.length;
      print("Niveau de bruit calibré: $_noLevel");
    }
  }

  Future<void> _getCurrentPosition() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await Geolocator.openLocationSettings();
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return;
      }
      Position position = await Geolocator.getCurrentPosition();
      setState(() {
        _currentPosition = position;
      });
    } catch (e) {
      print("Erreur de géolocalisation: $e");
    }
  }

  void _startAccelerometerMonitoring() {
    _accelerometerSubscription = accelerometerEvents.listen((AccelerometerEvent event) async {
      // Calcul de l'accélération totale
      double acceleration = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      
      // Mise à jour de l'historique
      _updateAccelHistory(acceleration);
      
      // Calcul de l'accélération nette (sans le bruit de fond)
      double netAcceleration = acceleration - _noLevel;
      
      // Détection d'impact (mouvement brusque et court)
      if (netAcceleration > _impactThreshold && 
          !_isDetecting && 
          DateTime.now().difference(_lastDetectionTime).inMilliseconds > _cooldownDurationMs) {
        
        _handleImpactDetection();
      }
      
      // Détection de vibrations continues (optionnelle)
      if (_calculateVibrationLevel() > _vibrationThreshold && 
          !_isDetecting &&
          DateTime.now().difference(_lastDetectionTime).inMilliseconds > _cooldownDurationMs) {
        
        _handleVibrationDetection();
      }
    });
  }

  void _updateAccelHistory(double acceleration) {
    _accelHistory.add(acceleration);
    if (_accelHistory.length > _historySize) {
      _accelHistory.removeAt(0);
    }
  }

  double _calculateVibrationLevel() {
    if (_accelHistory.length < 2) return 0.0;
    
    double sum = 0.0;
    for (int i = 1; i < _accelHistory.length; i++) {
      sum += (_accelHistory[i] - _accelHistory[i-1]).abs();
    }
    return sum / (_accelHistory.length - 1);
  }

  Future<void> _handleImpactDetection() async {
  setState(() {
    _isDetecting = true;
  });
  _lastDetectionTime = DateTime.now();
  
  print("💥 Impact détecté !");
  await _playDetectionSound();
  
  // Attendre un court instant pour stabiliser
  await Future.delayed(Duration(milliseconds: 200));
  
  try {
    final imagePath = await _takePicture();
    final imageUrl = await _uploadImageToDjango(imagePath);
    await _sendToFirebase(_currentPosition.latitude, _currentPosition.longitude, imageUrl);
  } catch (e) {
    print("Erreur lors de la détection: $e");
  } finally {
    setState(() {
      _isDetecting = false;
    });
  }
}

  Future<void> _handleVibrationDetection() async {
  setState(() {
    _isDetecting = true;
  });
  _lastDetectionTime = DateTime.now();
  
  print("🔊 Vibration prolongée détectée !");
  await _playDetectionSound();
  
  // Attendre un peu plus longtemps pour les vibrations continues
  await Future.delayed(Duration(milliseconds: 500));
  
  try {
    final imagePath = await _takePicture();
    final imageUrl = await _uploadImageToDjango(imagePath);
    await _sendToFirebase(_currentPosition.latitude, _currentPosition.longitude, imageUrl);
  } catch (e) {
    print("Erreur lors de la détection: $e");
  } finally {
    setState(() {
      _isDetecting = false;
    });
  }
}


  Future<void> _playDetectionSound() async {
    try {
      await _audioPlayer.play(AssetSource('mixkit-classic-alarm-995.mp3'));
    } catch (e) {
      print("Erreur lors de la lecture du son: $e");
    }
  }

  Future<String> _takePicture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      throw Exception("La caméra n'est pas prête");
    }
    final image = await _cameraController!.takePicture();
    final file = File(image.path);
    final directory = await getTemporaryDirectory();
    final imagePath = '${directory.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
    await file.copy(imagePath);
    return imagePath;
  }

  Future<String> _uploadImageToDjango(String imagePath) async {
    final uri = Uri.parse('http://192.168.1.19:8000/api/upload/');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(await http.MultipartFile.fromPath('photo', imagePath));

    final response = await request.send();
    if (response.statusCode == 200) {
      final responseBody = await response.stream.bytesToString();
      final Map<String, dynamic> data = jsonDecode(responseBody);
      return data['url'];
    } else {
      throw Exception('Échec de l\'upload de la photo');
    }
  }

  Future<void> _sendToFirebase(double lat, double lon, String imageUrl) async {
    try {
      await FirebaseFirestore.instance.collection('potholes').add({
        'latitude': lat,
        'longitude': lon,
        'imageUrl': imageUrl,
        'timestamp': Timestamp.now(),
        
      });
      print("📍 Nid-de-poule enregistré à ($lat, $lon) avec photo !");
    } catch (e) {
      print("Erreur Firebase: $e");
    }
  }

 @override
Widget build(BuildContext context) {
  if (_cameraController == null || !_cameraController!.value.isInitialized) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: CircularProgressIndicator()),
    );
  }

  return Scaffold(
    body: Stack(
      children: [
        
        Positioned.fill(child: CameraPreview(_cameraController!)),
        
        // Overlay semi-transparent
        // Positioned.fill(
        //   child: Container(
        //     color: Colors.black.withOpacity(_isDetecting ? 0.4 : 0.2),
        //   ),
        // ),

        // Top bar
        Positioned(
          top: MediaQuery.of(context).padding.top + 16,
          left: 16,
          right: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _isDetecting ? "DÉTECTION EN COURS" : "Surveillance active",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              AnimatedContainer(
                duration: Duration(milliseconds: 300),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: _isDetecting ? Colors.red : Colors.green,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _isDetecting ? Colors.red.withOpacity(0.8) : Colors.green.withOpacity(0.8),
                      blurRadius: 8,
                      spreadRadius: 2,
                    )
                  ],
                ),
              ),
            ],
          ),
        ),

        // Detection info
        Positioned(
          bottom: 32,
          left: 16,
          right: 16,
          child: AnimatedContainer(
            duration: Duration(milliseconds: 300),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              // ignore: deprecated_member_use
              color: _isDetecting ? Colors.red.withOpacity(0.7) : Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isDetecting ? Icons.warning_amber : Icons.check_circle,
                  color: Colors.white,
                  size: 36,
                ),
                const SizedBox(height: 10),
                Text(
                  _isDetecting 
                    ? "Nid-de-poule détecté!"
                    : "En attente de détection...",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Dernière détection: ${_lastDetectionTime.difference(DateTime.now()).abs().inSeconds}s",
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}


  @override
  void dispose() {
    _cameraController?.dispose();
    _accelerometerSubscription.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }
}