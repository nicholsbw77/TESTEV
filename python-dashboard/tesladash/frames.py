"""CAN frame — universal representation regardless of adapter source.

Mirrors lib/can/can_frame.dart from the Flutter app so captures and decode
logic stay interchangeable between the two codebases.
"""

import time


class CanFrame:
    __slots__ = ("id", "data", "timestamp")

    def __init__(self, can_id: int, data: bytes, timestamp: float | None = None):
        self.id = can_id
        self.data = bytes(data)
        self.timestamp = timestamp if timestamp is not None else time.time()

    @property
    def dlc(self) -> int:
        return len(self.data)

    def __repr__(self) -> str:
        return "%03X [%s]" % (self.id, " ".join("%02X" % b for b in self.data))
