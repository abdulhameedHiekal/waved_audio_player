// ignore_for_file: library_private_types_in_public_api

library waved_audio_player;

import 'dart:async'; // <-- for StreamSubscription
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:waved_audio_player/wave_form_painter.dart';
import 'package:waved_audio_player/waved_audio_player_error.dart';

// ignore: must_be_immutable
class WavedAudioPlayer extends StatefulWidget {
  Source source;
  Color playedColor;
  Color unplayedColor;
  Color iconColor;
  Color iconBackgoundColor;
  double barWidth;
  double spacing;
  double waveHeight;
  double buttonSize;
  double waveWidth;
  bool showTiming;
  TextStyle? timingStyle;
  void Function(WavedAudioPlayerError)? onError;

  WavedAudioPlayer({
    super.key,
    required this.source,
    this.playedColor = Colors.blue,
    this.unplayedColor = Colors.grey,
    this.iconColor = Colors.blue,
    this.iconBackgoundColor = Colors.white,
    this.barWidth = 2,
    this.spacing = 4,
    this.waveWidth = 200,
    this.buttonSize = 40,
    this.showTiming = true,
    this.timingStyle,
    this.onError,
    this.waveHeight = 35,
  });

  @override
  _WavedAudioPlayerState createState() => _WavedAudioPlayerState();
}

class _WavedAudioPlayerState extends State<WavedAudioPlayer> {
  final AudioPlayer _audioPlayer = AudioPlayer();

  // --- State
  List<double> waveformData = [];
  Duration audioDuration = Duration.zero;
  Duration currentPosition = Duration.zero;
  bool isPlaying = false;
  bool isPausing = true;
  Uint8List? _audioBytes;

  // --- Subscriptions {{اشتراكات}}
  late final StreamSubscription<PlayerState> _stateSub;
  late final StreamSubscription<void> _completeSub;
  late final StreamSubscription<Duration> _durSub;
  late final StreamSubscription<Duration> _posSub;

  // Extra guard {{حارس إضافي}}
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _loadWaveform();
    _setupAudioPlayer();
  }

  // safe setState {{استدعاء آمن لـ setState}}
  void _safeSetState(VoidCallback fn) {
    if (!mounted || _disposed) return;
    setState(fn);
  }

  @override
  void dispose() {
    _disposed = true;

    // Cancel streams first {{إلغاء المستمعين أولاً}}
    try {
      _stateSub.cancel();
      _completeSub.cancel();
      _durSub.cancel();
      _posSub.cancel();
    } catch (_) {
      // ignore
    }

    // Stop and dispose player {{إيقاف وتحرير المشغّل}}
    try {
      _audioPlayer.stop();
    } catch (_) {}
    _audioPlayer.dispose();

    super.dispose();
  }

  Future<void> _loadWaveform() async {
    try {
      if (_audioBytes == null) {
        if (widget.source is AssetSource) {
          _audioBytes =
          await _loadAssetAudioWaveform((widget.source as AssetSource).path);
        } else if (widget.source is UrlSource) {
          _audioBytes =
          await _loadRemoteAudioWaveform((widget.source as UrlSource).url);
        } else if (widget.source is DeviceFileSource) {
          _audioBytes = await _loadDeviceFileAudioWaveform(
              (widget.source as DeviceFileSource).path);
        } else if (widget.source is BytesSource) {
          _audioBytes = (widget.source as BytesSource).bytes;
        }

        if (_audioBytes == null) return;

        waveformData = _extractWaveformData(_audioBytes!);
        _safeSetState(() {}); // rebuild once data ready
      }

      await _audioPlayer
          .setSource(BytesSource(_audioBytes!, mimeType: widget.source.mimeType));
    } catch (e) {
      _callOnError(WavedAudioPlayerError("Error loading audio: $e"));
    }
  }

  Future<Uint8List?> _loadDeviceFileAudioWaveform(String filePath) async {
    try {
      final file = File(filePath);
      return await file.readAsBytes();
    } catch (e) {
      _callOnError(WavedAudioPlayerError("Error loading file audio: $e"));
      return null;
    }
  }

  Future<Uint8List?> _loadAssetAudioWaveform(String path) async {
    try {
      final bytes = await rootBundle.load(path);
      return bytes.buffer.asUint8List();
    } catch (e) {
      _callOnError(WavedAudioPlayerError("Error loading asset audio: $e"));
      return null;
    }
  }

  Future<Uint8List?> _loadRemoteAudioWaveform(String url) async {
    HttpClient? httpClient;
    try {
      httpClient = HttpClient();
      final request = await httpClient.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode == 200) {
        return await consolidateHttpClientResponseBytes(response);
      } else {
        _callOnError(WavedAudioPlayerError(
            "Failed to load audio: ${response.statusCode}"));
        return null;
      }
    } catch (e) {
      _callOnError(WavedAudioPlayerError("Error loading audio: $e"));
      return null;
    } finally {
      try {
        httpClient?.close(force: true);
      } catch (_) {}
    }
  }

  void _callOnError(WavedAudioPlayerError error) {
    if (widget.onError == null) return;
    // print error nicely
    // ignore: avoid_print
    print('\x1B[31m ${error.message}\x1B[0m');
    widget.onError!(error);
  }

  void _setupAudioPlayer() {
    _stateSub =
        _audioPlayer.onPlayerStateChanged.listen((PlayerState state) {
          _safeSetState(() {
            isPlaying = (state == PlayerState.playing);
          });
        });

    _completeSub = _audioPlayer.onPlayerComplete.listen((_) {
      // keep UI stable; if you need UI change, guard via _safeSetState
      isPausing = false;
      _audioPlayer.release();
    });

    _durSub = _audioPlayer.onDurationChanged.listen((Duration duration) {
      _safeSetState(() {
        audioDuration = duration;
        isPausing = true;
      });
    });

    _posSub = _audioPlayer.onPositionChanged.listen((Duration position) {
      _safeSetState(() {
        currentPosition = position;
        isPausing = true;
      });
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (hours > 0) {
      return "${twoDigits(hours)}:$minutes:$seconds"; // HH:MM:SS
    } else {
      return "$minutes:$seconds"; // MM:SS
    }
  }

  List<double> _extractWaveformData(Uint8List audioBytes) {
    final List<double> waveData = [];
    final step = (audioBytes.length /
        (widget.waveWidth / (widget.barWidth + widget.spacing)))
        .floor()
        .clamp(1, audioBytes.length);
    for (int i = 0; i < audioBytes.length; i += step) {
      waveData.add(audioBytes[i] / 255);
    }
    waveData.add(audioBytes[audioBytes.length - 1] / 255);
    return waveData;
  }

  void _onWaveformTap(double tapX, double width) {
    if (audioDuration == Duration.zero) return;
    final tapPercent = (tapX / width).clamp(0.0, 1.0);
    final newPosition = audioDuration * tapPercent;
    _audioPlayer.seek(newPosition);
  }

  void _playAudio() {
    if (_audioBytes == null) return;
    if (isPausing) {
      _audioPlayer.resume();
    } else {
      _audioPlayer.play(BytesSource(_audioBytes!, mimeType: widget.source.mimeType));
    }
  }

  void _pauseAudio() {
    _audioPlayer.pause();
    isPausing = true;
  }

  @override
  Widget build(BuildContext context) {
    return (waveformData.isNotEmpty)
        ? Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: () {
            isPlaying ? _pauseAudio() : _playAudio();
            _safeSetState(() {
              isPlaying = !isPlaying;
            });
          },
          child: Container(
            height: widget.buttonSize,
            width: widget.buttonSize,
            decoration: BoxDecoration(
              color: widget.iconBackgoundColor,
              borderRadius: BorderRadius.circular(40),
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: widget.iconColor,
              size: 4 * widget.buttonSize / 5,
            ),
          ),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTapDown: (details) {
            _onWaveformTap(details.localPosition.dx, widget.waveWidth);
          },
          child: CustomPaint(
            size: Size(widget.waveWidth, widget.waveHeight),
            painter: WaveformPainter(
              waveformData,
              audioDuration.inMilliseconds == 0
                  ? 0
                  : currentPosition.inMilliseconds /
                  audioDuration.inMilliseconds,
              playedColor: widget.playedColor,
              unplayedColor: widget.unplayedColor,
              barWidth: widget.barWidth,
            ),
          ),
        ),
        if (widget.showTiming) const SizedBox(width: 10),
        if (widget.showTiming)
          Center(
            child: Text(
              _formatDuration(currentPosition),
              style: widget.timingStyle,
            ),
          ),
      ],
    )
        : SizedBox(
      width: widget.waveWidth + widget.buttonSize,
      height: max(widget.waveHeight, widget.buttonSize),
      child: Center(
        child: LinearProgressIndicator(
          color: widget.playedColor,
          borderRadius: BorderRadius.circular(40),
        ),
      ),
    );
  }
}
