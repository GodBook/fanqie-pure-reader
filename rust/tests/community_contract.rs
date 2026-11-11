mod common;
use common::{build_server,pool_json,TempDir,MockReply,MockUpstream};
use fqapi_core::endpoints::{Params,router::match_rest_path};
use serde_json::json;

#[tokio::test]
async fn topic_comments_use_read_only_service_six_and_keep_pagination(){
    let upstream=MockUpstream::start(|request|{
        let query=Params::parse(&request.query);
        assert_eq!(request.method,"GET");
        assert_eq!(request.path,"/reading/ugc/novel_comment/topic/v1/");
        assert_eq!(query.get_str("service_id"),"6");
        assert_eq!(query.get_str("book_id"),"11111");
        assert_eq!(query.get_str("offset"),"20");
        assert_eq!(query.get_str("sort"),"create_time");
        assert_eq!(query.get_str("session_id"),"session");
        MockReply::json(json!({"code":0,"data":{"comment":[],"next_offset":40,"has_more":true}}))
    }).await;
    let dir=TempDir::new("community");
    let server=build_server(&dir,Some(upstream.origin.clone()),&[],&[],&pool_json(5)).await;
    let route=match_rest_path("/api/v1/community/topics/1111111111111111/comments",
        &Params::parse("offset=20&sort=create_time&session_id=session&community_part=detail")).unwrap();
    let response=(server.handler(route.api).unwrap())(&server.ctx,&route.params).await.unwrap();
    assert_eq!(response["data"]["next_offset"],40);
    upstream.shutdown();
}

#[test]
fn community_routes_only_expose_fixed_read_resources(){
    assert!(match_rest_path("/api/v1/community/topics/1111111111111111/publish",&Params::new()).is_none());
    let route=match_rest_path("/api/v1/community/topics/1111111111111111",&Params::parse("community_part=comments&topic_id=wrong")).unwrap();
    assert_eq!(route.params.get_str("topic_id"),"1111111111111111");
    assert_eq!(route.params.get_str("community_part"),"detail");
}
