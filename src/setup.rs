/// Interactive setup: verify proxy configuration and API connectivity.
pub async fn run_setup() -> Result<(), crate::error::NodeError> {
    let _ = dotenvy::dotenv();

    println!();
    println!("  Dria Node — Cloud API Proxy Setup");
    println!();

    let api_url = std::env::var("PROXY_API_URL")
        .unwrap_or_else(|_| "https://api.hyperbolic.xyz/v1".into());
    let api_key = std::env::var("PROXY_API_KEY").unwrap_or_default();
    let default_model = std::env::var("PROXY_DEFAULT_MODEL")
        .unwrap_or_else(|_| "meta-llama/Llama-3.3-70B-Instruct".into());
    let proxy_models = std::env::var("PROXY_MODELS").unwrap_or_default();
    let dria_wallet = std::env::var("DRIA_WALLET")
        .map(|k| {
            let hex = k.strip_prefix("0x").unwrap_or(&k).to_string();
            if hex.len() == 64 { "✓ set".to_string() } else { "✗ invalid length".to_string() }
        })
        .unwrap_or_else(|_| "✗ not set".to_string());
    let dria_models = std::env::var("DRIA_MODELS").unwrap_or_else(|_| "(not set)".into());

    println!("  Current configuration:");
    println!("    DRIA_WALLET        : {dria_wallet}");
    println!("    DRIA_MODELS        : {dria_models}");
    println!("    PROXY_API_URL      : {api_url}");
    println!("    PROXY_API_KEY      : {}", mask_key(&api_key));
    println!("    PROXY_DEFAULT_MODEL: {default_model}");
    if !proxy_models.is_empty() {
        println!("    PROXY_MODELS       : {proxy_models}");
    }
    println!();

    if api_key.is_empty() {
        println!("  ERROR: PROXY_API_KEY is not set.");
        println!("  Set it in .env or as an environment variable:");
        println!("    PROXY_API_KEY=your_api_key_here");
        println!();
        return Ok(());
    }

    // Test API connectivity
    println!("  Testing API connectivity...");

    let engine = crate::inference::InferenceEngine::new(
        &api_url,
        &api_key,
        &default_model,
        false,
    )?;

    match tokio::task::spawn_blocking(move || engine.benchmark(&default_model)).await {
        Ok(Ok(result)) => {
            println!("  API test PASSED  ({:.1} tok/s reported)", result.generation_tps);
        }
        Ok(Err(e)) => {
            println!("  API test FAILED: {e}");
            println!();
            println!("  Check that PROXY_API_URL and PROXY_API_KEY are correct.");
            return Ok(());
        }
        Err(e) => {
            println!("  API test error: {e}");
            return Ok(());
        }
    }

    println!();
    println!("  Everything looks good! Start the node with:");
    println!();
    println!("    dria-node start \\");
    println!("      --wallet $DRIA_WALLET \\");
    println!("      --model qwen3.5:9b \\");
    println!("      --proxy-api-key $PROXY_API_KEY");
    println!();

    Ok(())
}

fn mask_key(key: &str) -> String {
    if key.is_empty() {
        return "(not set)".into();
    }
    if key.len() <= 8 {
        return "****".into();
    }
    format!("{}...{}", &key[..4], &key[key.len() - 4..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mask_key_empty() {
        assert_eq!(mask_key(""), "(not set)");
    }

    #[test]
    fn test_mask_key_short() {
        assert_eq!(mask_key("abc"), "****");
    }

    #[test]
    fn test_mask_key_long() {
        let masked = mask_key("sk-abcdefghijklmnop");
        assert!(masked.starts_with("sk-a"));
        assert!(masked.ends_with("mnop"));
        assert!(masked.contains("..."));
    }
}
