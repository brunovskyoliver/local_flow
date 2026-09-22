#include "whisper.h"
#include "json.hpp"

// whisper.cpp vendors dr_wav inside miniaudio. Compile only its file decoder;
// microphone ownership and recording permissions stay in the macOS app.
#define MA_NO_DEVICE_IO
#define MA_NO_THREADING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_NO_FLAC
#define MA_NO_MP3
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <unordered_set>
#include <utility>
#include <variant>
#include <vector>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/event.h>
#elif defined(__linux__)
#include <signal.h>
#include <sys/prctl.h>
#endif

namespace {

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
constexpr size_t maxRequestBytes = 1024 * 1024;
constexpr size_t maxVocabularyBytes = 384 * 1024;
constexpr size_t maxPromptBytes = 8192;
constexpr size_t minSamples = WHISPER_SAMPLE_RATE / 5;
constexpr size_t maxSamples = WHISPER_SAMPLE_RATE * 180;

void emit(const json &event) {
    std::cout << event.dump(-1, ' ', false, json::error_handler_t::replace) << '\n' << std::flush;
    if (!std::cout) std::_Exit(0); // The app closed its end of the pipe.
}

void emitError(const std::string &message, const std::string &id = {}) {
    json event = {{"type", "error"}, {"message", message}};
    if (!id.empty()) event["id"] = id;
    emit(event);
}

void libraryLog(ggml_log_level level, const char *message, void *) {
    // No debug logs: upstream debug output can contain decoded tokens.
    if (level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN) {
        std::fputs(message, stderr);
    }
}

void watchParent() {
    const pid_t parent = getppid();
    if (parent <= 1) std::_Exit(0);
#if defined(__linux__)
    // Kill even during an uninterruptible model call if the supervisor dies.
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) == 0) {
        if (getppid() != parent) std::_Exit(0);
        return;
    }
#elif defined(__APPLE__)
    const int queue = kqueue();
    struct kevent change;
    EV_SET(&change, parent, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, nullptr);
    if (queue >= 0 && kevent(queue, &change, 1, nullptr, 0, nullptr) == 0) {
        std::thread([queue] {
            struct kevent event;
            while (kevent(queue, nullptr, 0, &event, 1, nullptr) < 0 && errno == EINTR) {}
            std::_Exit(0);
        }).detach();
        return;
    }
    if (queue >= 0) close(queue);
#endif
    std::thread([parent] {
        while (getppid() == parent) std::this_thread::sleep_for(std::chrono::seconds(1));
        std::_Exit(0);
    }).detach();
}

struct Audio {
    std::vector<float> samples;
    double duration;
    bool silent;
};

std::variant<Audio, std::string> readAudio(const std::string &path) {
    std::error_code error;
    if (!std::filesystem::is_regular_file(path, error)) {
        return "The recording is missing or is not a regular file.";
    }
    const auto bytes = std::filesystem::file_size(path, error);
    if (error || bytes > 32 * 1024 * 1024) {
        return "The recording cannot be read or exceeds the 32 MB limit.";
    }

    ma_dr_wav wav{};
    if (!ma_dr_wav_init_file(&wav, path.c_str(), nullptr)) {
        return "The recording is not a readable WAV file.";
    }
    const auto finish = [&wav](ma_dr_wav *) { ma_dr_wav_uninit(&wav); };
    const std::unique_ptr<ma_dr_wav, decltype(finish)> guard(&wav, finish);
    if (wav.channels != 1 || wav.sampleRate != WHISPER_SAMPLE_RATE) {
        return "The recording must be mono, 16 kHz WAV audio.";
    }
    if (!((wav.translatedFormatTag == 1 && wav.bitsPerSample == 16) ||
          (wav.translatedFormatTag == 3 && wav.bitsPerSample == 32))) {
        return "The recording must use PCM16 or float32 WAV samples.";
    }
    if (wav.totalPCMFrameCount < minSamples || wav.totalPCMFrameCount > maxSamples) {
        return "Record between 0.2 seconds and 3 minutes of audio.";
    }

    std::vector<float> samples(static_cast<size_t>(wav.totalPCMFrameCount));
    const auto frames = ma_dr_wav_read_pcm_frames_f32(&wav, samples.size(), samples.data());
    if (frames != samples.size()) return "The recording is incomplete.";

    double squareSum = 0;
    float peak = 0;
    for (auto &sample : samples) {
        if (!std::isfinite(sample)) return "The recording contains invalid audio samples.";
        sample = std::clamp(sample, -1.0f, 1.0f);
        squareSum += static_cast<double>(sample) * sample;
        peak = std::max(peak, std::abs(sample));
    }
    // This is deliberately conservative. Whisper's no-speech probability does
    // the semantic filtering; an amplitude gate just avoids decoding silence.
    const bool silent = peak < 0.002f || std::sqrt(squareSum / samples.size()) < 0.0003;
    const double duration = static_cast<double>(samples.size()) / WHISPER_SAMPLE_RATE;
    return Audio{std::move(samples), duration, silent};
}

std::string trim(std::string text) {
    constexpr auto space = " \t\r\n";
    const auto first = text.find_first_not_of(space);
    if (first == std::string::npos) return {};
    return text.substr(first, text.find_last_not_of(space) - first + 1);
}

struct Progress {
    const std::string &id;
    int last = -1;
};

void reportProgress(whisper_context *, whisper_state *, int value, void *opaque) {
    auto &progress = *static_cast<Progress *>(opaque);
    value = std::clamp(value, 0, 100);
    if (value <= progress.last) return;
    progress.last = value;
    emit({{"type", "progress"}, {"id", progress.id}, {"value", value / 100.0}});
}

std::optional<std::string> stringField(const json &request, const char *key) {
    const auto field = request.find(key);
    if (field == request.end() || !field->is_string()) return std::nullopt;
    const auto value = field->get<std::string>();
    if (value.find('\0') != std::string::npos) return std::nullopt;
    return value;
}

std::variant<std::vector<std::string>, std::string> vocabularyTerms(const json &request) {
    const auto field = request.find("vocabularyTerms");
    if (field == request.end()) {
        // Older callers supplied unstructured text. Preserve it as one complete
        // hint, or omit all of it if it cannot fit; never silently take a suffix.
        const auto prompt = request.contains("prompt") ? stringField(request, "prompt") : std::optional<std::string>("");
        if (!prompt || prompt->size() > maxPromptBytes) {
            return "Custom vocabulary must be a string of at most 8192 bytes.";
        }
        return prompt->empty() ? std::vector<std::string>{} : std::vector<std::string>{*prompt};
    }
    if (!field->is_array() || field->size() > 8192) {
        return "Vocabulary terms must be an ordered array of at most 8192 strings.";
    }
    std::vector<std::string> terms;
    std::unordered_set<std::string> seen;
    size_t bytes = 0;
    for (const auto &entry : *field) {
        if (!entry.is_string()) return "Vocabulary terms must contain only strings.";
        const auto term = entry.get<std::string>();
        if (term.empty() || term.size() > 16384 || trim(term) != term ||
            std::any_of(term.begin(), term.end(), [](unsigned char character) { return character < 32 || character == 127; })) {
            return "Vocabulary terms must be nonempty single-line text of at most 16384 bytes without surrounding whitespace.";
        }
        bytes += term.size();
        if (bytes > maxVocabularyBytes) return "Vocabulary terms exceed the 384 KB text limit.";
        if (seen.insert(term).second) terms.push_back(term);
    }
    return terms;
}

struct VocabularyHints {
    std::vector<std::string> included;
    std::vector<std::string> omitted;
    std::vector<whisper_token> tokens;
    int tokenBudget;
};

VocabularyHints selectVocabulary(whisper_context *context, const std::vector<std::string> &terms) {
    const auto defaults = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    // whisper_full reserves the previous-text marker, then retains this many
    // carried initial-prompt tokens. Use the loaded model's tokenizer and pass
    // these exact tokens, avoiding upstream's suffix truncation entirely.
    VocabularyHints hints{{}, {}, {}, std::max(0, std::min(defaults.n_max_text_ctx, whisper_n_text_ctx(context) / 2) - 1)};
    std::string prompt;
    for (const auto &term : terms) {
        const auto candidate = prompt.empty() ? term : prompt + ", " + term;
        if (candidate.size() > maxPromptBytes || hints.tokenBudget == 0) {
            hints.omitted.push_back(term);
            continue;
        }
        std::vector<whisper_token> tokens(static_cast<size_t>(hints.tokenBudget));
        const auto count = whisper_tokenize(context, candidate.c_str(), tokens.data(), hints.tokenBudget);
        if (count <= 0) {
            hints.omitted.push_back(term);
            continue;
        }
        tokens.resize(static_cast<size_t>(count));
        hints.included.push_back(term);
        hints.tokens = std::move(tokens);
        prompt = candidate;
    }
    return hints;
}

// A meeting window's language is decided on its speech, not on whatever fills its
// first 30 s. Under this detection probability the caller's fallback decides.
constexpr float languagePinProbability = 0.9f;

// The VAD spans of one window in order, up to 30 s: the audio the language is
// detected on. Segment times are centiseconds on the 16 kHz input.
std::vector<float> speechForDetection(const std::vector<float> &samples, whisper_vad_segments *segments) {
    constexpr size_t limit = 30 * 16000;
    std::vector<float> speech;
    if (!segments) return speech;
    const auto count = whisper_vad_segments_n_segments(segments);
    for (int i = 0; i < count && speech.size() < limit; ++i) {
        const auto start = std::max<int64_t>(0, static_cast<int64_t>(whisper_vad_segments_get_segment_t0(segments, i)) * 160);
        const auto end = std::min<int64_t>(static_cast<int64_t>(samples.size()),
                                           static_cast<int64_t>(whisper_vad_segments_get_segment_t1(segments, i)) * 160);
        for (auto index = start; index < end && speech.size() < limit; ++index) speech.push_back(samples[index]);
    }
    return speech;
}

void transcribe(whisper_context *context, whisper_vad_context *vad, const std::string &vadModelPath, int threads, const json &request) {
    const auto id = stringField(request, "id");
    if (!id || id->empty() || id->size() > 256) {
        emitError("A transcription request needs a nonempty id (up to 256 bytes).");
        return;
    }
    const auto path = stringField(request, "path");
    if (!path || path->empty() || path->size() > 4096) {
        emitError("A transcription request needs a valid WAV path.", *id);
        return;
    }
    const auto language = request.contains("language") ? stringField(request, "language") : std::optional<std::string>("en");
    if (!language || (*language != "auto" && whisper_lang_id(language->c_str()) < 0)) {
        emitError("The requested language is not supported.", *id);
        return;
    }
    const bool meetingTranscription =
        request.contains("meetingTranscription") && request["meetingTranscription"].is_boolean()
        && request["meetingTranscription"].get<bool>();
    // Meeting windows with "auto": the language this window decodes in when its own
    // detection is not confident, typically the caller's last confident detection.
    const auto fallbackLanguage = request.contains("fallbackLanguage") ? stringField(request, "fallbackLanguage") : std::optional<std::string>("");
    if (!fallbackLanguage || (!fallbackLanguage->empty() && whisper_lang_id(fallbackLanguage->c_str()) < 0)) {
        emitError("The requested fallback language is not supported.", *id);
        return;
    }
    // Meeting tracks recognized on their own carry long silences (the other side
    // talking); whisper.cpp's VAD mode decodes only the speech spans and maps the
    // timestamps back, so the decoder never sees a silent chunk to fill.
    const bool silenceSkipping =
        request.contains("silenceSkipping") && request["silenceSkipping"].is_boolean()
        && request["silenceSkipping"].get<bool>();
    const bool benchmarkEvidence =
        (request.contains("benchmarkEvidence") && request["benchmarkEvidence"].is_boolean()
         && request["benchmarkEvidence"].get<bool>()) || meetingTranscription;
    const auto vocabulary = vocabularyTerms(request);
    if (const auto failure = std::get_if<std::string>(&vocabulary)) {
        emitError(*failure, *id);
        return;
    }

    // Meeting windows may carry one context sentence per language code; the one for
    // the language the window decodes in leads the prompt, so the terms are read in
    // that language's spelling and the decoder starts in the register of a meeting.
    std::map<std::string, std::string> languageContext;
    if (const auto field = request.find("languageContext"); field != request.end()) {
        if (!field->is_object() || field->size() > 16) {
            emitError("languageContext must map at most 16 language codes to sentences.", *id);
            return;
        }
        for (const auto &[code, sentence] : field->items()) {
            if (!sentence.is_string() || whisper_lang_id(code.c_str()) < 0 || sentence.get<std::string>().size() > 256) {
                emitError("languageContext must map language codes to sentences of at most 256 bytes.", *id);
                return;
            }
            languageContext[code] = sentence.get<std::string>();
        }
    }

    const auto start = Clock::now();
    auto hints = selectVocabulary(context, std::get<std::vector<std::string>>(vocabulary));
    auto loaded = readAudio(*path);
    if (const auto failure = std::get_if<std::string>(&loaded)) {
        emitError(*failure, *id);
        return;
    }
    auto &audio = std::get<Audio>(loaded);
    const std::unique_ptr<whisper_state, decltype(&whisper_free_state)> benchmarkState(
        benchmarkEvidence ? whisper_init_state(context) : nullptr, whisper_free_state);
    if (benchmarkEvidence && !benchmarkState) {
        emitError("Local transcription state allocation failed. Try recording again.", *id);
        return;
    }
    Progress progress{*id};
    reportProgress(nullptr, nullptr, 0, &progress);
    std::string text;
    std::string detectedLanguage = *language;
    std::optional<float> detectedLanguageProbability;
    std::optional<double> languageSpeechSeconds;
    // The language whisper_full is given, and how it was chosen.
    std::string decodeLanguage = *language;
    std::string languageDecision = *language == "auto" ? "whisper" : "fixed";
    if (meetingTranscription && *language == "auto" && !fallbackLanguage->empty()) {
        decodeLanguage = *fallbackLanguage;
        languageDecision = "fallback";
    }
    std::unique_ptr<whisper_vad_segments, decltype(&whisper_vad_free_segments)> segments(nullptr, whisper_vad_free_segments);
    if (!audio.silent) {
        // A small CPU-only Silero pass rejects fan noise, tones, and other
        // nonspeech that Whisper can otherwise turn into invented sentences.
        // Its recurrent state is reset on each call, just like the ASR context.
        if (!whisper_vad_detect_speech(vad, audio.samples.data(), static_cast<int>(audio.samples.size()))) {
            emitError("Local speech detection failed. Try recording again.", *id);
            return;
        }
        auto detection = whisper_vad_default_params();
        detection.threshold = 0.5f;
        detection.min_speech_duration_ms = 120;
        segments.reset(whisper_vad_segments_from_probs(vad, detection));
        if (!segments) {
            emitError("Local speech detection failed. Try recording again.", *id);
            return;
        }
        audio.silent = whisper_vad_segments_n_segments(segments.get()) == 0;
        // Keep the complete recording when there is speech; this avoids cutting
        // off quiet word boundaries or short pauses inside a sentence.
    }
    if (!audio.silent) {
        if (benchmarkEvidence && *language == "auto") {
            // Meeting windows decide the language here, on the first 30 s of speech,
            // and hand whisper_full a fixed one. whisper's own detection sees the first
            // 30 s of whatever it gets; on a microphone lane with the remote voice
            // muted that was a few words in silence, and Slovak windows came back as
            // Romanian or as English translations. A confident detection is pinned;
            // under the pin probability the caller's fallback decides; without one,
            // whisper detects as before.
            const auto speech = meetingTranscription ? speechForDetection(audio.samples, segments.get()) : audio.samples;
            if (meetingTranscription) languageSpeechSeconds = static_cast<double>(speech.size()) / 16000.0;
            std::vector<float> languageProbabilities(whisper_lang_max_id() + 1, 0.0f);
            if (!speech.empty() && (!meetingTranscription || *languageSpeechSeconds >= 3.0)
                && whisper_pcm_to_mel_with_state(context, benchmarkState.get(), speech.data(), static_cast<int>(speech.size()), threads) == 0) {
                const auto detected = whisper_lang_auto_detect_with_state(
                    context, benchmarkState.get(), 0, threads, languageProbabilities.data());
                if (detected >= 0 && detected <= whisper_lang_max_id()) {
                    detectedLanguageProbability = languageProbabilities[detected];
                    if (meetingTranscription) {
                        if (*detectedLanguageProbability >= languagePinProbability) {
                            decodeLanguage = whisper_lang_str(detected);
                            languageDecision = "detected";
                        } else if (!fallbackLanguage->empty()) {
                            decodeLanguage = *fallbackLanguage;
                            languageDecision = "fallback";
                        }
                    }
                }
            }
        }
        if (const auto sentence = languageContext.find(decodeLanguage); sentence != languageContext.end()) {
            auto terms = std::get<std::vector<std::string>>(vocabulary);
            terms.insert(terms.begin(), sentence->second);
            hints = selectVocabulary(context, terms);
        }
        auto parameters = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
        parameters.n_threads = threads;
        parameters.no_context = !benchmarkEvidence;
        // Production requests isolate dictations. The opt-in benchmark request
        // keeps whisper.cpp's rolling context across its internal long-form seeks.
        // Keep timestamp tokens during decoding: disabling them can omit whole
        // passages when vocabulary hints are present. Segment text below still
        // returns plain text, without exposing timestamps to the client.
        parameters.no_timestamps = false;
        parameters.translate = false;
        parameters.print_special = false;
        parameters.print_progress = false;
        parameters.print_realtime = false;
        parameters.print_timestamps = false;
        parameters.suppress_blank = true;
        parameters.suppress_nst = true;
        parameters.language = decodeLanguage.c_str();
        parameters.prompt_tokens = hints.tokens.empty() ? nullptr : hints.tokens.data();
        parameters.prompt_n_tokens = static_cast<int>(hints.tokens.size());
        parameters.carry_initial_prompt = !hints.tokens.empty();
        parameters.temperature = 0;
        parameters.temperature_inc = 0; // Deterministic, bounded dictation latency.
        parameters.beam_search.beam_size = 5;
        parameters.no_speech_thold = 0.6f;
        if (meetingTranscription) {
            // Offline meeting windows can afford whisper's fallback ladder: a chunk whose
            // decode is low-entropy (a repeated phrase) or low-probability is retried at
            // rising temperatures, which is what stops "České všichni. České všichni. …"
            // from filling a window. Dictation keeps the deterministic single decode.
            parameters.temperature_inc = 0.2f;
            parameters.entropy_thold = 2.4f;
            parameters.logprob_thold = -1.0f;
        }
        if (silenceSkipping) {
            parameters.vad = true;
            parameters.vad_model_path = vadModelPath.c_str();
            parameters.vad_params = whisper_vad_default_params();
        }
        parameters.progress_callback = reportProgress;
        parameters.progress_callback_user_data = &progress;

        auto decode = [&](const whisper_full_params &current) {
            return benchmarkEvidence
                ? whisper_full_with_state(context, benchmarkState.get(), current, audio.samples.data(), static_cast<int>(audio.samples.size()))
                : whisper_full(context, current, audio.samples.data(), static_cast<int>(audio.samples.size()));
        };
        // whisper.cpp's entropy check counts timestamp tokens, which are all distinct,
        // so a chunk that emits the same phrase with rising timestamps passes it. Three
        // identical consecutive segments are that loop; the window is decoded again
        // sampled from 0.4 up, which is a different search and stays deterministic
        // (the state's generator is seeded).
        auto segmentTextAt = [&](int index) {
            std::string current(benchmarkEvidence ? whisper_full_get_segment_text_from_state(benchmarkState.get(), index)
                                                  : whisper_full_get_segment_text(context, index));
            while (!current.empty() && std::isspace(static_cast<unsigned char>(current.back()))) current.pop_back();
            while (!current.empty() && std::isspace(static_cast<unsigned char>(current.front()))) current.erase(current.begin());
            return current;
        };
        // Every maximal run of >= 3 consecutive identical segments, as [first, last].
        auto segmentLoopRuns = [&]() {
            std::vector<std::pair<int, int>> runs;
            const auto count = benchmarkEvidence ? whisper_full_n_segments_from_state(benchmarkState.get())
                                                 : whisper_full_n_segments(context);
            int i = 0;
            while (i < count) {
                const std::string current = segmentTextAt(i);
                if (current.empty()) { ++i; continue; }
                int last = i;
                while (last + 1 < count && segmentTextAt(last + 1) == current) ++last;
                if (last - i + 1 >= 3) runs.push_back({i, last});
                i = last + 1;
            }
            return runs;
        };
        // Mirrors WhisperMeetingRuntime.speechBacked: 100 ms frames are loud when
        // their mean-square level exceeds -50 dBFS, and a segment is speech-backed
        // when at least 20 % of its frames are loud. A loop run no segment's audio
        // backs is decoder filler over silence the app drops after the fact, so the
        // sampled re-decode cannot change the transcript and is skipped.
        auto loopRunIsDeadAudio = [&](int first, int last) {
            const int frameSamples = 1600;
            const int frames = static_cast<int>((audio.samples.size() + frameSamples - 1) / frameSamples);
            if (frames == 0) return true;
            for (int i = first; i <= last; ++i) {
                const double t0 = (benchmarkEvidence ? whisper_full_get_segment_t0_from_state(benchmarkState.get(), i)
                                                     : whisper_full_get_segment_t0(context, i)) / 100.0;
                const double t1 = (benchmarkEvidence ? whisper_full_get_segment_t1_from_state(benchmarkState.get(), i)
                                                     : whisper_full_get_segment_t1(context, i)) / 100.0;
                const int firstFrame = std::max(0, std::min(frames - 1, static_cast<int>(t0 * 10)));
                const int lastFrame = std::max(firstFrame, std::min(frames - 1, static_cast<int>(std::ceil(t1 * 10)) - 1));
                const int spanCount = lastFrame - firstFrame + 1;
                int loudCount = 0;
                for (int frame = firstFrame; frame <= lastFrame; ++frame) {
                    const size_t s0 = static_cast<size_t>(frame) * frameSamples;
                    const size_t s1 = std::min(audio.samples.size(), s0 + frameSamples);
                    double sum = 0;
                    for (size_t k = s0; k < s1; ++k) sum += static_cast<double>(audio.samples[k]) * audio.samples[k];
                    if (10 * std::log10(sum / (s1 - s0) + 1e-10) > -50) ++loudCount;
                }
                if (static_cast<double>(loudCount) >= 0.2 * spanCount) return false;
            }
            return true;
        };
        int loopRetries = 0;
        int loopRetriesSkipped = 0;
        auto fullResult = decode(parameters);
        if (fullResult == 0 && meetingTranscription) {
            const auto runs = segmentLoopRuns();
            const bool backedRun = std::any_of(runs.begin(), runs.end(), [&](const auto &run) {
                return !loopRunIsDeadAudio(run.first, run.second);
            });
            if (backedRun) {
                auto sampled = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
                sampled.n_threads = parameters.n_threads;
                sampled.no_context = parameters.no_context;
                sampled.no_timestamps = parameters.no_timestamps;
                sampled.translate = parameters.translate;
                sampled.print_special = false;
                sampled.print_progress = false;
                sampled.print_realtime = false;
                sampled.print_timestamps = false;
                sampled.suppress_blank = parameters.suppress_blank;
                sampled.suppress_nst = parameters.suppress_nst;
                sampled.language = parameters.language;
                sampled.prompt_tokens = parameters.prompt_tokens;
                sampled.prompt_n_tokens = parameters.prompt_n_tokens;
                sampled.carry_initial_prompt = parameters.carry_initial_prompt;
                sampled.temperature = 0.4f;
                sampled.temperature_inc = 0.2f;
                sampled.entropy_thold = parameters.entropy_thold;
                sampled.logprob_thold = parameters.logprob_thold;
                sampled.no_speech_thold = parameters.no_speech_thold;
                sampled.greedy.best_of = 5;
                sampled.vad = parameters.vad;
                sampled.vad_model_path = parameters.vad_model_path;
                sampled.vad_params = parameters.vad_params;
                sampled.progress_callback = reportProgress;
                sampled.progress_callback_user_data = &progress;
                loopRetries = 1;
                fullResult = decode(sampled);
            } else if (!runs.empty()) {
                loopRetriesSkipped = 1;
            }
        }
        if (fullResult != 0) {
            emitError("Local transcription failed. Try recording again.", *id);
            return;
        }
        const auto lang = benchmarkEvidence ? whisper_lang_str(whisper_full_lang_id_from_state(benchmarkState.get()))
                                             : whisper_lang_str(whisper_full_lang_id(context));
        if (lang) detectedLanguage = lang;
        json nativeSegments = json::array();
        const auto segmentCount = benchmarkEvidence ? whisper_full_n_segments_from_state(benchmarkState.get())
                                                    : whisper_full_n_segments(context);
        for (int i = 0; i < segmentCount; ++i) {
            const auto noSpeechProbability = benchmarkEvidence
                ? whisper_full_get_segment_no_speech_prob_from_state(benchmarkState.get(), i)
                : whisper_full_get_segment_no_speech_prob(context, i);
            if (noSpeechProbability > parameters.no_speech_thold) continue;
            // Whisper owns punctuation and word spacing. Only trim the outside.
            const auto segmentText = std::string(benchmarkEvidence
                    ? whisper_full_get_segment_text_from_state(benchmarkState.get(), i)
                    : whisper_full_get_segment_text(context, i));
            text += segmentText;
            if (benchmarkEvidence) {
                nativeSegments.push_back({
                    {"startSeconds", (benchmarkEvidence ? whisper_full_get_segment_t0_from_state(benchmarkState.get(), i)
                                                            : whisper_full_get_segment_t0(context, i)) / 100.0},
                    {"endSeconds", (benchmarkEvidence ? whisper_full_get_segment_t1_from_state(benchmarkState.get(), i)
                                                          : whisper_full_get_segment_t1(context, i)) / 100.0},
                    {"text", segmentText},
                    {"noSpeechProbability", noSpeechProbability}});
            }
        }
        if (!benchmarkEvidence) {
            reportProgress(nullptr, nullptr, 100, &progress);
            emit({{"type", "result"}, {"id", *id}, {"text", trim(std::move(text))},
                  {"duration", audio.duration}, {"elapsed", std::chrono::duration<double>(Clock::now() - start).count()},
                  {"language", detectedLanguage}, {"includedTerms", hints.included}, {"omittedTerms", hints.omitted},
                  {"tokenCount", hints.tokens.size()}, {"tokenBudget", hints.tokenBudget}});
            return;
        }
        reportProgress(nullptr, nullptr, 100, &progress);
        json result = {
            {"type", "result"}, {"id", *id}, {"text", trim(std::move(text))},
            {"duration", audio.duration},
            {"elapsed", std::chrono::duration<double>(Clock::now() - start).count()},
            {"language", detectedLanguage}, {"languageDecision", languageDecision}, {"segments", nativeSegments},
            {"segmentation", "whisper_full_internal_30s_seek_segments_v1"},
            {"context", "rolling_internal_prompt_reset_between_requests"},
            {"decoding", std::string(meetingTranscription ? "beam5_fallback_t0.2_e2.4_lp-1.0_loop_t0.4_deadskip" : "beam5_greedy_t0") + (silenceSkipping ? "_vad" : "")},
            {"loopRetries", loopRetries}, {"loopRetriesSkipped", loopRetriesSkipped},
            {"includedTerms", hints.included}, {"omittedTerms", hints.omitted},
            {"tokenCount", hints.tokens.size()}, {"tokenBudget", hints.tokenBudget}};
        if (detectedLanguageProbability) result["languageProbability"] = *detectedLanguageProbability;
        if (languageSpeechSeconds) result["languageSpeechSeconds"] = *languageSpeechSeconds;
        emit(result);
        return;
    }
    reportProgress(nullptr, nullptr, 100, &progress);
    if (benchmarkEvidence) {
        emit({{"type", "result"}, {"id", *id}, {"text", trim(std::move(text))},
              {"duration", audio.duration}, {"elapsed", std::chrono::duration<double>(Clock::now() - start).count()},
              {"language", detectedLanguage}, {"languageDecision", languageDecision}, {"segments", json::array()},
              {"segmentation", "whisper_full_internal_30s_seek_segments_v1"},
              {"context", "rolling_internal_prompt_reset_between_requests"},
            {"decoding", std::string(meetingTranscription ? "beam5_fallback_t0.2_e2.4_lp-1.0_loop_t0.4_deadskip" : "beam5_greedy_t0") + (silenceSkipping ? "_vad" : "")},
              {"includedTerms", hints.included}, {"omittedTerms", hints.omitted},
              {"tokenCount", hints.tokens.size()}, {"tokenBudget", hints.tokenBudget}});
    } else {
        emit({{"type", "result"}, {"id", *id}, {"text", trim(std::move(text))},
              {"duration", audio.duration}, {"elapsed", std::chrono::duration<double>(Clock::now() - start).count()},
              {"language", detectedLanguage}, {"includedTerms", hints.included}, {"omittedTerms", hints.omitted},
              {"tokenCount", hints.tokens.size()}, {"tokenBudget", hints.tokenBudget}});
    }
}

} // namespace

int main(int argc, char **argv) {
    std::ios::sync_with_stdio(false);
    std::string model;
    std::string vadModel;
    int threads = static_cast<int>(std::clamp(std::thread::hardware_concurrency(), 1u, 8u));
    for (int i = 1; i < argc; ++i) {
        const std::string argument = argv[i];
        if (argument == "--help") {
            std::fputs("Usage: sotto-engine --model PATH --vad-model PATH [--threads 1..32]\nJSON lines on stdin and stdout; diagnostics only on stderr.\n", stderr);
            return 0;
        }
        if ((argument != "--model" && argument != "--vad-model" && argument != "--threads") || i + 1 >= argc) {
            emitError("Usage: sotto-engine --model PATH --vad-model PATH [--threads 1..32]");
            return 2;
        }
        const std::string value = argv[++i];
        if (argument == "--model") {
            model = value;
        } else if (argument == "--vad-model") {
            vadModel = value;
        } else {
            const auto parsed = std::from_chars(value.data(), value.data() + value.size(), threads);
            if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size() || threads < 1 || threads > 32) {
                emitError("The thread count must be between 1 and 32.");
                return 2;
            }
        }
    }
    std::error_code error;
    if (model.empty() || !std::filesystem::is_regular_file(model, error)) {
        emitError("The speech model is missing. Configure the server's speech model path.");
        return 2;
    }
    if (vadModel.empty() || !std::filesystem::is_regular_file(vadModel, error)) {
        emitError("The speech detector is missing. Configure the server's VAD model path.");
        return 2;
    }

    watchParent();
    whisper_log_set(libraryLog, nullptr);
    ggml_log_set(libraryLog, nullptr);
    auto parameters = whisper_context_default_params();
    parameters.use_gpu = true;
    parameters.flash_attn = true;
    const std::unique_ptr<whisper_context, decltype(&whisper_free)> context(
        whisper_init_from_file_with_params(model.c_str(), parameters), whisper_free);
    if (!context) {
        emitError("The model could not be loaded. Check available memory or download it again.");
        return 1;
    }
    auto vadParameters = whisper_vad_default_context_params();
    vadParameters.n_threads = std::min(threads, 2);
    vadParameters.use_gpu = false;
    const std::unique_ptr<whisper_vad_context, decltype(&whisper_vad_free)> vad(
        whisper_vad_init_from_file_with_params(vadModel.c_str(), vadParameters), whisper_vad_free);
    if (!vad) {
        emitError("The local speech detector could not load. Rebuild Sotto to restore it.");
        return 1;
    }
    emit({{"type", "ready"}, {"engineVersion", whisper_version()}});

    // Fixed-size reads prevent a malformed caller from allocating unbounded RAM.
    std::vector<char> buffer(maxRequestBytes + 1);
    while (std::cin.getline(buffer.data(), buffer.size())) {
        const auto request = json::parse(buffer.data(), nullptr, false);
        if (request.is_discarded() || !request.is_object()) {
            emitError("Expected one JSON object per line.");
            continue;
        }
        const auto type = stringField(request, "type");
        if (type == "quit") return 0;
        if (type != "transcribe") {
            emitError("Unknown request type.", stringField(request, "id").value_or(""));
            continue;
        }
        transcribe(context.get(), vad.get(), vadModel, threads, request);
    }
    if (!std::cin.eof()) {
        emitError("The request exceeds the 1 MB limit.");
        return 2;
    }
    return 0;
}
