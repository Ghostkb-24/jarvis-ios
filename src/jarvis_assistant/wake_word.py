from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from threading import Lock
from typing import Protocol


class WakeBackend(Protocol):
    def start(self, on_detected: Callable[[], None]) -> None: ...
    def stop(self) -> None: ...


def resolve_input_device(name: str, devices) -> int:
    matches = [
        (index, device)
        for index, device in enumerate(devices)
        if name.casefold() in str(device["name"]).casefold()
        and int(device["max_input_channels"]) > 0
    ]
    if not matches:
        raise ValueError(f"找不到麦克风：{name}")
    return next((index for index, device in matches if int(device["hostapi"]) == 2), matches[0][0])


def amplify_samples(samples, *, gain: float = 10.0):
    return [max(-1.0, min(1.0, float(sample) * gain)) for sample in samples]


class WakeWordListener:
    def __init__(self, backend: WakeBackend) -> None:
        self._backend = backend
        self._running = False
        self._triggered = False
        self._lock = Lock()

    @property
    def running(self) -> bool:
        return self._running

    def start(self, on_detected: Callable[[], None]) -> None:
        if self._running:
            return
        self._triggered = False
        self._running = True

        def detected() -> None:
            with self._lock:
                if not self._running or self._triggered:
                    return
                self._triggered = True
            on_detected()

        try:
            self._backend.start(detected)
        except Exception:
            self._running = False
            raise

    def stop(self) -> None:
        if not self._running:
            return
        self._running = False
        self._backend.stop()


class SherpaWakeBackend:
    def __init__(self, model_dir: Path, keywords_file: Path, *, device: str = "Lian II"):
        self._model_dir = model_dir
        self._keywords_file = keywords_file
        self._device = device
        self._stream = None
        self._spotter = None

    def start(self, on_detected: Callable[[], None]) -> None:
        import sherpa_onnx
        import sounddevice

        device_id = resolve_input_device(self._device, sounddevice.query_devices())
        input_sample_rate = int(sounddevice.query_devices(device_id)["default_samplerate"])

        self._spotter = sherpa_onnx.KeywordSpotter(
            tokens=str(self._model_dir / "tokens.txt"),
            encoder=str(self._model_dir / "encoder-epoch-13-avg-2-chunk-16-left-64.int8.onnx"),
            decoder=str(self._model_dir / "decoder-epoch-13-avg-2-chunk-16-left-64.onnx"),
            joiner=str(self._model_dir / "joiner-epoch-13-avg-2-chunk-16-left-64.int8.onnx"),
            keywords_file=str(self._keywords_file),
            keywords_threshold=0.20,
        )
        kws_stream = self._spotter.create_stream()

        def callback(indata, frames, time, status) -> None:
            del frames, time
            if status or self._spotter is None:
                return
            kws_stream.accept_waveform(
                input_sample_rate,
                amplify_samples(indata[:, 0], gain=12.0),
            )
            while self._spotter.is_ready(kws_stream):
                self._spotter.decode_stream(kws_stream)
            result = self._spotter.get_result(kws_stream)
            if result:
                self._spotter.reset_stream(kws_stream)
                on_detected()

        self._stream = sounddevice.InputStream(
            samplerate=input_sample_rate,
            channels=1,
            dtype="float32",
            device=device_id,
            callback=callback,
        )
        self._stream.start()

    def stop(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
        self._stream = None
        self._spotter = None
