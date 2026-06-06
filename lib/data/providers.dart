import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pack_state.dart';
import '../decoder/decoder_engine.dart';
import '../protocol/can_frame.dart';

final packStateProvider = Provider<PackState>((ref) => PackState());

final decoderEngineProvider = Provider<DecoderEngine>((ref) {
  return DecoderEngine(ref.read(packStateProvider));
});

final frameStreamProvider = StreamProvider<CanFrame>((ref) {
  return ref.watch(_frameControllerProvider).stream;
});

final _frameControllerProvider =
    Provider<StreamController<CanFrame>>((ref) {
  final controller = StreamController<CanFrame>.broadcast();
  ref.onDispose(() => controller.close());
  return controller;
});

final connectionStateProvider = StateProvider<bool>((ref) => false);
final fpsProvider = StateProvider<int>((ref) => 0);
final adapterTypeProvider = StateProvider<String>((ref) => '');
final sweepPctProvider = StateProvider<double>((ref) => 0.0);
