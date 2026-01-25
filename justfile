# Ports - macOS menubar app

# Build debug
build:
    swift build

# Build release
release:
    swift build -c release

# Create app bundle (requires release build)
bundle: release
    #!/usr/bin/env bash
    set -euo pipefail
    
    APP_BUNDLE=".build/release-bundle/Ports.app"
    CONTENTS="${APP_BUNDLE}/Contents"
    
    rm -rf "${APP_BUNDLE}"
    mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
    
    cp .build/release/Ports "${CONTENTS}/MacOS/Ports"
    cp Sources/Info.plist "${CONTENTS}/Info.plist"
    
    xcrun actool Sources/Assets.xcassets \
        --compile "${CONTENTS}/Resources" \
        --platform macosx \
        --minimum-deployment-target 13.0 \
        --app-icon AppIcon \
        --output-partial-info-plist .build/release-bundle/AssetInfo.plist
    
    echo "Created ${APP_BUNDLE}"

# Sign app bundle (requires bundle)
sign: bundle
    codesign --force --options runtime \
        --sign "Developer ID Application" \
        .build/release-bundle/Ports.app/Contents/MacOS/Ports
    codesign --force --options runtime \
        --sign "Developer ID Application" \
        .build/release-bundle/Ports.app
    codesign --verify --deep --strict --verbose=2 .build/release-bundle/Ports.app

# Create DMG (requires signed bundle)
dmg: sign
    #!/usr/bin/env bash
    set -euo pipefail
    
    rm -rf .build/dmg
    mkdir -p .build/dmg/staging
    cp -R .build/release-bundle/Ports.app .build/dmg/staging/
    ln -s /Applications .build/dmg/staging/Applications
    
    hdiutil create -volname "Ports" \
        -srcfolder .build/dmg/staging \
        -ov -format UDRW \
        .build/dmg/Ports-temp.dmg
    
    hdiutil convert .build/dmg/Ports-temp.dmg \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o .build/dmg/Ports.dmg
    
    rm .build/dmg/Ports-temp.dmg
    rm -rf .build/dmg/staging
    
    codesign --force --sign "Developer ID Application" .build/dmg/Ports.dmg
    
    echo "Created .build/dmg/Ports.dmg"

# Run the app (debug build)
run: build
    .build/debug/Ports

# Clean build artifacts
clean:
    rm -rf .build
