# Pruflo web app (Flutter)

The Flutter client for Pruflo. People use it to create cases, upload evidence, review findings, record decisions and generate reports. Admins also manage users and integrations.

The app has no data of its own. Every screen reads from and writes to the Pruflo API (`backend/`) and shows a loading, empty or error state while it waits. The API is described in [`Docs/API_Contract.md`](../Docs/API_Contract.md) and [`Docs/Integrations_API_Contract.md`](../Docs/Integrations_API_Contract.md).

- Production: https://pruflo.web.app (Firebase Hosting, project `login-register-125ef`)
- Targets: web (primary). Android and iOS build from the same code but aren't released yet.

## Requirements

- Flutter 3.47 (stable) with Dart 3.13. Check with `flutter --version`.
- A running Pruflo API: locally from `backend/` (see [`backend/README.md`](../backend/README.md)), or a deployed Cloud Run URL.
- For real sign-in: a Firebase web app in the Firebase project, with the Email/Password, Google and (optionally) Microsoft providers enabled.

## Configuration

All settings are passed at build time with `--dart-define=NAME=value`. None of them are secrets: Firebase web config is public by design, and access is enforced by Firebase Auth and the API.

| Name | Default | What it does |
| --- | --- | --- |
| `API_BASE_URL` | `http://localhost:8000` | The Pruflo API, e.g. `https://pruflo-api-xxxx.a.run.app` |
| `FIREBASE_API_KEY` | *(empty)* | Turns on Firebase Auth. Without it the app uses development sign-in (below) |
| `FIREBASE_APP_ID` | *(empty)* | Firebase web app ID, `1:...:web:...` |
| `FIREBASE_MESSAGING_SENDER_ID` | *(empty)* | Firebase sender ID |
| `FIREBASE_PROJECT_ID` | `login-register-125ef` | Firebase project |
| `FIREBASE_AUTH_DOMAIN` | `login-register-125ef.firebaseapp.com` | Firebase auth domain |
| `FIREBASE_APP_CHECK_SITE_KEY` | *(empty)* | reCAPTCHA v3 site key. When set, every API call carries an App Check token |

You can find the Firebase values in the Firebase console under **Project settings → Your apps → Web app → SDK setup and configuration**.

The API requires an App Check token in production unless it runs with `PRUFLO_APP_CHECK_REQUIRED=false`. Set `FIREBASE_APP_CHECK_SITE_KEY` for production builds, or relax that API setting until App Check is registered.

## Run locally against the local API

1. Start the API and create an organisation and an admin (details in `backend/README.md`):

   ```bash
   cd backend
   cp .env.example .env    # set PRUFLO_DB_PASSWORD: openssl rand -hex 16
   docker compose up -d postgres
   python3.12 -m venv .venv && source .venv/bin/activate
   pip install -r requirements-dev.txt
   alembic upgrade head
   python -m app.cli bootstrap --tenant "My Org" --admin-email you@example.com --admin-name "Your Name"
   uvicorn app.main:app --reload --port 8000 --no-access-log
   ```

   To invite more people: `python -m app.cli invite --tenant ten_... --email someone@example.com --role reviewer`, or use the Admin screen in the app.

2. Run the app:

   ```bash
   cd frontend
   flutter pub get
   flutter run -d chrome
   ```

3. Sign in with an invited email.

**Development sign-in.** Builds without `FIREBASE_API_KEY` show a yellow "Development sign-in" banner and ask only for an email address. The app then sends the API's development token (`dev:<uid>:<email>`). The API accepts it only when it runs with `PRUFLO_ENV=local` and `PRUFLO_AUTH_DEV_MODE=true`, so this mode can't sign anyone in to a deployed API. The session isn't remembered, so reloading the page signs you out.

## Build for production

```bash
flutter build web --release \
  --dart-define=API_BASE_URL=https://pruflo-api-xxxx.a.run.app \
  --dart-define=FIREBASE_API_KEY=... \
  --dart-define=FIREBASE_APP_ID=... \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define=FIREBASE_APP_CHECK_SITE_KEY=...
```

The output is in `build/web`.

Also add the hosting domain (`pruflo.web.app`) to **Firebase Authentication → Settings → Authorized domains**, and to the API's `PRUFLO_CORS_ORIGINS`.

## Deploy (Firebase Hosting)

Deployment is automated by two GitHub Actions workflows in `.github/workflows/`:

| Workflow | When | What |
| --- | --- | --- |
| `firebase-hosting-pull-request.yml` | A pull request to `main` | Builds the app and deploys a preview channel |
| `firebase-hosting-merge.yml` | A push to `main` | Builds the app and deploys to the live channel, including https://pruflo.web.app |

Hosting settings are in `firebase.json`: `build/web` is served with SPA rewrites to `index.html` and `Cache-Control: no-cache`, so browsers pick up new releases straight away.

Both workflows pass the build settings from GitHub repository variables (**Settings → Secrets and variables → Actions → Variables**):

| Variable | Required | Value |
| --- | --- | --- |
| `API_BASE_URL` | yes | The deployed API, `https://...` |
| `FIREBASE_API_KEY` | yes | From the Firebase web app config |
| `FIREBASE_APP_ID` | yes | From the Firebase web app config |
| `FIREBASE_MESSAGING_SENDER_ID` | yes | From the Firebase web app config |
| `FIREBASE_APP_CHECK_SITE_KEY` | if the API requires App Check | reCAPTCHA v3 site key |

A **Check build settings** step stops the workflow if a required variable is missing or `API_BASE_URL` isn't `https`, so a misconfigured build never replaces the live site.

To deploy by hand, run `firebase deploy --only hosting:web --project pruflo` from `frontend/`. The project alias is in `frontend/.firebaserc`.

## Project structure

```
lib/
  main.dart                 starts the app and checks the saved session
  app/                      router (go_router) and theme
  core/
    config.dart             --dart-define settings
    api_client.dart         HTTP, auth headers, the API's error envelope
    api.dart                PrufloApi: profile, cases, evidence, findings, reports, admin
    integrations_api.dart   API keys, webhooks, sources, rules, providers
    auth_service.dart       Firebase or development sign-in; the user from /v1/me
    models.dart             API models (fromJson), wire values for enums
    integration_models.dart Integrations models
    download*.dart          browser downloads and opening signed links
  features/                 one folder per screen
  widgets/                  shared widgets, including AsyncView (loading/error/empty)
test/
  support/fake_api.dart     a fake API returning contract-shaped JSON
```

What each role can do is decided by the API. The app only hides actions a role can't take: viewers can't decide or export, and only admins see Admin and Integrations.

## Test

```bash
flutter analyze
flutter test
```

The tests run against `test/support/fake_api.dart`, which answers with JSON copied from the API contracts. They cover:

- every route rendering at phone and desktop widths;
- data from the API reaching the screens;
- empty organisations showing empty states;
- sign-in errors;
- review decision rules;
- role-based hiding.

If you change the API contract, update `models.dart` and the fake together.
