pub threadlocal var is_audio_thread: bool = false;
/// Thread-local flag set when running inside libz_jobs worker/help loop.
/// Used as a reentrancy guard for CLAP thread-pool requests.
pub threadlocal var in_jobs_worker: bool = false;
/// Nesting depth for CLAP `thread_pool` requests on this thread.
pub threadlocal var clap_threadpool_depth: u32 = 0;
