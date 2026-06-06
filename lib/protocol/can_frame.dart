import 'dart:typed_data';

class CanFrame {
  final int arbitrationId;
  final Uint8List data;
  final double timestamp;
  final bool isExtended;

  CanFrame({
    required this.arbitrationId,
    required this.data,
    double? timestamp,
    this.isExtended = false,
  }) : timestamp = timestamp ?? DateTime.now().microsecondsSinceEpoch / 1e6;

  factory CanFrame.fromList({
    required int arbitrationId,
    required List<int> data,
    double? timestamp,
    bool isExtended = false,
  }) {
    return CanFrame(
      arbitrationId: arbitrationId,
      data: Uint8List.fromList(data),
      timestamp: timestamp,
      isExtended: isExtended,
    );
  }

  int get dlc => data.length;

  @override
  String toString() =>
      '${arbitrationId.toRadixString(16).toUpperCase().padLeft(3, '0')} '
      '[${data.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ')}]';
}
