//! Read-only official topic details and reader book recommendations.
use super::base::{dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec, HOST_FQNOVEL};
use super::home::reading724_params;
use super::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};
use futures::future::BoxFuture;
use serde_json::Value;

fn topic<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let id = params.get_str("topic_id");
        if !(10..=20).contains(&id.len()) || !id.bytes().all(|b| b.is_ascii_digit()) {
            return Err(ApiError::BadRequest("无效话题编号".into()));
        }
        let mut query = reading724_params();
        query.set("topic_id", id);
        query.set("book_id", "11111");
        let comments = params.get_str("community_part") == "comments";
        if comments {
            query.set("service_id", "6");
            query.set("source", "bookstore");
            query.set("has_book", "true");
            query.set("count", "20");
            query.set(
                "offset",
                params.get_int("offset", 0).clamp(0, 1_000_000).to_string(),
            );
            query.set(
                "sort",
                if params.get_str("sort") == "create_time" {
                    "create_time"
                } else {
                    "smart_hot"
                },
            );
            let session = params.get_str("session_id");
            if !session.is_empty() {
                query.set("session_id", session);
            }
        }
        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.into(),
                path: if comments {
                    "/reading/ugc/novel_comment/topic/v1/"
                } else {
                    "/reading/ugc/topic/content/v1/"
                }
                .into(),
                params: query.to_pairs(),
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

pub fn register(server: &mut Server) {
    server.add_route("community_topic", topic);
}
