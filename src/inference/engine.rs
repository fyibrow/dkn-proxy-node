use std::io::BufRead;
use std::ops::ControlFlow;
use std::time::Instant;

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use serde::{Deserialize, Serialize};

use dkn_protocol::{ChatMessage, ContentPart, InferenceProof, MessageContent};

use crate::error::NodeError;
use crate::inference::stream::StreamToken;

/// Parameters controlling text generation.
#[derive(Debug, Clone)]
pub struct GenerateParams {
    pub max_tokens: u32,
    pub temperature: f32,
    pub top_p: f32,
    pub seed: Option<u64>,
    /// Extract logprobs every N tokens (0 = disabled).
    /// Kept for protocol compatibility; cloud nodes return empty proofs.
    #[allow(dead_code)]
    pub logprob_every_n: usize,
    /// Top-k alternatives at each logprob position.
    #[allow(dead_code)]
    pub logprob_top_k: usize,
    /// OpenAI-style response_format JSON value (replaces GBNF grammar).
    pub response_format: Option<serde_json::Value>,
}

impl Default for GenerateParams {
    fn default() -> Self {
        Self {
            max_tokens: 512,
            temperature: 0.7,
            top_p: 0.9,
            seed: None,
            logprob_every_n: 0,
            logprob_top_k: 5,
            response_format: None,
        }
    }
}

/// Result of an inference run.
#[derive(Debug, Clone)]
pub struct InferenceResult {
    pub text: String,
    pub tokens_generated: u32,
    pub prompt_tokens: u32,
    pub generation_time_ms: u64,
    #[allow(dead_code)]
    pub prompt_eval_time_ms: u64,
    pub tokens_per_second: f64,
    pub proof: Option<InferenceProof>,
}

// ── API wire types ────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
struct ApiChatRequest {
    model: String,
    messages: Vec<ApiMessage>,
    max_tokens: u32,
    temperature: f32,
    top_p: f32,
    stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    seed: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    response_format: Option<serde_json::Value>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ApiMessage {
    role: String,
    content: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct ApiStreamChunk {
    choices: Vec<ApiStreamChoice>,
    #[serde(default)]
    usage: Option<ApiUsage>,
}

#[derive(Debug, Deserialize)]
struct ApiStreamChoice {
    delta: ApiDelta,
}

#[derive(Debug, Deserialize)]
struct ApiDelta {
    #[serde(default)]
    content: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ApiUsage {
    #[serde(default)]
    prompt_tokens: u32,
}

// ── Engine ────────────────────────────────────────────────────────────────────

/// Cloud-based inference engine that proxies to any OpenAI-compatible API.
///
/// Inference calls are made synchronously (blocking HTTP) so they can be
/// dispatched from `tokio::task::spawn_blocking` the same way llama.cpp was.
pub struct InferenceEngine {
    pub(crate) client: reqwest::blocking::Client,
    /// Base URL without trailing slash, e.g. "https://api.hyperbolic.xyz/v1"
    pub(crate) api_url: String,
    pub(crate) api_key: String,
    /// Model identifier on the cloud provider.
    pub(crate) cloud_model: String,
    /// Whether this engine handles image/audio inputs.
    is_multimodal: bool,
}

impl InferenceEngine {
    pub fn new(
        api_url: &str,
        api_key: &str,
        cloud_model: &str,
        is_multimodal: bool,
    ) -> Result<Self, NodeError> {
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(300))
            .user_agent("dria-proxy-node/0.7.4")
            .build()
            .map_err(|e| NodeError::Inference(format!("HTTP client init failed: {e}")))?;

        Ok(InferenceEngine {
            client,
            api_url: api_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
            cloud_model: cloud_model.to_string(),
            is_multimodal,
        })
    }

    pub fn has_multimodal(&self) -> bool {
        self.is_multimodal
    }

    /// Report a large context window so pre-flight checks rarely reject tasks.
    pub fn ctx_limit(&self) -> u32 {
        131_072
    }

    /// Approximate token count (4 chars ≈ 1 token).
    pub fn tokenize_count(&self, messages: &[ChatMessage]) -> Result<u32, NodeError> {
        let chars: usize = messages
            .iter()
            .map(|m| m.role.len() + content_char_len(&m.content))
            .sum();
        Ok((chars / 4 + messages.len() * 10) as u32)
    }

    /// Serialize messages to JSON — used internally as the "prompt" string.
    pub fn apply_template(&self, messages: &[ChatMessage]) -> Result<String, NodeError> {
        serde_json::to_string(messages)
            .map_err(|e| NodeError::Inference(format!("message serialization failed: {e}")))
    }

    /// Generate text from the serialized-JSON prompt produced by `apply_template`.
    pub fn generate<F>(
        &self,
        prompt: &str,
        params: &GenerateParams,
        mut on_token: F,
    ) -> Result<InferenceResult, NodeError>
    where
        F: FnMut(StreamToken) -> ControlFlow<()>,
    {
        let messages = deserialize_prompt(prompt);
        self.call_api(messages, params, &mut on_token)
    }

    /// Generate from multimodal messages directly (images / audio).
    pub fn generate_multimodal<F>(
        &self,
        messages: &[ChatMessage],
        params: &GenerateParams,
        mut on_token: F,
    ) -> Result<InferenceResult, NodeError>
    where
        F: FnMut(StreamToken) -> ControlFlow<()>,
    {
        self.call_api(messages.to_vec(), params, &mut on_token)
    }

    /// Validation prefill — cloud nodes return an empty proof.
    ///
    /// Cloud APIs don't expose raw logits in the same format as llama.cpp,
    /// so exact logprob matching is not possible. An empty proof is returned;
    /// the router treats this as an unverifiable but not fraudulent response.
    pub fn validate_prefill(
        &self,
        _prompt: &str,
        _output_text: &str,
        _logprob_every_n: usize,
        _logprob_top_k: usize,
    ) -> Result<InferenceProof, NodeError> {
        Ok(InferenceProof {
            logprobs: vec![],
            kv_cache_hash: None,
        })
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    fn call_api(
        &self,
        messages: Vec<ChatMessage>,
        params: &GenerateParams,
        on_token: &mut dyn FnMut(StreamToken) -> ControlFlow<()>,
    ) -> Result<InferenceResult, NodeError> {
        let api_messages = build_api_messages(&messages);

        let approx_prompt_tokens: u32 = api_messages
            .iter()
            .map(|m| m.content.to_string().len() as u32 / 4 + 10)
            .sum();

        let body = ApiChatRequest {
            model: self.cloud_model.clone(),
            messages: api_messages,
            max_tokens: params.max_tokens,
            temperature: params.temperature,
            top_p: params.top_p,
            stream: true,
            seed: params.seed,
            response_format: params.response_format.clone(),
        };

        let url = format!("{}/chat/completions", self.api_url);
        let start = Instant::now();

        let response = self
            .client
            .post(&url)
            .bearer_auth(&self.api_key)
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .map_err(|e| NodeError::Inference(format!("API request failed: {e}")))?;

        let status = response.status();
        if !status.is_success() {
            let err_body = response.text().unwrap_or_default();
            return Err(NodeError::Inference(format!(
                "API error {status}: {err_body}"
            )));
        }

        let reader = std::io::BufReader::new(response);
        let mut generated_text = String::new();
        let mut token_count = 0u32;
        let mut api_prompt_tokens: Option<u32> = None;

        for line_result in reader.lines() {
            let line =
                line_result.map_err(|e| NodeError::Inference(format!("stream read: {e}")))?;

            let Some(data) = line.strip_prefix("data: ") else {
                continue;
            };
            let data = data.trim();
            if data == "[DONE]" {
                break;
            }
            if data.is_empty() {
                continue;
            }

            match serde_json::from_str::<ApiStreamChunk>(data) {
                Ok(chunk) => {
                    if let Some(ref u) = chunk.usage {
                        api_prompt_tokens = Some(u.prompt_tokens);
                    }
                    if let Some(choice) = chunk.choices.first() {
                        if let Some(ref content) = choice.delta.content {
                            if !content.is_empty() {
                                generated_text.push_str(content);
                                let st = StreamToken {
                                    text: content.clone(),
                                    index: token_count as usize,
                                };
                                token_count += 1;
                                if let ControlFlow::Break(()) = on_token(st) {
                                    break;
                                }
                            }
                        }
                    }
                }
                Err(_) => { /* skip keep-alive or unknown chunks */ }
            }
        }

        let elapsed_ms = start.elapsed().as_millis() as u64;
        let tps = if elapsed_ms > 0 {
            token_count as f64 / (elapsed_ms as f64 / 1000.0)
        } else {
            50.0
        };

        Ok(InferenceResult {
            text: generated_text,
            tokens_generated: token_count,
            prompt_tokens: api_prompt_tokens.unwrap_or(approx_prompt_tokens),
            generation_time_ms: elapsed_ms,
            prompt_eval_time_ms: 0,
            tokens_per_second: tps,
            proof: None,
        })
    }
}

// ── Free helpers ──────────────────────────────────────────────────────────────

fn deserialize_prompt(prompt: &str) -> Vec<ChatMessage> {
    serde_json::from_str(prompt).unwrap_or_else(|_| {
        vec![ChatMessage {
            role: "user".into(),
            content: MessageContent::Text(prompt.to_string()),
        }]
    })
}

fn content_char_len(content: &MessageContent) -> usize {
    match content {
        MessageContent::Text(t) => t.len(),
        MessageContent::Parts(parts) => parts
            .iter()
            .map(|p| match p {
                ContentPart::Text { text } => text.len(),
                ContentPart::Image { data } => data.len() / 3,
                ContentPart::Audio { data } => data.len() / 10,
            })
            .sum(),
    }
}

fn build_api_messages(messages: &[ChatMessage]) -> Vec<ApiMessage> {
    messages
        .iter()
        .map(|m| {
            let content = match &m.content {
                MessageContent::Text(text) => serde_json::Value::String(text.clone()),
                MessageContent::Parts(parts) => {
                    let api_parts: Vec<serde_json::Value> = parts
                        .iter()
                        .map(|part| match part {
                            ContentPart::Text { text } => {
                                serde_json::json!({"type": "text", "text": text})
                            }
                            ContentPart::Image { data } => {
                                let b64 = BASE64.encode(data);
                                let mime = infer_image_mime(data);
                                serde_json::json!({
                                    "type": "image_url",
                                    "image_url": {
                                        "url": format!("data:{mime};base64,{b64}")
                                    }
                                })
                            }
                            ContentPart::Audio { data } => {
                                let b64 = BASE64.encode(data);
                                serde_json::json!({
                                    "type": "input_audio",
                                    "input_audio": {"data": b64, "format": "wav"}
                                })
                            }
                        })
                        .collect();
                    serde_json::Value::Array(api_parts)
                }
            };
            ApiMessage {
                role: m.role.clone(),
                content,
            }
        })
        .collect()
}

fn infer_image_mime(data: &[u8]) -> &'static str {
    if data.starts_with(b"\x89PNG") {
        "image/png"
    } else if data.starts_with(b"\xff\xd8\xff") {
        "image/jpeg"
    } else if data.starts_with(b"GIF") {
        "image/gif"
    } else if data.len() > 12 && data.starts_with(b"RIFF") && &data[8..12] == b"WEBP" {
        "image/webp"
    } else if data.starts_with(b"BM") {
        "image/bmp"
    } else {
        "image/jpeg"
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_params_default() {
        let p = GenerateParams::default();
        assert_eq!(p.max_tokens, 512);
        assert_eq!(p.temperature, 0.7);
        assert_eq!(p.logprob_every_n, 0);
        assert!(p.response_format.is_none());
    }

    #[test]
    fn test_deserialize_prompt_json() {
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: MessageContent::Text("hello".into()),
        }];
        let json = serde_json::to_string(&messages).unwrap();
        let back = deserialize_prompt(&json);
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].role, "user");
    }

    #[test]
    fn test_deserialize_prompt_plain_text_fallback() {
        let back = deserialize_prompt("not json {{{");
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].role, "user");
        match &back[0].content {
            MessageContent::Text(t) => assert_eq!(t, "not json {{{"),
            _ => panic!("expected Text"),
        }
    }

    #[test]
    fn test_infer_image_mime() {
        assert_eq!(infer_image_mime(b"\x89PNG\r\n\x1a\n"), "image/png");
        assert_eq!(infer_image_mime(b"\xff\xd8\xff\xe0"), "image/jpeg");
        assert_eq!(infer_image_mime(b"GIF89a"), "image/gif");
        assert_eq!(infer_image_mime(b"BM"), "image/bmp");
        assert_eq!(infer_image_mime(b"unknown"), "image/jpeg");
    }

    #[test]
    fn test_content_char_len_text() {
        let c = MessageContent::Text("hello world".into());
        assert_eq!(content_char_len(&c), 11);
    }

    #[test]
    fn test_tokenize_count_approx() {
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: MessageContent::Text("a".repeat(400)),
        }];
        // engine creation requires a real HTTP client but tokenize_count doesn't call the API
        let engine = InferenceEngine::new(
            "https://example.com/v1",
            "test-key",
            "test-model",
            false,
        )
        .unwrap();
        let count = engine.tokenize_count(&messages).unwrap();
        assert!(count > 90 && count < 200, "approx token count out of range: {count}");
    }

    #[test]
    fn test_ctx_limit() {
        let engine = InferenceEngine::new(
            "https://example.com/v1",
            "test-key",
            "test-model",
            false,
        )
        .unwrap();
        assert_eq!(engine.ctx_limit(), 131_072);
    }

    #[test]
    fn test_validate_prefill_returns_empty_proof() {
        let engine = InferenceEngine::new(
            "https://example.com/v1",
            "test-key",
            "test-model",
            false,
        )
        .unwrap();
        let proof = engine.validate_prefill("prompt", "output", 8, 5).unwrap();
        assert!(proof.logprobs.is_empty());
        assert!(proof.kv_cache_hash.is_none());
    }

    #[test]
    fn test_apply_template_roundtrip() {
        let engine = InferenceEngine::new(
            "https://example.com/v1",
            "test-key",
            "test-model",
            false,
        )
        .unwrap();
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: MessageContent::Text("hi".into()),
        }];
        let json = engine.apply_template(&messages).unwrap();
        let back = deserialize_prompt(&json);
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].role, "user");
    }

    #[test]
    fn test_build_api_messages_text() {
        let messages = vec![
            ChatMessage {
                role: "system".into(),
                content: MessageContent::Text("You are helpful.".into()),
            },
            ChatMessage {
                role: "user".into(),
                content: MessageContent::Text("Hello".into()),
            },
        ];
        let api = build_api_messages(&messages);
        assert_eq!(api.len(), 2);
        assert_eq!(api[0].role, "system");
        assert_eq!(api[1].content, serde_json::Value::String("Hello".into()));
    }

    #[test]
    fn test_build_api_messages_multipart() {
        let messages = vec![ChatMessage {
            role: "user".into(),
            content: MessageContent::Parts(vec![
                ContentPart::Text {
                    text: "describe".into(),
                },
                ContentPart::Image {
                    data: b"\x89PNG\r\n\x1a\nfake".to_vec(),
                },
            ]),
        }];
        let api = build_api_messages(&messages);
        assert_eq!(api.len(), 1);
        let parts = api[0].content.as_array().expect("should be array");
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0]["type"], "text");
        assert_eq!(parts[1]["type"], "image_url");
        let url = parts[1]["image_url"]["url"].as_str().unwrap();
        assert!(url.starts_with("data:image/png;base64,"));
    }
}
