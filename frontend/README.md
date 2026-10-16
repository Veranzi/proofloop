# pruflo

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Running against the local backend

By default the app runs on mock data (this is what https://pruflo.web.app shows).
To use the real API, start the backend first (see `backend/README.md`), then:

```bash
flutter run -d chrome --dart-define=USE_API=true
```

Sign in with an email the backend has invited (see `python -m app.cli invite` in
`backend/README.md`), using the email and password form. "Continue with Google"
is still a mock that signs in as a placeholder account the backend hasn't invited.

Until Firebase Auth is wired in, the app sends the backend's local development
token, which the backend accepts only when `PRUFLO_ENV` is `local` or `test`.
Set `--dart-define=API_BASE_URL=...` to point at another API.
