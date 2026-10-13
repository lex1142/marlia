#!/bin/bash
# Builds Marlia.app from scratch into build/ — there is no Xcode project; the app is
# compiled directly with swiftc. This file holds the one list of sources: CI calls it too.
#
#   ./build.sh          compile and assemble build/Marlia.app
#   ./build.sh --run    ...then (re)launch it
#   ./build.sh --dmg    ...then package build/Marlia-<version>.dmg
#
# Environment:
#   SDK=/path/to.sdk    compile against a specific SDK (passed to swiftc -sdk)
set -euo pipefail
cd "$(dirname "$0")"

SOURCES=(
  App/MarliaApp.swift App/MainMenu.swift App/WindowControllers.swift App/main.swift
  Models/FileItem.swift Models/WindowStateStore.swift Models/KeyboardShortcuts.swift
  Models/SortPreferencesStore.swift Models/FileClipboard.swift Models/Theme.swift
  Models/BatchRenamePlan.swift Models/UndoHistory.swift
  ViewModels/PaneViewModel.swift
  Views/ContentView.swift Views/PaneView.swift Views/PaneView+Columns.swift
  Views/PaneInteractionViews.swift Views/Sidebar.swift Views/GetInfoView.swift Views/HelpView.swift
  Views/ConflictResolutionView.swift Views/CreateArchiveView.swift Views/ArchiveContentsView.swift
  Views/ConnectToServerView.swift Views/OperationProgress.swift Views/ShortcutSettingsView.swift
  Views/FileTableView.swift Views/FileIconsView.swift Views/ColumnTableView.swift
  Views/BatchRenameView.swift Views/InspectorView.swift Views/DiskImageInstallView.swift
  Services/FileOperationService.swift Services/ArchiveService.swift Services/NetworkMountService.swift
  Services/DiskOperationQueue.swift Services/OperationControl.swift Services/DirectoryWatcher.swift
  Services/ThumbnailCache.swift Services/WorkspaceStore.swift Services/QuickLookController.swift
)

RUN=0; DMG=0
for arg in "$@"; do
  case "$arg" in
    --run) RUN=1 ;;
    --dmg) DMG=1 ;;
    *) echo "usage: $0 [--run] [--dmg]" >&2; exit 2 ;;
  esac
done

# With only the Command Line Tools installed, the macOS 27 SDK can't build SwiftUI's
# @State macro (its implementation ships with Xcode only). Fall back to the 26.5 SDK
# when it's there, unless an SDK was given explicitly.
CLT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
if [[ -z "${SDK:-}" && "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools && -d "$CLT_SDK" ]]; then
  SDK="$CLT_SDK"
fi
SDK_ARGS=()
[[ -n "${SDK:-}" ]] && SDK_ARGS=(-sdk "$SDK")

# The -target stamps the Mach-O minos; without it the app refuses to launch on Ventura
# even though Info.plist says 13.5.
mkdir -p build
echo "Compiling…"
swiftc -O -target arm64-apple-macosx13.5 ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} "${SOURCES[@]}" -o build/Marlia

APP=build/Marlia.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/Marlia.icns "$APP/Contents/Resources/Marlia.icns"
# Remove first, then copy: overwriting the binary in place keeps its inode, and the
# kernel's cached signature for it makes the next launch fail ("Launchd job spawn failed").
rm -f "$APP/Contents/MacOS/Marlia"
cp build/Marlia "$APP/Contents/MacOS/Marlia"
codesign --force --sign - "$APP"
echo "Built $APP"

if (( DMG )); then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" App/Info.plist)
  IMAGE="build/Marlia-$VERSION.dmg"
  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  cp -R "$APP" "$STAGE"/
  ln -s /Applications "$STAGE"/Applications
  cp "Packaging/Read Me.txt" "$STAGE"/
  hdiutil create -quiet -volname "Marlia $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$IMAGE"
  echo "Built $IMAGE"
fi

if (( RUN )); then
  pkill -x Marlia 2>/dev/null && sleep 1 || true
  open "$APP"
fi
