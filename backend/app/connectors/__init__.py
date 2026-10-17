"""Document sources (Docs/Integrations_API_Contract.md §3).

Connectors only change where the bytes come from. Every imported file goes
through ``app.services.evidence.import_file``: the same types, limits,
server-side checksum and processing queue as a manual upload.

- ``email_inbox``: a mail service posts each message to ``/v1/inbound/email``.
- ``odoo``: polled with a read-only user's API key.
- ``google_drive`` and ``sharepoint``: OAuth, then polled.

Polling runs from Cloud Scheduler (``/tasks/sync-connectors`` on the worker)
or ``python -m app.worker sync-connectors``.
"""
