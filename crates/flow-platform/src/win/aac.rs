//! Media Foundation's AAC encoder MFT, per Microsoft's contract: 16-bit PCM in, raw AAC out
//! (`MF_MT_AAC_PAYLOAD_TYPE` 0), each output sample one 1024-sample frame, every input sample with a
//! time and a duration. Created and used on one thread.
use crate::win_rules::aac_frame_ticks;
use crate::{AudioEncoder, AudioFailure};
use ::windows::Win32::Media::MediaFoundation::*;
use ::windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx};
use ::windows::core::{Error, Result};
use std::mem::ManuallyDrop;

/// `CLSID_AACMFTEncoder` from wmcodecdsp.h; the crate's metadata leaves it out.
const CLSID_AACMFT_ENCODER: ::windows::core::GUID = ::windows::core::GUID::from_u128(0x93af0c51_2275_45d2_a35b_f2ba21caed00);
const FAILED: AudioFailure = "encoder_failed";

pub struct Aac {
    transform: IMFTransform,
    output_size: u32,
    ticks: i64,
    frames: i64,
}

impl Aac {
    pub fn new(channels: usize, bytes_per_second: u32) -> Result<Aac> {
        unsafe {
            // Balanced by the thread ending; the segment's writer thread does nothing else.
            CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
            MFStartup(MF_VERSION, MFSTARTUP_LITE)?;
            let transform: IMFTransform = CoCreateInstance(&CLSID_AACMFT_ENCODER, None, CLSCTX_INPROC_SERVER)?;
            let audio_type = |subtype: &::windows::core::GUID| -> Result<IMFMediaType> {
                let t = MFCreateMediaType()?;
                t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
                t.SetGUID(&MF_MT_SUBTYPE, subtype)?;
                t.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
                t.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, 48_000)?;
                t.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, channels as u32)?;
                Ok(t)
            };
            let input = audio_type(&MFAudioFormat_PCM)?;
            transform.SetInputType(0, &input, 0)?;
            let output = audio_type(&MFAudioFormat_AAC)?;
            output.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bytes_per_second)?;
            output.SetUINT32(&MF_MT_AAC_PAYLOAD_TYPE, 0)?;
            transform.SetOutputType(0, &output, 0)?;
            let output_size = transform.GetOutputStreamInfo(0)?.cbSize.max(8192);
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
            Ok(Aac { transform, output_size, ticks: aac_frame_ticks(), frames: 0 })
        }
    }

    fn input_sample(&mut self, pcm: &[i16]) -> Result<IMFSample> {
        unsafe {
            let size = size_of_val(pcm) as u32;
            let buffer = MFCreateMemoryBuffer(size)?;
            let mut data = std::ptr::null_mut();
            buffer.Lock(&mut data, None, None)?;
            std::ptr::copy_nonoverlapping(pcm.as_ptr().cast::<u8>(), data, size as usize);
            buffer.Unlock()?;
            buffer.SetCurrentLength(size)?;
            let sample = MFCreateSample()?;
            sample.AddBuffer(&buffer)?;
            // Time starts at one frame: Microsoft asks for a nonzero time on every input sample.
            self.frames += 1;
            sample.SetSampleTime(self.frames * self.ticks)?;
            sample.SetSampleDuration(self.ticks)?;
            Ok(sample)
        }
    }

    /// Every output sample the transform has ready.
    fn collect(&mut self, out: &mut dyn FnMut(&[u8]) -> std::result::Result<(), AudioFailure>) -> std::result::Result<(), EncodeError> {
        unsafe {
            loop {
                let sample = MFCreateSample()?;
                sample.AddBuffer(&MFCreateMemoryBuffer(self.output_size)?)?;
                let mut result = [MFT_OUTPUT_DATA_BUFFER { dwStreamID: 0, pSample: ManuallyDrop::new(Some(sample)), dwStatus: 0, pEvents: ManuallyDrop::new(None) }];
                let mut status = 0;
                let outcome = self.transform.ProcessOutput(0, &mut result, &mut status);
                let produced = ManuallyDrop::take(&mut result[0].pSample);
                drop(ManuallyDrop::take(&mut result[0].pEvents));
                match outcome {
                    Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(()),
                    Err(e) => return Err(e.into()),
                    Ok(()) => {}
                }
                let sample = produced.ok_or(EncodeError::Out(FAILED))?;
                let buffer = sample.ConvertToContiguousBuffer()?;
                let (mut data, mut length) = (std::ptr::null_mut(), 0u32);
                buffer.Lock(&mut data, None, Some(&mut length))?;
                let written = if length > 0 { out(std::slice::from_raw_parts(data, length as usize)) } else { Ok(()) };
                buffer.Unlock()?;
                written.map_err(EncodeError::Out)?;
            }
        }
    }
}

enum EncodeError {
    Encoder,
    Out(AudioFailure),
}
impl From<Error> for EncodeError {
    fn from(_: Error) -> Self {
        EncodeError::Encoder
    }
}
fn reason(result: std::result::Result<(), EncodeError>) -> std::result::Result<(), AudioFailure> {
    result.map_err(|e| match e {
        EncodeError::Encoder => FAILED,
        EncodeError::Out(reason) => reason,
    })
}

impl AudioEncoder for Aac {
    fn encode(&mut self, pcm: &[i16], out: &mut dyn FnMut(&[u8]) -> std::result::Result<(), AudioFailure>) -> std::result::Result<(), AudioFailure> {
        let sample = self.input_sample(pcm).map_err(|_| FAILED)?;
        unsafe { self.transform.ProcessInput(0, &sample, 0) }.map_err(|_| FAILED)?;
        reason(self.collect(out))
    }
    fn drain(&mut self, out: &mut dyn FnMut(&[u8]) -> std::result::Result<(), AudioFailure>) -> std::result::Result<(), AudioFailure> {
        unsafe {
            self.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0).map_err(|_| FAILED)?;
            self.transform.ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0).map_err(|_| FAILED)?;
        }
        reason(self.collect(out))
    }
}

impl Drop for Aac {
    fn drop(&mut self) {
        let _ = unsafe { MFShutdown() };
    }
}
