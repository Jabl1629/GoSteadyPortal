# GoSteady Portal

Caregiver monitoring dashboard for the GoSteady smart walker cap. Built in Flutter so V1 runs as a responsive web app and the same codebase can be compiled to native iOS and Android when we need it.

## V1 Scope

V1 is intentionally narrow. It shows two things:

1. **Device health** — battery level, cellular signal strength, last data received, device info (serial, firmware). Everything a caregiver or dev needs to know the device is alive and reporting.
2. **Distance traveled** — today's distance and step count, a 24-hour activity timeline, and a 7-day history row. This maps directly to the first algorithm going into firmware (`firmware_algo_dev`).

Explicitly out of scope for V1: tip-over alerts, no-activity alerts, assistance score, multi-device view, user accounts, 7d/30d activity views, device activation flow.

Data is currently mocked from the actual capture annotations in `GoSteady_Capture_Annotations_v1.xlsx`. When the AWS pipeline is live, swap `lib/data/mock_data.dart` for a real API client.

## Tech Stack

- **Flutter Web** (stable channel, Dart 3.x)
- **google_fonts** — Fraunces (headings) + Inter (body) to match gosteady.co
- **fl_chart** — activity timeline and daily history bars
- **intl** — date/time formatting

## Getting Started

```bash
# Install dependencies
flutter pub get

# Run in Chrome (dev mode)
flutter run -d chrome

# Build for production
flutter build web --release
```

The build output lands in `build/web/` and can be deployed to any static host (S3 + CloudFront, Vercel, Netlify, Firebase Hosting).

## Project Structure

```
lib/
├── main.dart                    # App entry + routing
├── theme/
│   └── app_theme.dart          # Colors, typography, card styles
├── models/
│   ├── device.dart             # Device health data model
│   └── activity.dart           # Activity + hourly buckets
├── data/
│   └── mock_data.dart          # Simulated data until AWS is live
├── screens/
│   └── dashboard_screen.dart   # Single-page V1 dashboard
└── widgets/
    ├── device_health_card.dart
    ├── distance_card.dart
    ├── activity_timeline.dart
    └── daily_history.dart
```

## Design

Matches gosteady.co:
- Sage green `#4A7C59` primary, warm white `#FFFCF7` background
- Fraunces (serif) for headings, Inter (sans) for body and UI
- 20px rounded cards with soft shadows
- Calm, trustworthy, healthcare-adjacent tone

## Roadmap

| Version | Features |
|---------|----------|
| V1 (current) | Device health + distance traveled, mock data |
| V2 | Live AWS data via REST API, assistance score, 7d/30d views |
| V3 | Tip-over alerts, push notifications, device activation |
| V4 | Multi-device view, user accounts + auth, caregiver settings |

## License

Proprietary — GoSteady, 2026.
