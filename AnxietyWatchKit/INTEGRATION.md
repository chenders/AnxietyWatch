# AnxietyWatchKit Integration Guide

## Package Structure

The AnxietyWatchKit package has been created with the following structure:

```
AnxietyWatchKit/
├── Package.swift
├── Sources/
│   └── AnxietyWatchKit/
│       ├── AnxietyWatchKit.swift (public umbrella)
│       ├── BLE/
│       ├── Diagnostics/
│       ├── Pipeline/
│       ├── Storage/
│       ├── Sync/
│       ├── Transport/
│       └── ViewModels/
└── Tests/
    └── AnxietyWatchKitTests/
        └── UmbrellaTests.swift
```

## Verification

The package has been verified to build and test successfully:

```bash
# Build the package
swift build --package-path AnxietyWatchKit

# Run tests
swift test --package-path AnxietyWatchKit
```

## Xcode Integration

To integrate the AnxietyWatchKit package into the Xcode project:

1. Open AnxietyWatch.xcodeproj in Xcode
2. In the Project Navigator, right-click on the project root and select "Add Package Dependency..."
3. Select "Add Local..." and navigate to the AnxietyWatchKit folder
4. Select the AnxietyWatchKit package
5. In the Target Selection dialog:
   - Check "AnxietyWatch" target
   - Check "AnxietyWatch Watch App" target
6. Click "Add Package"

Alternatively, you can manually edit the project.pbxproj file to add the package references, but this is more error-prone.

## Dependencies

The package depends on:
- GRDB.swift (version 6.x) - for SQLite database access
- iOS 17+, watchOS 10+, macOS 14+ (for testing)

## Current Status

The package now contains the v3 storage, sync, BLE, pipeline, diagnostics,
transport, and view-model foundations. It is integrated as a local package
dependency of both the AnxietyWatch iOS app and Watch App targets.

## Integration Requirement

Xcode-project integration was intentionally deferred while the package
foundations were developed in isolation, then completed when app and Watch
consumers were introduced. New package APIs used by either target must remain
linked to the appropriate target and should be verified with both package tests
and application-target builds.