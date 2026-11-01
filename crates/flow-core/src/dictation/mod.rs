//! Dictation logic with no OS APIs. Process spawning and key capture stay in `flow-platform`.
pub mod hotkey;
pub mod insert;
pub mod lifecycle;
pub mod normalize;
pub mod provision;
pub mod remote;
pub mod resample;
pub mod retrier;
pub mod rewrite;
pub mod ring;
pub mod session;
pub mod spool;
pub mod worker;
