/// Whole-book position relative to the current catalogue, not unique text read.
double? novelSavedBookProgress(Map<String, dynamic>? saved) {
  final value = saved?['progress'];
  return value is num && value.isFinite && value >= 0 && value <= 1
      ? value.toDouble()
      : null;
}

String novelBookProgressLabel(double fraction) {
  if (!fraction.isFinite) return '阅读进度暂不可用';
  return '本书已读 ${novelBookProgressPercent(fraction)}%';
}

String novelBookProgressPercent(double fraction, {bool compact = true}) {
  if (!fraction.isFinite) return '—';
  // Do not report 100% while a final part of the book still remains.
  final tenths = (fraction.clamp(0.0, 1.0) * 1000 + 1e-9).floor();
  final percent = (tenths / 10).toStringAsFixed(1);
  return compact ? percent.replaceFirst(RegExp(r'\.0$'), '') : percent;
}
