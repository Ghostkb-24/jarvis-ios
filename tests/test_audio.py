import pytest

from jarvis_assistant.audio import AudioError, AudioRecorder, Speaker


class FakeAudioBackend:
    def __init__(self, samples=None) -> None:
        self.samples = samples if samples is not None else [0.1, 0.2, 0.3]
        self.started = False

    def start(self, on_samples) -> None:
        self.started = True
        on_samples(self.samples)

    def stop(self) -> None:
        self.started = False


class FakeSpeechEngine:
    def __init__(self) -> None:
        self.spoken = []
        self.stop_count = 0

    def say(self, text: str) -> None:
        self.spoken.append(text)

    def runAndWait(self) -> None:
        return None

    def stop(self) -> None:
        self.stop_count += 1


def test_recorder_keeps_audio_in_memory_only(fake_path=None) -> None:
    recorder = AudioRecorder(FakeAudioBackend())
    recorder.start()
    buffer = recorder.stop()
    assert buffer.samples == (0.1, 0.2, 0.3)
    assert buffer.sample_rate == 16_000


def test_recorder_rejects_invalid_lifecycle() -> None:
    recorder = AudioRecorder(FakeAudioBackend())
    with pytest.raises(AudioError, match="尚未开始"):
        recorder.stop()
    recorder.start()
    with pytest.raises(AudioError, match="正在录音"):
        recorder.start()


def test_recorder_rejects_empty_audio() -> None:
    recorder = AudioRecorder(FakeAudioBackend(samples=[]))
    recorder.start()
    with pytest.raises(AudioError, match="没有检测到音频"):
        recorder.stop()


def test_speaker_interrupts_previous_utterance() -> None:
    engine = FakeSpeechEngine()
    speaker = Speaker(engine)
    speaker.say("第一句")
    speaker.say("第二句")
    assert engine.spoken == ["第一句", "第二句"]
    assert engine.stop_count == 2
