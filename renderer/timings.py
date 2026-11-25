"""How long each step of a render took, logged as one line per attempt.

The line holds step names, durations, counts and status codes only, never a
query, URL or page content, so it is safe to log in production.
"""
import time


class Timings:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.started = self.step_started = clock()
        self.step = None
        self.fields = {}

    def begin(self, step):
        """Finish the current step, if any, and start timing the next one."""
        self.finish()
        self.step = step

    def finish(self):
        now = self.clock()
        if self.step:
            self.fields[f"{self.step}_ms"] = round((now - self.step_started) * 1000)
        self.step_started = now
        self.step = None

    def note(self, **fields):
        self.fields.update(fields)

    def snapshot(self, outcome):
        """The line so far, without finishing anything: for a summary sent on."""
        fields = dict(self.fields)
        now = self.clock()
        parts = [f"outcome={outcome}"]
        if self.step:
            if "stopped_in" not in fields:
                parts.append(f"stopped_in={self.step}")
            fields[f"{self.step}_ms"] = round((now - self.step_started) * 1000)
        parts += [f"{name}={value}" for name, value in fields.items()]
        parts.append(f"total_ms={round((now - self.started) * 1000)}")
        return " ".join(parts)

    def line(self, outcome):
        """The log line. An unfinished step is timed so far and named as `stopped_in`."""
        unfinished = self.step
        self.finish()
        parts = [f"outcome={outcome}"]
        if unfinished and "stopped_in" not in self.fields:
            parts.append(f"stopped_in={unfinished}")
        parts += [f"{name}={value}" for name, value in self.fields.items()]
        parts.append(f"total_ms={round((self.clock() - self.started) * 1000)}")
        return " ".join(parts)
