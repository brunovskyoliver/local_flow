//! Dictation logic with no OS APIs. Process spawning and key capture stay in `flow-platform`.
pub mod hotkey;
pub mod insert;
pub mod lifecycle;
pub mod normalize;
pub mod resample;
pub mod ring;
pub mod session;
pub mod spool;
pub mod worker;
