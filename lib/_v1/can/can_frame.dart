/// CAN frame — universal representation regardless of adapter source.
class CanFrame {
  final int id;
  final List<int> data;
  final DateTime timestamp;

  CanFrame({required this.id, required this.data, DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();

  int get dlc => data.length;

  @override
  String toString() =>
      '${id.toRadixString(16).toUpperCase().padLeft(3, '0')} '
      '[${data.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ')}]';
}
