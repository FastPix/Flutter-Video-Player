---
name: Bug Report
about: Create a report to help us improve
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description

A clear and concise description of what the bug is.

## Reproduction Steps

1. **Setup Environment**

```yaml
dependencies:
  fastpix_player: 0.1.0
```

2. **Code To Reproduce**

```dart
FastPixPlayer( controller: controller,
  width: 350,
  height: 200,
  aspectRatio: FastPixAspectRatio.ratio16x9,
  showLoadingIndicator: true,
  loadingIndicatorColor: Colors.white,
  showErrorDetails: false,
)
```

3. **Expected Behavior**
```
<!-- A clear and concise description of what you expected to happen.  -->
```

4. **Actual Behavior**
```
<!-- A clear and concise description of what actually happened. -->
```

5. **Environment**

- **SDK Version**: [e.g., 1.2.2]
- **Android Version**: [e.g., Android 12]
- **Min SDK Version**: [e.g., 24]
- **Target SDK Version**: [e.g., 35]
- **Device/Emulator**: [e.g., Pixel 5, Android Emulator]
- **Player**: [e.g., ExoPlayer 2.19.0, VideoView, etc.]
- **Kotlin Version**: [e.g., 2.0.21]

## Code Sample

```dart
// Please provide a minimal code sample that reproduces the issue
FastPixPlayer( controller: controller,
  width: 350,
  height: 200,
  aspectRatio: FastPixAspectRatio.ratio16x9,
  showLoadingIndicator: true,
  loadingIndicatorColor: Colors.white,
  showErrorDetails: false,
)
```

## Logs/Stack Trace

```
Paste relevant logs or stack traces here
```

## Additional Context

Add any other context about the problem here.

## Screenshots

If applicable, add screenshots to help explain your problem.

