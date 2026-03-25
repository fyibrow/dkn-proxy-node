#![allow(dead_code)]

mod config;
mod error;
mod identity;
mod inference;
mod models;
mod network;
mod setup;
mod stats;
mod update;
mod worker;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use clap::Parser;
use tokio::sync::mpsc;
use tracing_subscriber::EnvFilter;

use config::{Cli, Command, Config};
use identity::Identity;
use models::registry::ModelSpec;
use models::default_registry;
use network::protocol::ModelType;
use network::{NodeMessage, RouterMessage, RouterConnection};
use stats::NodeStats;
use worker::{CompletedTask, Worker};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Load .env file if present (silently ignore if missing)
    let _ = dotenvy::dotenv();

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();

    match cli.command {
        Command::Setup => {
            setup::run_setup().await?;
        }
        Command::Start {
            wallet,
            model,
            router_url,
            max_concurrent,
            proxy_api_url,
            proxy_api_key,
            proxy_default_model,
            proxy_models,
            insecure,
            skip_update,
        } => {
            run_start(
                wallet,
                model,
                router_url,
                max_concurrent,
                proxy_api_url,
                proxy_api_key,
                proxy_default_model,
                proxy_models,
                insecure,
                skip_update,
            )
            .await?;
        }
    }

    Ok(())
}

/// Shared state needed by event handlers.
struct NodeContext {
    identity: Identity,
    config: Config,
    tps: HashMap<String, f64>,
    stats: Arc<NodeStats>,
}

/// Result of a background model engine creation.
struct ModelLoadResult {
    name: String,
    model_type: ModelType,
    result: Result<(inference::InferenceEngine, f64), error::NodeError>,
}

#[allow(clippy::too_many_arguments)]
async fn run_start(
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
) -> anyhow::Result<()> {
    let config = Config::from_start_args(
        wallet,
        model,
        router_url,
        max_concurrent,
        proxy_api_url,
        proxy_api_key,
        proxy_default_model,
        proxy_models,
        insecure,
        skip_update,
    )?;

    let identity = Identity::from_secret_hex(&config.secret_key_hex)?;
    tracing::info!(address = %format!("0x{}", identity.address_hex), "node identity");

    if !config.skip_update {
        match update::check_for_update().await {
            Ok(update::UpdateAction::Force(version)) => {
                tracing::warn!(%version, "mandatory update available, downloading...");
                if let Err(e) = update::perform_update(&version).await {
                    tracing::error!(%e, "auto-update failed, continuing with current version");
                } else {
                    tracing::info!("update complete — please restart the node");
                    return Ok(());
                }
            }
            Ok(update::UpdateAction::Warn(version)) => {
                tracing::warn!(
                    %version,
                    "new patch version available (current: {})",
                    env!("CARGO_PKG_VERSION")
                );
            }
            Ok(update::UpdateAction::UpToDate) => {}
            Err(e) => tracing::debug!(%e, "update check failed"),
        }
    }

    std::fs::create_dir_all(&config.data_dir)?;

    let registry = default_registry();

    // Create cloud inference engines for each advertised model
    let mut engines: HashMap<String, (inference::InferenceEngine, ModelType)> = HashMap::new();
    let mut tps_map: HashMap<String, f64> = HashMap::new();

    for model_name in &config.model_names {
        let model_type = registry
            .get(model_name.as_str())
            .map(|s| s.model_type)
            .unwrap_or(ModelType::Text);

        let (engine, tps) =
            create_cloud_engine(model_name, model_type, &config).await?;

        tracing::info!(
            model = %model_name,
            cloud_model = %config.resolve_cloud_model(model_name),
            tps = %format!("{tps:.1}"),
            "engine ready"
        );
        engines.insert(model_name.clone(), (engine, model_type));
        tps_map.insert(model_name.clone(), tps);
    }

    if engines.is_empty() {
        return Err(error::NodeError::Config("no models loaded".into()).into());
    }

    eprint!("{}", include_str!("../dnet.art"));

    let mut worker = Worker::new(engines, config.max_concurrent);

    // Connect to router
    let mut connection: Option<RouterConnection> = None;
    for url in &config.router_urls {
        match RouterConnection::connect(
            url,
            config.insecure,
            &identity,
            config.model_names.clone(),
            tps_map.clone(),
            worker.capacity(),
        )
        .await
        {
            Ok(conn) => {
                tracing::info!(node_id = %conn.node_id, router = %url, "connected to router");
                connection = Some(conn);
                break;
            }
            Err(e) => tracing::warn!(%e, router = %url, "failed to connect"),
        }
    }
    if connection.is_none() {
        tracing::warn!("all routers unavailable, running in offline mode");
    }

    tracing::info!(
        routers = ?config.router_urls,
        models = ?config.model_names,
        max_concurrent = config.max_concurrent,
        proxy_api = %config.proxy_api_url,
        online = connection.is_some(),
        "node ready"
    );

    let stats = Arc::new(NodeStats::new());
    let mut ctx = NodeContext {
        identity,
        config,
        tps: tps_map,
        stats: Arc::clone(&stats),
    };

    let (model_tx, mut model_rx) = mpsc::unbounded_channel::<ModelLoadResult>();

    let mut stats_interval = tokio::time::interval(Duration::from_secs(60));
    stats_interval.tick().await;

    loop {
        let event = tokio::select! {
            msg = recv_router_msg(&mut connection) => Event::RouterMsg(msg),
            Some(done) = worker.next_completed() => Event::TaskDone(done),
            Some(loaded) = model_rx.recv() => Event::ModelLoaded(loaded),
            _ = stats_interval.tick() => Event::StatsLog,
            _ = tokio::signal::ctrl_c() => Event::Shutdown,
        };

        match event {
            Event::RouterMsg(Ok(Some(msg))) => {
                handle_router_message(msg, &mut worker, &mut connection, &mut ctx, &model_tx)
                    .await;
            }
            Event::RouterMsg(Ok(None)) => {
                tracing::warn!("router stream closed, reconnecting");
                if let Some(ref c) = connection { c.close(); }
                connection = tokio::select! {
                    r = try_reconnect(&ctx, worker.capacity()) => r,
                    _ = tokio::signal::ctrl_c() => {
                        tracing::info!("shutdown during reconnect");
                        break;
                    }
                };
            }
            Event::RouterMsg(Err(e)) => {
                tracing::warn!(%e, "router error, reconnecting");
                if let Some(ref c) = connection { c.close(); }
                connection = tokio::select! {
                    r = try_reconnect(&ctx, worker.capacity()) => r,
                    _ = tokio::signal::ctrl_c() => {
                        tracing::info!("shutdown during reconnect");
                        break;
                    }
                };
            }
            Event::TaskDone(completed) => {
                handle_completed_task(completed, &connection, &ctx.stats);
            }
            Event::ModelLoaded(loaded) => match loaded.result {
                Ok((engine, tps)) => {
                    tracing::info!(model = %loaded.name, tps = %format!("{tps:.1}"), "model loaded");
                    worker.add_engine(loaded.name.clone(), engine, loaded.model_type);
                    ctx.tps.insert(loaded.name, tps);
                }
                Err(e) => {
                    tracing::error!(model = %loaded.name, %e, "model load failed");
                }
            },
            Event::StatsLog => ctx.stats.log_summary(),
            Event::Shutdown => {
                tracing::info!("shutdown signal");
                break;
            }
        }
    }

    // Drain in-flight tasks (30s timeout)
    if worker.has_in_flight() {
        tracing::info!("draining in-flight tasks (30s timeout)");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        loop {
            tokio::select! {
                Some(c) = worker.next_completed() => handle_completed_task(c, &connection, &ctx.stats),
                _ = tokio::time::sleep_until(deadline) => {
                    tracing::warn!("drain timeout, dropping remaining tasks");
                    break;
                }
            }
            if !worker.has_in_flight() { break; }
        }
    }

    if let Some(ref c) = connection { c.close(); }
    tracing::info!("shutdown complete");
    Ok(())
}

// ── Events ────────────────────────────────────────────────────────────────────

enum Event {
    RouterMsg(Result<Option<RouterMessage>, error::NodeError>),
    TaskDone(CompletedTask),
    ModelLoaded(ModelLoadResult),
    StatsLog,
    Shutdown,
}

// ── Helpers ───────────────────────────────────────────────────────────────────

async fn recv_router_msg(
    connection: &mut Option<RouterConnection>,
) -> Result<Option<RouterMessage>, error::NodeError> {
    match connection {
        Some(ref mut conn) => conn.recv().await,
        None => {
            tokio::time::sleep(Duration::from_secs(10)).await;
            Err(error::NodeError::Network("offline, retrying".into()))
        }
    }
}

async fn try_reconnect(
    ctx: &NodeContext,
    capacity: network::protocol::Capacity,
) -> Option<RouterConnection> {
    let mut delay = Duration::from_secs(1);
    for round in 1..=5u32 {
        tracing::info!(round, delay_secs = delay.as_secs(), "reconnecting");
        tokio::time::sleep(delay).await;
        for url in &ctx.config.router_urls {
            match RouterConnection::connect(
                url,
                ctx.config.insecure,
                &ctx.identity,
                ctx.config.model_names.clone(),
                ctx.tps.clone(),
                capacity.clone(),
            )
            .await
            {
                Ok(conn) => {
                    tracing::info!(node_id = %conn.node_id, router = %url, "reconnected");
                    return Some(conn);
                }
                Err(e) => tracing::warn!(%e, router = %url, round, "reconnect failed"),
            }
        }
        delay *= 2;
    }
    tracing::warn!("all reconnect attempts exhausted, going offline");
    None
}

/// Create a cloud inference engine for a Dria model name.
async fn create_cloud_engine(
    model_name: &str,
    model_type: ModelType,
    config: &Config,
) -> Result<(inference::InferenceEngine, f64), error::NodeError> {
    let cloud_model = config.resolve_cloud_model(model_name);
    let is_multimodal = model_type != ModelType::Text;

    let engine = inference::InferenceEngine::new(
        &config.proxy_api_url,
        &config.proxy_api_key,
        &cloud_model,
        is_multimodal,
    )?;

    tracing::info!(
        dria_model = %model_name,
        cloud_model = %cloud_model,
        "testing API connectivity"
    );

    // Run benchmark in blocking thread
    let model_name_owned = model_name.to_string();
    let tps = tokio::task::spawn_blocking(move || engine.benchmark(&model_name_owned).map(|r| (engine, r.generation_tps)))
        .await
        .map_err(|e| error::NodeError::Inference(format!("benchmark join: {e}")))?
        .map(|(engine, tps)| (engine, tps))?;

    Ok(tps)
}

async fn handle_router_message(
    msg: RouterMessage,
    worker: &mut Worker,
    connection: &mut Option<RouterConnection>,
    ctx: &mut NodeContext,
    model_tx: &mpsc::UnboundedSender<ModelLoadResult>,
) {
    match msg {
        RouterMessage::TaskAssignment {
            task_id,
            model,
            messages,
            max_tokens,
            temperature,
            validation,
            stream,
            response_format,
        } => {
            tracing::info!(%task_id, %model, stream, "task assigned");
            let stream_tx = if stream {
                connection.as_ref().map(|c| c.sender())
            } else {
                None
            };
            match worker.try_accept(
                task_id,
                &model,
                messages,
                max_tokens,
                temperature,
                validation,
                stream,
                stream_tx,
                response_format,
            ) {
                Ok(()) => tracing::debug!(%task_id, "task accepted"),
                Err(reason) => {
                    ctx.stats.record_rejected();
                    tracing::warn!(%task_id, ?reason, "task rejected");
                    if let Some(ref conn) = connection {
                        let _ = conn.send(NodeMessage::TaskRejected { task_id, reason });
                    }
                }
            }
        }
        RouterMessage::Ping => {
            tracing::debug!("ping");
            if let Some(ref conn) = connection {
                let status = NodeMessage::StatusUpdate {
                    models: worker.model_names(),
                    capacity: worker.capacity(),
                    version: env!("CARGO_PKG_VERSION").to_string(),
                    stats: Some(ctx.stats.snapshot()),
                };
                if let Err(e) = conn.send(status) {
                    tracing::error!(%e, "failed to send status");
                }
            }
        }
        RouterMessage::Challenge { challenge } => {
            tracing::debug!("challenge received");
            let (sig, recid) = ctx.identity.sign(&challenge);
            if let Some(ref conn) = connection {
                let resp = NodeMessage::ChallengeResponse {
                    challenge,
                    signature: sig.serialize().to_vec(),
                    recovery_id: recid.serialize(),
                };
                if let Err(e) = conn.send(resp) {
                    tracing::error!(%e, "failed to send challenge response");
                }
            }
        }
        RouterMessage::ValidationTask {
            validation_id,
            model,
            messages,
            output_text,
            logprob_every_n,
            logprob_top_k,
        } => {
            tracing::info!(%validation_id, %model, "validation task");
            match worker.try_accept_validation(
                validation_id,
                &model,
                messages,
                output_text,
                logprob_every_n,
                logprob_top_k,
            ) {
                Ok(()) => tracing::debug!(%validation_id, "validation accepted"),
                Err(reason) => tracing::warn!(%validation_id, ?reason, "validation rejected"),
            }
        }
        RouterMessage::ModelRegistryUpdate { entries } => {
            tracing::info!(count = entries.len(), "model registry update");

            let desired: HashMap<&str, _> = entries.iter().map(|e| (e.name.as_str(), e)).collect();

            // Remove stale models
            for name in &worker.model_names() {
                if !desired.contains_key(name.as_str()) {
                    tracing::info!(model = %name, "removing stale model");
                    worker.remove_engine(name);
                    ctx.tps.remove(name);
                }
            }

            // Create engines for new models — collect all needed data before spawning
            let new_models: Vec<_> = entries
                .iter()
                .filter(|e| !worker.has_model(&e.name))
                .map(|e| {
                    (
                        e.name.clone(),
                        e.model_type,
                        ModelSpec::from_registry_entry(e),
                        ctx.config.proxy_api_url.clone(),
                        ctx.config.proxy_api_key.clone(),
                        ctx.config.resolve_cloud_model(&e.name),
                    )
                })
                .collect();

            for (name, model_type, spec, api_url, api_key, cloud_model) in new_models {
                let tx = model_tx.clone();
                let name_clone = name.clone();

                tracing::info!(model = %name, "spawning cloud engine for new model");
                tokio::spawn(async move {
                    let result = tokio::task::spawn_blocking(move || {
                        let is_multimodal = spec.model_type != ModelType::Text;
                        let engine = inference::InferenceEngine::new(
                            &api_url,
                            &api_key,
                            &cloud_model,
                            is_multimodal,
                        )?;
                        let tps = engine.benchmark(&name_clone)?.generation_tps;
                        Ok::<_, error::NodeError>((engine, tps))
                    })
                    .await
                    .map_err(|e| error::NodeError::Inference(format!("join: {e}")))
                    .and_then(|r| r);

                    let _ = tx.send(ModelLoadResult { name, model_type, result });
                });
            }
        }
    }
}

fn handle_completed_task(
    completed: CompletedTask,
    connection: &Option<RouterConnection>,
    stats: &NodeStats,
) {
    match completed.result {
        Ok(msg) => {
            let tokens = match &msg {
                NodeMessage::TaskResult { stats: ts, .. } => ts.tokens_generated,
                _ => 0,
            };
            stats.record_completed(tokens);
            tracing::info!(task_id = %completed.task_id, stream = completed.stream, "task complete");
            if completed.stream {
                return; // streaming tasks already sent tokens inline
            }
            if let Some(ref conn) = connection {
                if let Err(e) = conn.send(msg) {
                    tracing::error!(%e, task_id = %completed.task_id, "failed to send result");
                }
            }
        }
        Err(e) => {
            stats.record_failed();
            tracing::error!(%e, task_id = %completed.task_id, "task failed");
            if let Some(ref conn) = connection {
                let _ = conn.send(NodeMessage::StreamError {
                    task_id: completed.task_id,
                    error: e.to_string(),
                });
            }
        }
    }
}
