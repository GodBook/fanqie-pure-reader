import 'dart:async';

import 'api_client.dart' show ApiException;

/// Only concise user-facing errors belong in product screens. Upstream errors
/// may carry full registration URLs and protocol parameters.
String userErrorText(Object error) {
  if (error is TimeoutException) return '请求超时，请重试';
  if (error is ApiException || error is StateError) {
    final message = error is ApiException
        ? error.message.trim()
        : (error as StateError).message.toString().trim();
    if (message.length <= 60 &&
        RegExp(r'[\u4e00-\u9fff]').hasMatch(message) &&
        !RegExp(r'[\r\n{}<>]|https?://|[a-zA-Z_]{4,}').hasMatch(message)) {
      return message;
    }
    return '连接失败，请检查网络后重试';
  }
  return '网络或本地存储暂时不可用，请重试';
}
