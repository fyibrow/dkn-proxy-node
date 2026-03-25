use std::collections::HashMap;
use std::path::PathBuf;

use clap::{Parser, Subcommand};

use crate::error::NodeError;

#[derive(Parser)]
#[command(
    name = "dria-node",
    version,
    about = "Dria Compute Node — Cloud API Proxy Edition"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
    /// Show proxy configuration and verify API connectivity
    Setup,

    /// Start the compute node (proxies inference to a cloud API)
    Start {
        /// Dria wallet secret key (hex-encoded, 32 bytes)
        #[arg(long, env = "DRIA_WALLET")]
        wallet: String,

        /// Dria model name(s) to advertise (comma-separated, e.g. "qwen3.5:9b,lfm2.5:1.2b")
        #[arg(long, env = "DRIA_MODELS")]
        model: String,

        /// Router URL for task coordination
        #[arg(long, env = "DRIA_ROUTER_URL", default_value = "quic.dria.co:4001")]
        router_url: String,

        /// Maximum concurrent inference requests
        #[arg(long, env = "DRIA_MAX_CONCURRENT", default_value = "4")]
        max_concurrent: usize,

        /// Cloud API base URL (OpenAI-compatible, e.g. https://api.hyperbolic.xyz/v1)
        #[arg(long, env = "PROXY_API_URL", default_value = "https://api.hyperbolic.xyz/v1")]
        proxy_api_url: String,

        /// Cloud API key
        #[arg(long, env = "PROXY_API_KEY")]
        proxy_api_key: String,

        /// Default cloud model to use for all Dria model names
        #[arg(
            long,
            env = "PROXY_DEFAULT_MODEL",
            default_value = "meta-llama/Llama-3.3-70B-Instruct"
        )]
        proxy_default_model: String,

        /// Optional per-model mapping: "dria_name=cloud_name" entries, comma-separated.
        /// E.g. "qwen3.5:9b=Qwen/Qwen2.5-7B-Instruct,lfm2.5:1.2b=Qwen/Qwen2.5-1.5B-Instruct"
        #[arg(long, env = "PROXY_MODELS", default_value = "")]
        proxy_models: String,

        /// Skip TLS certificate verification (development only)
        #[arg(long, env = "DRIA_INSECURE")]
        insecure: bool,

        /// Skip automatic update check on startup
        #[arg(long, env = "DRIA_SKIP_UPDATE")]
        skip_update: bool,
    },
}

/// Parsed and validated runtime configuration.
pub struct Config {
    pub secret_key_hex: String,
    pub model_names: Vec<String>,
    pub router_urls: Vec<String>,
    pub max_concurrent: usize,
    pub data_dir: PathBuf,
    /// Cloud API base URL (no trailing slash).
    pub proxy_api_url: String,
    /// Cloud API authentication key.
    pub proxy_api_key: String,
    /// Default cloud model name used when no per-model mapping is found.
    pub proxy_default_model: String,
    /// Dria model name → cloud model name overrides.
    pub proxy_model_map: HashMap<String, String>,
    pub insecure: bool,
    pub skip_update: bool,
}

impl Config {
    #[allow(clippy::too_many_arguments)]
    pub fn from_start_args(
        wallet: String,
        model: String,
        router_url: String,
        max_concurrent: usize,
        proxy_api_url: String,
        proxy_api_key: String,
        proxy_default_model: String,
        proxy_models: String,
        insecure: bool,
        skip_update: bool,
    ) -> Result<Self, NodeError> {
        // Validate wallet key
        let secret_key_hex = wallet.strip_prefix("0x").unwrap_or(&wallet).to_string();
        if secret_key_hex.len() != 64 {
            return Err(NodeError::Config(format!(
                "wallet key must be 64 hex chars (got {})",
                secret_key_hex.len()
            )));
        }
        hex::decode(&secret_key_hex)
            .map_err(|e| NodeError::Config(format!("wallet key is not valid hex: {e}")))?;

        // Parse Dria model names
        let model_names: Vec<String> = model
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if model_names.is_empty() {
            return Err(NodeError::Config(
                "at least one model must be specified (--model)".into(),
            ));
        }

        if max_concurrent == 0 {
            return Err(NodeError::Config("max-concurrent must be >= 1".into()));
        }

        // Parse router URLs (comma-separated)
        let router_urls: Vec<String> = router_url
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if router_urls.is_empty() {
            return Err(NodeError::Config("router URL must not be empty".into()));
        }

        // Validate proxy API key
        if proxy_api_key.trim().is_empty() {
            return Err(NodeError::Config(
                "PROXY_API_KEY is required (set via --proxy-api-key or env var)".into(),
            ));
        }

        // Parse per-model mapping: "dria_name=cloud_name,..."
        let proxy_model_map = parse_model_map(&proxy_models);

        let data_dir = dirs::home_dir()
            .ok_or_else(|| NodeError::Config("could not determine home directory".into()))?
            .join(".dria");

        Ok(Config {
            secret_key_hex,
            model_names,
            router_urls,
            max_concurrent,
            data_dir,
            proxy_api_url: proxy_api_url.trim_end_matches('/').to_string(),
            proxy_api_key,
            proxy_default_model,
            proxy_model_map,
            insecure,
            skip_update,
        })
    }

    /// Resolve which cloud model name to use for a given Dria model name.
    pub fn resolve_cloud_model(&self, dria_model: &str) -> String {
        self.proxy_model_map
            .get(dria_model)
            .cloned()
            .unwrap_or_else(|| self.proxy_default_model.clone())
    }
}

/// Parse "a=b,c=d" into a HashMap.
fn parse_model_map(s: &str) -> HashMap<String, String> {
    s.split(',')
        .filter_map(|pair| {
            let mut parts = pair.splitn(2, '=');
            let key = parts.next()?.trim();
            let val = parts.next()?.trim();
            if key.is_empty() || val.is_empty() {
                None
            } else {
                Some((key.to_string(), val.to_string()))
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_wallet() -> String {
        "6472696164726961647269616472696164726961647269616472696164726961".into()
    }

    fn make_cfg(extra: Option<(&str, &str)>) -> Result<Config, NodeError> {
        let proxy_models = extra
            .map(|(k, v)| format!("{k}={v}"))
            .unwrap_or_default();
        Config::from_start_args(
            valid_wallet(),
            "qwen3.5:9b".into(),
            "quic.dria.co:4001".into(),
            4,
            "https://api.hyperbolic.xyz/v1".into(),
            "test-key".into(),
            "meta-llama/Llama-3.3-70B-Instruct".into(),
            proxy_models,
            false,
            true,
        )
    }

    #[test]
    fn test_config_valid() {
        let cfg = make_cfg(None).unwrap();
        assert_eq!(cfg.model_names, vec!["qwen3.5:9b"]);
        assert_eq!(cfg.max_concurrent, 4);
        assert!(cfg.skip_update);
    }

    #[test]
    fn test_config_wallet_too_short() {
        let r = Config::from_start_args(
            "0xabcd".into(),
            "qwen3.5:9b".into(),
            "quic.dria.co:4001".into(),
            1,
            "https://api.example.com/v1".into(),
            "key".into(),
            "model".into(),
            "".into(),
            false,
            false,
        );
        assert!(r.is_err());
    }

    #[test]
    fn test_config_empty_proxy_key() {
        let r = Config::from_start_args(
            valid_wallet(),
            "qwen3.5:9b".into(),
            "quic.dria.co:4001".into(),
            1,
            "https://api.example.com/v1".into(),
            "".into(),
            "model".into(),
            "".into(),
            false,
            false,
        );
        assert!(r.is_err());
    }

    #[test]
    fn test_config_zero_concurrent() {
        let r = Config::from_start_args(
            valid_wallet(),
            "qwen3.5:9b".into(),
            "quic.dria.co:4001".into(),
            0,
            "https://api.example.com/v1".into(),
            "key".into(),
            "model".into(),
            "".into(),
            false,
            false,
        );
        assert!(r.is_err());
    }

    #[test]
    fn test_resolve_cloud_model_default() {
        let cfg = make_cfg(None).unwrap();
        assert_eq!(
            cfg.resolve_cloud_model("unknown:model"),
            "meta-llama/Llama-3.3-70B-Instruct"
        );
    }

    #[test]
    fn test_resolve_cloud_model_mapped() {
        let cfg = make_cfg(Some(("qwen3.5:9b", "Qwen/Qwen2.5-7B-Instruct"))).unwrap();
        assert_eq!(
            cfg.resolve_cloud_model("qwen3.5:9b"),
            "Qwen/Qwen2.5-7B-Instruct"
        );
        assert_eq!(
            cfg.resolve_cloud_model("other:model"),
            "meta-llama/Llama-3.3-70B-Instruct"
        );
    }

    #[test]
    fn test_parse_model_map_valid() {
        let m = parse_model_map("a:1=X/Y,b:2=Z/W");
        assert_eq!(m.get("a:1").map(|s| s.as_str()), Some("X/Y"));
        assert_eq!(m.get("b:2").map(|s| s.as_str()), Some("Z/W"));
    }

    #[test]
    fn test_parse_model_map_empty() {
        let m = parse_model_map("");
        assert!(m.is_empty());
    }

    #[test]
    fn test_parse_model_map_ignores_bad_entries() {
        let m = parse_model_map("no-equals,a=b,=empty");
        assert_eq!(m.len(), 1);
        assert_eq!(m.get("a").map(|s| s.as_str()), Some("b"));
    }

    #[test]
    fn test_proxy_api_url_strips_trailing_slash() {
        let cfg = Config::from_start_args(
            valid_wallet(),
            "qwen3.5:9b".into(),
            "quic.dria.co:4001".into(),
            1,
            "https://api.example.com/v1/".into(),
            "key".into(),
            "model".into(),
            "".into(),
            false,
            false,
        )
        .unwrap();
        assert_eq!(cfg.proxy_api_url, "https://api.example.com/v1");
    }
}
