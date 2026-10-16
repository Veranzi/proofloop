"""How a pipeline failure is handled.

- ``PermanentError``: retrying won't help (corrupt file, unreadable content).
  The evidence goes straight to ``failed_terminal``.
- ``TransientError``: a dependency hiccup (storage, OCR timeout). The job is
  retried with backoff, up to ``MAX_ATTEMPTS``, then it becomes terminal.

``code`` is stored as the evidence's ``error_class`` and shown to people.
"""


class PipelineError(Exception):
    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code


class PermanentError(PipelineError):
    pass


class TransientError(PipelineError):
    pass
