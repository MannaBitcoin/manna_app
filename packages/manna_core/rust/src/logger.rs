use std::sync::{Once, OnceLock};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_error::ErrorLayer;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::Registry;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

static INIT: Once = Once::new();
static LOG_GUARD: OnceLock<WorkerGuard> = OnceLock::new();

pub fn init_logger(logs_dir_path: String, target: String) {
    INIT.call_once(|| {
        let (non_blocking_writer, guard) = tracing_appender::non_blocking(
            tracing_appender::rolling::never(&logs_dir_path, "rust.jsonl"),
        );
        if LOG_GUARD.set(guard).is_err() {
            eprintln!("Logger guard already set");
        }

        let json_layer = tracing_subscriber::fmt::layer()
            .json()
            .with_writer(non_blocking_writer)
            .with_ansi(false)
            .with_target(true)
            .with_thread_names(false)
            .with_file(true)
            .with_line_number(true)
            .with_current_span(true)
            .with_span_list(true);

        let env_filter =
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
        let subscriber = Registry::default()
            .with(env_filter)
            .with(ErrorLayer::default())
            .with(json_layer);

        if let Err(e) = subscriber.try_init() {
            eprintln!("Failed to initialize tracing subscriber: {:?}", e);
        } else {
            tracing::info!("Rust logger initialized from {}", target);
        }
    });
}
