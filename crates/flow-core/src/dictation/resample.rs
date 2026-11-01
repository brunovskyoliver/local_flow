//! Any device format to the 16 kHz mono the recognizer takes: average the channels, then a streaming
//! Blackman-windowed sinc low-passed under the new Nyquist.
const TARGET: f64 = 16_000.;
const ZERO_CROSSINGS: f64 = 16.;
const TABLE_PER_CROSSING: usize = 256;

pub struct Converter {
    channels: usize,
    /// Input samples per output sample.
    step: f64,
    /// Sinc scale: below 1 when downsampling.
    cutoff: f64,
    half_width: f64,
    table: Vec<f32>,
    history: Vec<f32>,
    /// Input samples dropped from the front of `history`.
    dropped: u64,
    /// Output samples made.
    made: u64,
}

impl Converter {
    pub fn new(rate: u32, channels: usize) -> Converter {
        let step = rate as f64 / TARGET;
        // 0.95: the transition band fits under 8 kHz.
        let cutoff = (0.95 / step).min(1.);
        let size = ZERO_CROSSINGS as usize * TABLE_PER_CROSSING + 2;
        let table = (0..size)
            .map(|i| {
                let x = i as f64 / TABLE_PER_CROSSING as f64;
                let u = (x / ZERO_CROSSINGS).min(1.);
                let window = 0.42 + 0.5 * (std::f64::consts::PI * u).cos() + 0.08 * (2. * std::f64::consts::PI * u).cos();
                let sinc = if x == 0. { 1. } else { (std::f64::consts::PI * x).sin() / (std::f64::consts::PI * x) };
                (sinc * window) as f32
            })
            .collect();
        Converter { channels: channels.max(1), step, cutoff, half_width: ZERO_CROSSINGS / cutoff, table, history: Vec::new(), dropped: 0, made: 0 }
    }

    fn kernel(&self, x: f64) -> f32 {
        let at = x.abs() * self.cutoff * TABLE_PER_CROSSING as f64;
        let (i, frac) = (at as usize, at.fract() as f32);
        match (self.table.get(i), self.table.get(i + 1)) {
            (Some(a), Some(b)) => a + (b - a) * frac,
            _ => 0.,
        }
    }

    /// Interleaved in, finite samples within -1..=1 appended to `out`.
    pub fn push(&mut self, interleaved: &[f32], out: &mut Vec<f32>) {
        for frame in interleaved.chunks_exact(self.channels) {
            let sum: f32 = frame.iter().map(|s| if s.is_finite() { *s } else { 0. }).sum();
            self.history.push(sum / self.channels as f32);
        }
        if self.step == 1. {
            out.extend(self.history.drain(..).map(|s| s.clamp(-1., 1.)));
            return;
        }
        self.run(0., out);
    }

    fn run(&mut self, extra: f64, out: &mut Vec<f32>) {
        let end = self.dropped as f64 + self.history.len() as f64 + extra;
        loop {
            let at = self.made as f64 * self.step;
            if at + self.half_width >= end {
                break;
            }
            let first = (at - self.half_width).ceil().max(self.dropped as f64) as u64;
            let last = ((at + self.half_width) as u64).min(self.dropped + self.history.len() as u64);
            let mut sum = 0.;
            for n in first..last {
                sum += self.history[(n - self.dropped) as usize] * self.kernel(n as f64 - at);
            }
            out.push((sum * self.cutoff as f32).clamp(-1., 1.));
            self.made += 1;
        }
        let keep_from = ((self.made as f64 * self.step - self.half_width).floor().max(0.) as u64).max(self.dropped);
        let drop = ((keep_from - self.dropped) as usize).min(self.history.len());
        self.history.drain(..drop);
        self.dropped += drop as u64;
    }

    /// The last half filter width, read as if silence followed.
    pub fn finish(&mut self, out: &mut Vec<f32>) {
        if self.step != 1. {
            self.run(self.half_width + 1., out);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(rate: u32, hz: f64, seconds: f64) -> Vec<f32> {
        (0..(rate as f64 * seconds) as usize).map(|n| (2. * std::f64::consts::PI * hz * n as f64 / rate as f64).sin() as f32 * 0.8).collect()
    }
    fn rms(s: &[f32]) -> f32 {
        (s.iter().map(|v| v * v).sum::<f32>() / s.len() as f32).sqrt()
    }
    fn convert(rate: u32, input: &[f32], chunk: usize) -> Vec<f32> {
        let mut c = Converter::new(rate, 1);
        let mut out = Vec::new();
        for part in input.chunks(chunk) {
            c.push(part, &mut out);
        }
        c.finish(&mut out);
        out
    }

    #[test]
    fn keeps_speech_and_removes_what_would_alias() {
        for rate in [44_100, 48_000, 96_000] {
            let kept = convert(rate, &tone(rate, 440., 1.), 512);
            assert!((kept.len() as i64 - 16_000).abs() < 40, "{rate}: {}", kept.len());
            let middle = &kept[1000..15000];
            assert!((rms(middle) - 0.8 / 2f32.sqrt()).abs() < 0.01, "{rate}: {}", rms(middle));
            // 440 Hz stays 440 Hz: a sample period's worth of phase over the second.
            let crossings = middle.windows(2).filter(|w| w[0] <= 0. && w[1] > 0.).count();
            assert!((crossings as i64 - (440. * 14000. / 16000.) as i64).abs() <= 1, "{crossings}");
        }
        let gone = convert(48_000, &tone(48_000, 10_000., 1.), 512);
        assert!(rms(&gone[1000..15000]) < 0.002, "{}", rms(&gone[1000..15000]));
    }

    #[test]
    fn chunking_does_not_change_the_result() {
        let input = tone(44_100, 1000., 0.5);
        let (a, b) = (convert(44_100, &input, 137), convert(44_100, &input, 4096));
        assert_eq!(a.len(), b.len());
        assert!(a.iter().zip(&b).all(|(x, y)| (x - y).abs() < 1e-6));
    }

    #[test]
    fn averages_channels_passes_16k_and_cleans_bad_samples() {
        let mut c = Converter::new(16_000, 2);
        let mut out = Vec::new();
        c.push(&[0.5, 0.25, f32::NAN, 1., 3., 3.], &mut out);
        assert_eq!(out, [0.375, 0.5, 1.]);
    }

    #[test]
    fn history_stays_bounded() {
        let mut c = Converter::new(48_000, 1);
        let mut out = Vec::new();
        for _ in 0..200 {
            c.push(&[0.1; 4096], &mut out);
            out.clear();
        }
        assert!(c.history.len() < 200, "{}", c.history.len());
    }
}
