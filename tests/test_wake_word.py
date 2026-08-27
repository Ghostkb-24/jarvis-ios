from jarvis_assistant.wake_word import WakeWordListener, amplify_samples, resolve_input_device


class FakeBackend:
    def __init__(self):
        self.callback = None
        self.running = False

    def start(self, callback):
        self.callback = callback
        self.running = True

    def stop(self):
        self.running = False


def test_listener_starts_detects_once_and_stops():
    backend = FakeBackend()
    detected = []
    listener = WakeWordListener(backend)

    listener.start(lambda: detected.append(True))
    backend.callback()
    backend.callback()

    assert listener.running
    assert detected == [True]
    listener.stop()
    assert not listener.running


def test_resolve_input_device_prefers_wasapi_match():
    devices = [
        {"name": "麦克风 (Lian II)", "max_input_channels": 1, "hostapi": 0},
        {"name": "麦克风 (Lian II)", "max_input_channels": 1, "hostapi": 2},
    ]
    assert resolve_input_device("Lian II", devices) == 1


def test_amplify_samples_caps_signal():
    assert amplify_samples([0.01, -0.2], gain=10) == [0.1, -1.0]
