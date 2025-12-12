// lib/main.dart
//
// FINAL VERSION: Uses the verified 'bluetooth' package.
// The Bluetooth logic has been rewritten to match the new package's API.
//

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:bluetooth/bluetooth.dart'; // The new, verified package
import 'package:bluetooth_classic/bluetooth_classic.dart' as bc; // For device model compatibility
import 'package:fl_chart/fl_chart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(const GradiometerApp());
}

class GradiometerApp extends StatelessWidget {
  const GradiometerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gradiometer Companion (GND)',
      theme: ThemeData.dark(),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum FilterType { none, movingAverage, iirLowPass, median, kalman }

class _HomeScreenState extends State<HomeScreen> {
  // Bluetooth - Using the new 'bluetooth' package
  bool _isBluetoothEnabled = false;
  List<BluetoothDevice> _bondedDevices = [];
  List<BluetoothDiscoveryResult> _discoveredDevices = [];
  BluetoothDevice? _selectedDevice;
  BluetoothConnection? _connection;
  StreamSubscription<Uint8List>? _btSub;
  bool _connected = false;
  StreamSubscription<BluetoothDiscoveryResult>? _discoveryStreamSubscription;

  // Serial buffer
  String _buffer = "";

  // Mode: Type A = 2 sensors; Type B = AD623 single/amplified (or gradient)
  bool _modeA = true;

  // Raw and computed
  double s1 = 0.0;
  double s2 = 0.0;
  double rawGradient = 0.0;
  double filteredValue = 0.0;

  // Filters
  FilterType _filter = FilterType.iirLowPass;
  int _maWindow = 8;
  int _medianWindow = 5;
  double _iirAlpha = 0.12;

  final List<double> _maBuf = [];
  final List<double> _medianBuf = [];

  // Kalman
  double _kalmanX = 0.0;
  double _kalmanP = 1.0;
  double _kalmanQ = 1e-5;
  double _kalmanR = 0.01;

  // IIR state
  double _iirState = 0.0;

  // Graph
  List<FlSpot> points = [];
  int _xIndex = 0;
  int maxPoints = 240;

  // Alerts
  double posThreshold = 20.0;
  double negThreshold = -20.0;
  bool beepOnAlert = true;
  bool vibrateOnAlert = true;
  final AudioPlayer _player = AudioPlayer();

  // Logging
  bool logging = false;
  List<List<dynamic>> csvRows = [
    ['timestamp', 's1', 's2', 'raw', 'filtered']
  ];

  // Auto-zero
  double zeroOffset = 0.0;
  bool continuousDriftCancel = false;

  // Scan grid
  bool scanMode = false;
  int gridWidth = 8;
  int gridHeight = 6;
  double gridSpacingCm = 20.0;
  int scanX = 0, scanY = 0;
  List<double> gridValues = []; // flattened row-major width*height
  List<Map<String, dynamic>> scanPoints = [];

  // File storage
  Directory? appDir;

  SharedPreferences? prefs;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    appDir = await getApplicationDocumentsDirectory();
    prefs = await SharedPreferences.getInstance();
    _loadPrefs();
    _initBluetooth();
    setState(() {});
  }

  Future<void> _initBluetooth() async {
    // Check if Bluetooth is available and enabled
    _isBluetoothEnabled = await Bluetooth.isEnabled;
    if (!_isBluetoothEnabled) {
      // Optionally, ask the user to enable it
      // _showSnack("Please enable Bluetooth.");
    }
    // Get bonded devices
    _bondedDevices = await Bluetooth.getBondedDevices();
    setState(() {});
  }

  void _startDiscovery() {
    _discoveredDevices.clear();
    _discoveryStreamSubscription = Bluetooth.startDiscovery().listen((result) {
      if (!_discoveredDevices.any((d) => d.device?.address == result.device?.address)) {
        setState(() {
          _discoveredDevices.add(result);
        });
      }
    });
    // Stop discovery after 5 seconds
    Timer(const Duration(seconds: 5), () {
      _discoveryStreamSubscription?.cancel();
    });
  }

  void _loadPrefs() {
    _modeA = prefs?.getBool('modeA') ?? true;
    _filter = FilterType.values[prefs?.getInt('filter') ?? 1];
    _maWindow = prefs?.getInt('maWindow') ?? 8;
    _medianWindow = prefs?.getInt('medianWindow') ?? 5;
    _iirAlpha = prefs?.getDouble('iirAlpha') ?? 0.12;
    posThreshold = prefs?.getDouble('posThreshold') ?? 20.0;
    negThreshold = prefs?.getDouble('negThreshold') ?? -20.0;
    beepOnAlert = prefs?.getBool('beepOnAlert') ?? true;
    vibrateOnAlert = prefs?.getBool('vibrateOnAlert') ?? true;
    maxPoints = prefs?.getInt('maxPoints') ?? 240;
  }

  Future<void> _savePrefs() async {
    await prefs?.setBool('modeA', _modeA);
    await prefs?.setInt('filter', _filter.index);
    await prefs?.setInt('maWindow', _maWindow);
    await prefs?.setInt('medianWindow', _medianWindow);
    await prefs?.setDouble('iirAlpha', _iirAlpha);
    await prefs?.setDouble('posThreshold', posThreshold);
    await prefs?.setDouble('negThreshold', negThreshold);
    await prefs?.setBool('beepOnAlert', beepOnAlert);
    await prefs?.setBool('vibrateOnAlert', vibrateOnAlert);
    await prefs?.setInt('maxPoints', maxPoints);
  }

  Future<void> connectTo(BluetoothDevice device) async {
    try {
      await _connection?.close();
    } catch (_) {}
    try {
      BluetoothConnection conn = await Bluetooth.connect(device.address);
      _connection = conn;
      _connected = true;
      _selectedDevice = device;
      setState(() {});
      _btSub = conn.input?.listen(_onData, onDone: () {
        _connected = false;
        setState(() {});
      }, onError: (_) {
        _connected = false;
        setState(() {});
      });
    } catch (e) {
      _showSnack("Connection failed: $e");
    }
  }

  void _onData(Uint8List raw) {
    String chunk = utf8.decode(raw);
    _buffer += chunk;
    if (_buffer.contains('\n')) {
      List<String> lines = _buffer.split('\n');
      _buffer = lines.last;
      for (int i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.isNotEmpty) _processLine(line);
      }
    }
  }

  void _processLine(String line) {
    final clean = line.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    double p1 = 0.0;
    double p2 = 0.0;
    try {
      if (clean.contains(',')) {
        final parts = clean.split(',');
        if (parts.length >= 2) {
          p1 = _numFromString(parts[0]);
          p2 = _numFromString(parts[1]);
        } else {
          p1 = _numFromString(parts[0]);
        }
      } else if (clean.contains(':')) {
        final parts = clean.split(',');
        for (var pr in parts) {
          if (pr.contains(':')) {
            final kv = pr.split(':');
            final key = kv[0].trim().toLowerCase();
            final val = _numFromString(kv[1]);
            if (key.contains('1')) p1 = val;
            if (key.contains('2')) p2 = val;
          }
        }
      } else {
        p1 = _numFromString(clean);
      }
    } catch (_) { return; }

    setState(() {
      if (_modeA) {
        s1 = p1;
        s2 = p2;
      } else {
        s1 = p1;
        s2 = 0.0;
      }
      rawGradient = _modeA ? (s1 - s2) : s1;
      if (continuousDriftCancel) rawGradient -= zeroOffset;
      filteredValue = _applyFilter(rawGradient);
      points.add(FlSpot(_xIndex.toDouble(), filteredValue));
      _xIndex++;
      if (points.length > maxPoints) points.removeAt(0);
      if (logging) {
        csvRows.add([DateTime.now().toIso8601String(), s1.toStringAsFixed(6), s2.toStringAsFixed(6), rawGradient.toStringAsFixed(6), filteredValue.toStringAsFixed(6)]);
      }
      if (scanMode) _recordScanPointAuto();
      _maybeAlert(filteredValue);
    });
  }

  double _numFromString(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^0-9\.\-]'), '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  double _applyFilter(double v) {
    switch (_filter) {
      case FilterType.none: return v;
      case FilterType.movingAverage:
        _maBuf.add(v);
        if (_maBuf.length > _maWindow) _maBuf.removeAt(0);
        return _maBuf.reduce((a, b) => a + b) / _maBuf.length;
      case FilterType.median:
        _medianBuf.add(v);
        if (_medianBuf.length > _medianWindow) _medianBuf.removeAt(0);
        final copy = List<double>.from(_medianBuf)..sort();
        return copy[copy.length ~/ 2];
      case FilterType.kalman:
        double predX = _kalmanX;
        double predP = _kalmanP + _kalmanQ;
        double K = predP / (predP + _kalmanR);
        _kalmanX = predX + K * (v - predX);
        _kalmanP = (1 - K) * predP;
        return _kalmanX;
      case FilterType.iirLowPass:
      default:
        if (_iirState == 0.0) _iirState = v;
        _iirState = _iirState + _iirAlpha * (v - _iirState);
        return _iirState;
    }
  }

  void _maybeAlert(double v) {
    if (v > posThreshold || v < negThreshold) {
      if (vibrateOnAlert) Vibration.vibrate(duration: 120);
      if (beepOnAlert) _playBeep();
    }
  }

  Future<void> _playBeep() async {
    try {
      await _player.play(UrlSource('https://actions.google.com/sounds/v1/alarms/beep_short.ogg'));
    } catch (_) {}
  }

  void _toggleLogging() {
    setState(() {
      logging = !logging;
      if (logging) {
        csvRows = [['timestamp', 's1', 's2', 'raw', 'filtered']];
        _showSnack('Logging started');
      } else {
        _showSnack('Logging stopped');
      }
    });
  }

  Future<String> _saveCsv() async {
    final csv = const ListToCsvConverter().convert(csvRows);
    final name = 'gradiolog_${DateTime.now().millisecondsSinceEpoch}.csv';
    final file = File('${appDir!.path}/$name');
    await file.writeAsString(csv);
    return file.path;
  }

  Future<void> _exportCsv() async {
    if (csvRows.length <= 1) { _showSnack('No logged data to export.'); return; }
    final path = await _saveCsv();
    await Share.shareFiles([path], text: 'Gradiometer Log');
  }

  void _autoZero() {
    setState(() {
      zeroOffset = rawGradient;
      _showSnack('Auto-zero = ${zeroOffset.toStringAsFixed(4)}');
    });
  }

  void _startNewGrid() {
    setState(() {
      gridValues = List<double>.filled(gridWidth * gridHeight, 0.0);
      scanX = 0; scanY = 0; scanPoints = [];
      _showSnack('New grid started (${gridWidth}×${gridHeight})');
    });
  }

  void _recordScanPointManual() {
    final idx = scanY * gridWidth + scanX;
    if (idx >= 0 && idx < gridValues.length) {
      gridValues[idx] = filteredValue;
      scanPoints.add({'x': scanX, 'y': scanY, 'value': filteredValue});
      scanX++;
      if (scanX >= gridWidth) { scanX = 0; scanY++; }
      setState(() {});
    }
  }

  void _recordScanPointAuto() {
    if ((_xIndex % 6) == 0) _recordScanPointManual();
  }

  Future<String> _saveGndFile({String? fileName}) async {
    final meta = {
      'width': gridWidth, 'height': gridHeight, 'spacing_cm': gridSpacingCm,
      'mode': _modeA ? 'A' : 'B', 'iir_alpha': _iirAlpha,
      'filter': _filter.toString().split('.').last,
      'timestamp': DateTime.now().toIso8601String(),
    };
    final body = { 'meta': meta, 'values': gridValues, };
    final txt = const JsonEncoder.withIndent('  ').convert(body);
    final name = fileName ?? 'scan_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.gnd';
    final file = File('${appDir!.path}/$name');
    await file.writeAsString(txt);
    return file.path;
  }

  Future<List<String>> _listGndFiles() async {
    return Directory(appDir!.path)
        .listSync().whereType<File>()
        .where((f) => f.path.endsWith('.gnd'))
        .map((f) => f.path.split('/').last).toList();
  }

  Future<void> _loadGndFile(String fileName) async {
    final file = File('${appDir!.path}/$fileName');
    if (!file.existsSync()) { _showSnack('File not found'); return; }
    final txt = await file.readAsString();
    final decoded = json.decode(txt);
    final meta = decoded['meta'];
    final values = (decoded['values'] as List).map((e) => (e as num).toDouble()).toList();
    setState(() {
      gridWidth = meta['width'] ?? gridWidth;
      gridHeight = meta['height'] ?? gridHeight;
      gridSpacingCm = (meta['spacing_cm'] ?? gridSpacingCm).toDouble();
      _modeA = (meta['mode'] ?? (_modeA ? 'A' : 'B')) == 'A';
      gridValues = values;
    });
    _showSnack('Loaded $fileName (${gridWidth}×${gridHeight})');
  }

  Future<void> _exportGndAsCsvAndShare() async {
    if (gridValues.isEmpty) { _showSnack('No grid to export.'); return; }
    final rows = [['x','y','value']];
    for (int y=0;y<gridHeight;y++){
      for (int x=0;x<gridWidth;x++){
        final idx = y*gridWidth + x;
        rows.add([x,y,gridValues[idx]]);
      }
    }
    final csv = const ListToCsvConverter().convert(rows);
    final file = File('${appDir!.path}/grid_${DateTime.now().millisecondsSinceEpoch}.csv');
    await file.writeAsString(csv);
    await Share.shareFiles([file.path], text: 'Grid CSV');
  }

  Widget _buildHeatmapPreview() {
    if (gridValues.isEmpty) return const Center(child: Text('No grid recorded'));
    final minVal = gridValues.reduce(min);
    final maxVal = gridValues.reduce(max);
    return AspectRatio(
      aspectRatio: gridWidth / gridHeight,
      child: Container(
        padding: const EdgeInsets.all(6),
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: gridWidth),
          itemCount: gridWidth * gridHeight,
          itemBuilder: (context, idx) {
            final v = gridValues[idx];
            final t = (v - minVal) / max(0.0001, (maxVal - minVal));
            final color = _colorRamp(t);
            final x = idx % gridWidth; final y = idx ~/ gridWidth;
            return GestureDetector(
              onTap: () => _showSnack('($x,$y) = ${v.toStringAsFixed(3)}'),
              child: Container(
                margin: const EdgeInsets.all(1), color: color,
                child: Center(child: Text(v.toStringAsFixed(1), style: const TextStyle(fontSize: 10, color: Colors.white))),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPseudo3DPreview() {
    if (gridValues.isEmpty) return const SizedBox.shrink();
    final minVal = gridValues.reduce(min);
    final maxVal = gridValues.reduce(max);
    return SizedBox(
      height: 180,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: gridWidth,
        itemBuilder: (context, col) {
          return Column(
            children: List.generate(gridHeight, (row) {
              final idx = row * gridWidth + col;
              final v = gridValues[idx];
              final norm = (v - minVal) / max(0.0001, (maxVal - minVal));
              final h = 150 * norm;
              return Container(
                margin: const EdgeInsets.all(2), width: 16, height: 24,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(width: 16, height: max(2.0, h), color: _colorRamp(norm)),
                ),
              );
            }),
          );
        },
      ),
    );
  }

  Color _colorRamp(double t) {
    t = t.clamp(0.0, 1.0);
    if (t < 0.25) { return Color.lerp(Colors.blue, Colors.green, t / 0.25)!; }
    if (t < 0.6) { return Color.lerp(Colors.green, Colors.yellow, (t - 0.25) / 0.35)!; }
    return Color.lerp(Colors.yellow, Colors.red, (t - 0.6) / 0.4)!;
  }

  void _showSnack(String s) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _listAndLoadGndDialog() async {
    final files = await _listGndFiles();
    if (files.isEmpty) { _showSnack('No .gnd files found in ${appDir!.path}'); return; }
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Load .gnd file'),
      content: SizedBox(width: double.maxFinite, child: ListView.builder(
        shrinkWrap: true,
        itemCount: files.length,
        itemBuilder: (c, i) {
          final f = files[i];
          return ListTile(
            title: Text(f),
            trailing: IconButton(icon: const Icon(Icons.file_download), onPressed: () async {
              Navigator.of(ctx).pop(); await _loadGndFile(f);
            }),
          );
        },
      )),
    ));
  }

  Future<void> _saveGndDialog() async {
    if (gridValues.isEmpty) { _showSnack('No grid recorded to save.'); return; }
    final path = await _saveGndFile();
    _showSnack('Saved .gnd -> $path');
  }

  @override
  void dispose() {
    _discoveryStreamSubscription?.cancel();
    _btSub?.cancel();
    _connection?.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gradiometer Companion (GND)'), actions: [
        IconButton(icon: const Icon(Icons.save), tooltip: 'Save settings', onPressed: () { _savePrefs(); _showSnack('Settings saved'); },),
        IconButton(icon: const Icon(Icons.folder_open), tooltip: 'Open .gnd', onPressed: _listAndLoadGndDialog,),
      ]),
      body: SafeArea(
        child: Column(children: [
          // Bluetooth + connection
          Card(child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: [
              if (!_isBluetoothEnabled) const Text("Bluetooth is not enabled.", style: TextStyle(color: Colors.red)),
              Row(children: [
                const Text('BT device:'), const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<BluetoothDevice?>(
                    isExpanded: true,
                    value: _selectedDevice,
                    hint: const Text('Select bonded device'),
                    items: _bondedDevices.map((d) => DropdownMenuItem(value: d, child: Text('${d.name ?? "Unknown"} (${d.address})'))).toList(),
                    onChanged: (d) => setState(() => _selectedDevice = d),
                  ),
                ),
                IconButton(icon: const Icon(Icons.search), tooltip: 'Discover new devices', onPressed: _startDiscovery),
                IconButton(icon: const Icon(Icons.refresh), onPressed: _initBluetooth)
              ]),
              // Display discovered devices if any
              if (_discoveredDevices.isNotEmpty)
                SizedBox(
                  height: 100,
                  child: ListView.builder(
                    itemCount: _discoveredDevices.length,
                    itemBuilder: (context, index) {
                      final result = _discoveredDevices[index];
                      return ListTile(
                        title: Text(result.device?.name ?? 'Unknown Device'),
                        subtitle: Text(result.device?.address ?? 'No Address'),
                        onTap: () {
                          if (result.device != null) {
                            setState(() {
                              _selectedDevice = result.device!;
                              _discoveredDevices.clear();
                            });
                          }
                        },
                      );
                    },
                  ),
                ),
              Row(children: [
                ElevatedButton(onPressed: _selectedDevice == null ? null : () => connectTo(_selectedDevice!), child: Text(_connected ? 'Connected' : 'Connect')),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: () { _connection?.close(); _btSub?.cancel(); _connected = false; setState(() {}); }, child: const Text('Disconnect')),
                const SizedBox(width: 8), Text('Mode:'), const SizedBox(width: 6),
                ChoiceChip(label: const Text('A: 2 sensors'), selected: _modeA, onSelected: (v) => setState(() => _modeA = true)),
                const SizedBox(width: 6),
                ChoiceChip(label: const Text('B: 1 value/AD623'), selected: !_modeA, onSelected: (v) => setState(() => _modeA = false))
              ]),
            ]),
          )),
          // ... The rest of your UI code remains the same ...
          // indicators
          Card(child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
            Container(width: 92, height: 92, alignment: Alignment.center, decoration: BoxDecoration(color: _indicatorColor(filteredValue), shape: BoxShape.circle), child: Text(filteredValue.toStringAsFixed(2), style: const TextStyle(fontSize: 18))),
            const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Raw: ${rawGradient.toStringAsFixed(4)}'), Text('s1: ${s1.toStringAsFixed(4)}  s2: ${s2.toStringAsFixed(4)}'),
              Wrap(spacing: 6, children: [ElevatedButton(onPressed: _autoZero, child: const Text('Auto-zero')), ElevatedButton(onPressed: _toggleLogging, child: Text(logging ? 'Stop log' : 'Start log')), ElevatedButton(onPressed: _exportCsv, child: const Text('Export CSV'))])
            ]))
          ]))),
          // Graph
          Expanded(child: Padding(padding: const EdgeInsets.all(6), child: Card(child: Padding(padding: const EdgeInsets.all(8), child: Column(children: [
            Expanded(child: LineChart(LineChartData(titlesData: FlTitlesData(show: false), gridData: FlGridData(show: true), borderData: FlBorderData(show: false), lineBarsData: [LineChartBarData(spots: points, isCurved: true, dotData: FlDotData(show: false), color: Colors.lightGreenAccent, barWidth: 2)]))),
            Row(children: [const Text('Filter:'), const SizedBox(width: 8), DropdownButton<FilterType>(value: _filter, items: FilterType.values.map((f) => DropdownMenuItem(value: f, child: Text(f.toString().split('.').last))).toList(), onChanged: (v) => setState(() => _filter = v!)),
              if (_filter == FilterType.movingAverage) ...[const SizedBox(width: 12), const Text('MA size'), const SizedBox(width: 6), SizedBox(width: 80, child: TextFormField(initialValue: '$_maWindow', keyboardType: TextInputType.number, onFieldSubmitted: (t){_maWindow = int.tryParse(t) ?? _maWindow;}))],
              if (_filter == FilterType.median) ...[const SizedBox(width: 12), const Text('Median'), const SizedBox(width: 6), SizedBox(width: 80, child: TextFormField(initialValue: '$_medianWindow', keyboardType: TextInputType.number, onFieldSubmitted: (t){_medianWindow = int.tryParse(t) ?? _medianWindow;}))],
              if (_filter == FilterType.iirLowPass) ...[const SizedBox(width: 12), const Text('IIR α'), const SizedBox(width: 6), SizedBox(width: 100, child: TextFormField(initialValue: '$_iirAlpha', keyboardType: TextInputType.number, onFieldSubmitted: (t){_iirAlpha = double.tryParse(t) ?? _iirAlpha;}))]
            ])
          ])))),
          // Scan controls + heatmap preview
          Card(child: Padding(padding: const EdgeInsets.all(8), child: Column(children: [
            Row(children: [const Text('Grid W×H:'), const SizedBox(width: 8), SizedBox(width: 60, child: TextFormField(initialValue: '$gridWidth', keyboardType: TextInputType.number, onFieldSubmitted: (v){ gridWidth = int.tryParse(v) ?? gridWidth; })), const SizedBox(width: 8), SizedBox(width: 60, child: TextFormField(initialValue: '$gridHeight', keyboardType: TextInputType.number, onFieldSubmitted: (v){ gridHeight = int.tryParse(v) ?? gridHeight; })), const SizedBox(width: 12), const Text('Spacing cm'), const SizedBox(width: 6), SizedBox(width: 80, child: TextFormField(initialValue: '$gridSpacingCm', keyboardType: TextInputType.number, onFieldSubmitted: (v){ gridSpacingCm = double.tryParse(v) ?? gridSpacingCm; }))]),
            const SizedBox(height: 8),
            Row(children: [ElevatedButton(onPressed: _startNewGrid, child: const Text('New Grid')), const SizedBox(width: 8), ElevatedButton(onPressed: (){setState(()=>scanMode = !scanMode); _showSnack(scanMode ? 'Scan mode ON (auto record)' : 'Scan mode OFF');}, child: Text(scanMode ? 'Stop Scan' : 'Start Scan')), const SizedBox(width: 8), ElevatedButton(onPressed: _recordScanPointManual, child: const Text('Record Point')), const SizedBox(width: 8), ElevatedButton(onPressed: _saveGndDialog, child: const Text('Save .gnd')), const SizedBox(width: 8), ElevatedButton(onPressed: _listAndLoadGndDialog, child: const Text('Load .gnd')), const SizedBox(width: 8), ElevatedButton(onPressed: _exportGndAsCsvAndShare, child: const Text('Export Grid CSV'))]),
            const SizedBox(height: 8), Row(children: [Expanded(child: _buildHeatmapPreview())]), const SizedBox(height: 8), _buildPseudo3DPreview(),
          ]))
        ]),
      ),
    );
  }

  Color _indicatorColor(double v) {
    if (v > posThreshold) return Colors.redAccent;
    if (v < negThreshold) return Colors.blueAccent;
    return Colors.greenAccent;
  }
}
