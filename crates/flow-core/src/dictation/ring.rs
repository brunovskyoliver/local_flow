//! `AudioCaptureRing.c`: one real-time producer, one reader, fixed capacity, no locks or allocation
//! after `new`. A callback goes in whole or not at all; overflow latches and closes the ring.
use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU8, AtomicU64, AtomicUsize, Ordering::*};

pub const SLOT_FRAMES: usize = 4096;
pub const SLOTS: usize = 32;
const MAX_CHANNELS: usize = 8;

/// A latched capture failure. Values match the C ring's, plus what only the reader sees.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Overflow = 1,
    Unsupported = 2,
    DeviceLost = 3,
    Sleep = 4,
}

pub struct Ring {
    rate: u32,
    channels: usize,
    data: UnsafeCell<Box<[f32]>>,
    write: AtomicUsize,
    read: AtomicUsize,
    accepting: AtomicBool,
    copying: AtomicUsize,
    failure: AtomicU8,
    /// Nanoseconds on the producer's clock of the first callback with a non-zero sample; -1 before.
    first_audio: AtomicI64,
    max_delay_ns: AtomicU64,
    high_water: AtomicUsize,
}

// One producer and one reader touch disjoint frames, as `write` and `read` order them.
unsafe impl Sync for Ring {}
unsafe impl Send for Ring {}

impl Ring {
    /// `None` outside 8-192 kHz or 1-8 channels, the C ring's refusal.
    pub fn new(rate: u32, channels: usize) -> Option<Ring> {
        if !(8_000..=192_000).contains(&rate) || !(1..=MAX_CHANNELS).contains(&channels) {
            return None;
        }
        Some(Ring {
            rate,
            channels,
            data: UnsafeCell::new(vec![0.; SLOTS * SLOT_FRAMES * channels].into_boxed_slice()),
            write: AtomicUsize::new(0),
            read: AtomicUsize::new(0),
            accepting: AtomicBool::new(true),
            copying: AtomicUsize::new(0),
            failure: AtomicU8::new(0),
            first_audio: AtomicI64::new(-1),
            max_delay_ns: AtomicU64::new(0),
            high_water: AtomicUsize::new(0),
        })
    }
    pub fn rate(&self) -> u32 {
        self.rate
    }
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Real-time safe. `interleaved` holds whole frames; `now_ns` and `delay_ns` come from the callback.
    pub fn push(&self, interleaved: &[f32], now_ns: i64, delay_ns: u64) {
        self.copying.fetch_add(1, SeqCst);
        if self.accepting.load(SeqCst) {
            self.push_inner(interleaved, now_ns, delay_ns);
        }
        self.copying.fetch_sub(1, SeqCst);
    }

    fn push_inner(&self, interleaved: &[f32], now_ns: i64, delay_ns: u64) {
        let frames = interleaved.len() / self.channels;
        if frames > SLOT_FRAMES {
            self.fail(Failure::Unsupported);
            return;
        }
        let capacity = SLOTS * SLOT_FRAMES;
        let (write, read) = (self.write.load(Relaxed), self.read.load(Acquire));
        if write - read + frames > capacity {
            self.fail(Failure::Overflow);
            return;
        }
        if self.first_audio.load(Relaxed) < 0 && interleaved.iter().any(|s| *s != 0.) {
            self.first_audio.store(now_ns.max(0), Relaxed);
        }
        self.max_delay_ns.fetch_max(delay_ns, Relaxed);
        // Safety: frames in write..write+frames aren't visible to the reader until the store below.
        let data = unsafe { &mut *self.data.get() };
        let total = capacity * self.channels;
        let start = write * self.channels % total;
        let n = interleaved.len().min(total - start);
        data[start..start + n].copy_from_slice(&interleaved[..n]);
        data[..interleaved.len() - n].copy_from_slice(&interleaved[n..]);
        self.write.store(write + frames, Release);
        self.high_water.fetch_max(write + frames - read, Relaxed);
    }

    /// Appends what's there to `out`, interleaved. The reader's side.
    pub fn pop(&self, out: &mut Vec<f32>) {
        let (write, read) = (self.write.load(Acquire), self.read.load(Relaxed));
        if write == read {
            return;
        }
        let capacity = SLOTS * SLOT_FRAMES;
        let total = capacity * self.channels;
        let (start, len) = (read * self.channels % total, (write - read) * self.channels);
        // Safety: frames in read..write are published and the producer won't touch them until `read` moves.
        let data = unsafe { &*self.data.get() };
        let n = len.min(total - start);
        out.extend_from_slice(&data[start..start + n]);
        out.extend_from_slice(&data[..len - n]);
        self.read.store(write, Release);
    }

    /// The first failure wins. Accepting stops at once.
    pub fn fail(&self, failure: Failure) {
        let _ = self.failure.compare_exchange(0, failure as u8, SeqCst, SeqCst);
        self.accepting.store(false, SeqCst);
    }
    pub fn failure(&self) -> Option<Failure> {
        match self.failure.load(SeqCst) {
            1 => Some(Failure::Overflow),
            2 => Some(Failure::Unsupported),
            3 => Some(Failure::DeviceLost),
            4 => Some(Failure::Sleep),
            _ => None,
        }
    }
    /// True once a callback carried a non-zero sample.
    pub fn audio_flowing(&self) -> bool {
        self.first_audio.load(Relaxed) >= 0
    }
    pub fn max_delay_ns(&self) -> u64 {
        self.max_delay_ns.load(Relaxed)
    }
    pub fn high_water_frames(&self) -> usize {
        self.high_water.load(Relaxed)
    }
    pub fn free_frames(&self) -> usize {
        SLOTS * SLOT_FRAMES - (self.write.load(Acquire) - self.read.load(Acquire))
    }
    /// Closes the ring and waits out a callback in progress. No more samples after this.
    pub fn close_and_join(&self) {
        self.accepting.store(false, SeqCst);
        while self.copying.load(SeqCst) != 0 {
            std::thread::yield_now();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_formats_the_c_ring_refuses() {
        assert!(Ring::new(7_999, 1).is_none());
        assert!(Ring::new(192_001, 1).is_none());
        assert!(Ring::new(48_000, 0).is_none());
        assert!(Ring::new(48_000, 9).is_none());
        assert!(Ring::new(48_000, 8).is_some());
    }

    #[test]
    fn wraps_and_keeps_order_across_threads() {
        let ring = std::sync::Arc::new(Ring::new(48_000, 2).unwrap());
        let producer = ring.clone();
        let total = (SLOTS * SLOT_FRAMES * 4) as i32;
        let writer = std::thread::spawn(move || {
            let mut next = 0;
            let mut buffer = vec![0.; 512 * 2];
            while next < total {
                if producer.write.load(Relaxed) - producer.read.load(Relaxed) + 512 > SLOTS * SLOT_FRAMES {
                    std::thread::yield_now();
                    continue;
                }
                for frame in buffer.chunks_mut(2) {
                    frame[0] = next as f32;
                    frame[1] = -(next as f32);
                    next += 1;
                }
                producer.push(&buffer, 1, 5);
            }
        });
        let mut out = Vec::new();
        while out.len() < total as usize * 2 {
            ring.pop(&mut out);
        }
        writer.join().unwrap();
        for (i, frame) in out.chunks(2).enumerate() {
            assert_eq!(frame, [i as f32, -(i as f32)]);
        }
        assert!(ring.failure().is_none());
        assert_eq!(ring.max_delay_ns(), 5);
    }

    #[test]
    fn overflow_latches_and_drops_the_whole_callback() {
        let ring = Ring::new(16_000, 1).unwrap();
        let full = vec![1.; SLOT_FRAMES];
        for _ in 0..SLOTS {
            ring.push(&full, 0, 0);
        }
        assert_eq!(ring.failure(), None);
        ring.push(&[2.], 0, 0);
        assert_eq!(ring.failure(), Some(Failure::Overflow));
        let mut out = Vec::new();
        ring.pop(&mut out);
        assert_eq!(out.len(), SLOTS * SLOT_FRAMES);
        assert!(out.iter().all(|s| *s == 1.), "the callback that overflowed stored nothing");
        ring.push(&[3.], 0, 0);
        ring.pop(&mut out);
        assert_eq!(out.len(), SLOTS * SLOT_FRAMES, "closed after overflow");
        ring.fail(Failure::DeviceLost);
        assert_eq!(ring.failure(), Some(Failure::Overflow), "the first failure wins");
    }

    #[test]
    fn too_long_a_callback_is_unsupported_and_silence_is_not_audio() {
        let ring = Ring::new(16_000, 1).unwrap();
        ring.push(&[0.; 64], 0, 0);
        assert!(!ring.audio_flowing());
        ring.push(&[0.5], 7, 0);
        assert!(ring.audio_flowing());
        ring.push(&vec![0.; SLOT_FRAMES + 1], 0, 0);
        assert_eq!(ring.failure(), Some(Failure::Unsupported));
    }

    #[test]
    fn close_stops_accepting() {
        let ring = Ring::new(16_000, 1).unwrap();
        ring.close_and_join();
        ring.push(&[1.], 0, 0);
        let mut out = Vec::new();
        ring.pop(&mut out);
        assert!(out.is_empty());
        assert_eq!(ring.failure(), None);
    }
}
