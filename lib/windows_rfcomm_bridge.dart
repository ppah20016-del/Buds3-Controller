import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class WindowsRfcommBridge {
  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  final StreamController<Uint8List> _rawDataController =
      StreamController<Uint8List>.broadcast();

  final Completer<void> _connectedCompleter = Completer<void>();

  Stream<Uint8List> get rawDataStream => _rawDataController.stream;

  Future<void> connect({
    required String mac,
    required String uuid,
  }) async {
    final List<String> args = <String>[
      'run',
      '--project',
      'windows/buds_rfcomm_bridge/BudsRfcommBridge.csproj',
      '--',
      '--mac',
      mac,
      '--uuid',
      uuid,
    ];

    _process = await Process.start(
      'dotnet',
      args,
      runInShell: true,
      workingDirectory: Directory.current.path,
    );

    _stdoutSub = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStdoutLine);

    _stderrSub = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      if (!_connectedCompleter.isCompleted) {
        _connectedCompleter.completeError(
          StateError('Bridge stderr: $line'),
        );
      }
    });

    await _connectedCompleter.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        throw TimeoutException('C# bridge baglanti timeout.');
      },
    );
  }

  void _handleStdoutLine(String line) {
    try {
      final Map<String, dynamic> message =
          jsonDecode(line) as Map<String, dynamic>;
      final String type = (message['type'] ?? '').toString();

      if (type == 'status') {
        final bool ok = message['ok'] == true;
        if (!_connectedCompleter.isCompleted) {
          if (ok) {
            _connectedCompleter.complete();
          } else {
            _connectedCompleter.completeError(
              StateError((message['message'] ?? 'Bridge status error').toString()),
            );
          }
        }
      }

      if (type == 'data') {
        final String b64 = (message['data'] ?? '').toString();
        if (b64.isNotEmpty) {
          _rawDataController.add(base64Decode(b64));
        }
      }
    } catch (_) {
      // Ignore non-json log lines.
    }
  }

  Future<void> send(Uint8List bytes) async {
    final Process? p = _process;
    if (p == null) {
      throw StateError('C# bridge aktif degil.');
    }

    final String line = jsonEncode(<String, dynamic>{
      'type': 'send',
      'data': base64Encode(bytes),
    });

    p.stdin.writeln(line);
    await p.stdin.flush();
  }

  Future<void> disconnect() async {
    final Process? p = _process;
    if (p == null) {
      return;
    }

    p.stdin.writeln(jsonEncode(<String, dynamic>{'type': 'disconnect'}));
    await p.stdin.flush();

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();

    p.kill();
    _process = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _rawDataController.close();
  }
}
