mod common;

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::endpoints::{router::match_rest_path, Params};
use serde_json::json;

#[tokio::test]
async fn novel_homepage_opt_out_reaches_the_signed_upstream_request() {
    let upstream = MockUpstream::start(|request| {
        assert!(request.path.contains("/bookmall/tab/"));
        let query = Params::parse(&request.query);
        assert_eq!(query.get_str("need_personal_recommend"), "0");
        assert_eq!(query.get_str("tab_type"), "2");
        assert_eq!(query.get_str("offset"), "10");
        MockReply::json(json!({"code":0,"data":{"cell_data":[]}}))
    })
    .await;
    let dir = TempDir::new("novel-homepage-opt-out");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let route = match_rest_path(
        "/api/v1/recommend/homepage",
        &Params::parse("tab_type=2&tab_index=0&offset=10&personalized=0"),
    )
    .unwrap();
    let response = (server.handler(route.api).unwrap())(&server.ctx, &route.params)
        .await
        .unwrap();
    assert_eq!(response["code"], 0);
    upstream.shutdown();
}

#[tokio::test]
async fn novel_search_opt_out_keeps_the_readers_query() {
    let upstream = MockUpstream::start(|request| {
        assert!(request.path.contains("/search/tab/"));
        let query = Params::parse(&request.query);
        assert_eq!(query.get_str("need_personal_recommend"), "0");
        assert_eq!(query.get_str("query"), "斩神");
        assert_eq!(query.get_str("offset"), "20");
        MockReply::json(json!({"code":0,"data":{"search_tabs":[]}}))
    })
    .await;
    let dir = TempDir::new("novel-search-opt-out");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let mut query = Params::parse("tab_type=1&offset=20&count=10&personalized=0");
    query.set("query", "斩神");
    let route = match_rest_path("/api/v1/search", &query).unwrap();
    let response = (server.handler(route.api).unwrap())(&server.ctx, &route.params)
        .await
        .unwrap();
    assert_eq!(response["code"], 0);
    upstream.shutdown();
}
