from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass
from threading import Lock
from typing import Any, Protocol


class AudioError(RuntimeError):
    pass


@dataclass(frozen=True)
class AudioBuffer:
    samples: tuple[float, ...]
    sample_rate: int = 16_000


class AudioBackend(Protocol):
    def start(self, on_samples: Callable[[Sequence[float]], None]) -> None: ...

    def stop(self) -> None: ...


class AudioRecorder:
    def __init__(self, backend: AudioBackend, *, sample_rate: int = 16_000) -> None:
        self._backend = backend
        self._sample_rate = sample_rate
        self._recording = False
        self._samples: list[float] = []
        self._lock = Lock()

    @property
    def recording(self) -> bool:
        return self._recording

    def start(self) -> None:
        if self._recording:
            raise AudioError("正在录音，请先结束当前录音。")
        with self._lock:
            self._samples.clear()
        self._recording = True
        try:
            self._backend.start(self._append_samples)
        except Exception as error:
            self._recording = False
            raise AudioError("无法启动麦克风。") from error

    def stop(self) -> AudioBuffer:
        if not self._recording:
            raise AudioError("录音尚未开始。")
        self._recording = False
        try:
            self._backend.stop()
        except Exception as error:
            raise AudioError("无法停止麦克风。") from error
        with self._lock:
            samples = tuple(self._samples)
        if not samples:
            raise AudioError("没有检测到音频。")
        return AudioBuffer(samples=samples, sample_rate=self._sample_rate)

    def _append_samples(self, values: Sequence[float]) -> None:
        with self._lock:
            self._samples.extend(float(value) for value in values)


class SoundDeviceBackend:
    def __init__(self, *, device: str | int | None = None, sample_rate: int = 16_000) -> None:
        self._device = device
        self._sample_rate = sample_rate
        self._stream: Any | None = None

    def start(self, on_samples: Callable[[Sequence[float]], None]) -> None:
        try:
            import sounddevice
        except ImportError as error:
            raise AudioError("尚未安装 sounddevice。") from error

        def callback(indata: Any, frames: int, time: Any, status: Any) -> None:
            del frames, time
            if status:
                return
            on_samples(indata[:, 0].tolist())

        self._stream = sounddevice.InputStream(
            samplerate=self._sample_rate,
            channels=1,
            dtype="float32",
            device=self._device,
            callback=callback,
        )
        self._stream.start()

    def stop(self) -> None:
        if self._stream is None:
            return
        self._stream.stop()
        self._stream.close()
        self._stream = None


class FasterWhisperTranscriber:
    def __init__(
        self,
        model_name: str = "small",
        *,
        device: str = "auto",
        compute_type: str = "default",
    ) -> None:
        self._model_name = model_name
        self._device = device
        self._compute_type = compute_type
        self._model: Any | None = None

    def transcribe(self, buffer: AudioBuffer) -> str:
        try:
            import numpy
            from faster_whisper import WhisperModel
        except ImportError as error:
            raise AudioError("尚未安装本地语音识别组件。") from error
        if self._model is None:
            try:
                self._model = WhisperModel(
                    self._model_name,
                    device=self._device,
                    compute_type=self._compute_type,
                )
            except Exception as error:
                raise AudioError("无法加载语音识别模型。") from error
        audio = numpy.asarray(buffer.samples, dtype=numpy.float32)
        try:
            segments, _ = self._model.transcribe(audio, language="zh", vad_filter=True)
            text = "".join(segment.text for segment in segments).strip()
        except Exception as error:
            raise AudioError("语音识别失败。") from error
        if not text:
            raise AudioError("没有识别到文字。")
        return text


class SpeechEngine(Protocol):
    def say(self, text: str) -> None: ...

    def runAndWait(self) -> None: ...

    def stop(self) -> None: ...


class Speaker:
    def __init__(self, engine: SpeechEngine) -> None:
        self._engine = engine

    @classmethod
    def from_system(cls) -> Speaker:
        try:
            import pyttsx3
        except ImportError as error:
            raise AudioError("尚未安装本地语音合成组件。") from error
        return cls(pyttsx3.init())

    def say(self, text: str) -> None:
        self._engine.stop()
        if not text.strip():
            return
        self._engine.say(text)
        self._engine.runAndWait()

    def stop(self) -> None:
        self._engine.stop()
