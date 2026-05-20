# Distribution And Compliance

## Product Variants

- GitHub builds may support Apple Music plus third-party sources such as NetEase
  Music and QQ Music.
- The Mac App Store variant is Apple Music-only and should use official Apple
  Music API/MusicKit authorization for Apple Music account access.

## Shared System Features

- System-level features that are not tied to a music source should stay
  source-agnostic so they can be reused by both variants.
- Audio output switching belongs in shared Core logic, not in Apple Music,
  NetEase, QQ Music, or any player-specific integration.
- Audio output switching must use public Core Audio APIs only and should not add
  microphone/audio-input, Bluetooth, Accessibility, helper tool, shell
  automation, System Settings automation, private framework, or private selector
  requirements.

## Review Notes

- For App Store review, describe the output switcher as a user-initiated selector
  for macOS-detected output-capable devices. It changes the system-wide default
  output and follows macOS when devices appear, disappear, or the default changes
  elsewhere.
- Do not infer App Store readiness from the source entitlement file alone. Verify
  the signed app bundle entitlements; the current local GitHub build script signs
  its ad-hoc bundle with App Sandbox disabled, while the App Store variant must be
  sandboxed.
