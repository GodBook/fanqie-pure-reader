import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/api_client.dart';

void main() {
  test(
    'novel recommendation and search pass opt-out without changing cursors',
    () async {
      final requests = <Uri>[];
      final client = ApiClient(
        baseUrl: 'http://localhost',
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'cell_data': <Object>[], 'search_tabs': <Object>[]},
            }),
            200,
          );
        }),
      );
      await client.homepagePage(
        tabType: 2,
        offset: 10,
        sessionId: 'cursor',
        personalized: false,
      );
      await client.searchTabs(
        '斩神',
        tabType: 1,
        offset: 20,
        personalized: false,
      );
      expect(requests[0].queryParameters['personalized'], '0');
      expect(requests[0].queryParameters['session_id'], 'cursor');
      expect(requests[0].queryParameters['offset'], '10');
      expect(requests[1].queryParameters['personalized'], '0');
      expect(requests[1].queryParameters['query'], '斩神');
      expect(requests[1].queryParameters['offset'], '20');
      await client.homepageRecommend();
      expect(requests.last.queryParameters['personalized'], '1');
    },
  );
}
