extends RefCounted
## Build stamp for this binary, at the fixed path the launcher preloads.
##
## The checked-in values are the "local dev build" defaults. CI overwrites this
## file (in the workspace only, never committed) right before exporting, so the
## shipped APK/EXE and the shipped content pack each carry the versions they
## were built with.
##
## See ci/prepare_build.sh and docs/UPDATES.md.

## Bumped by hand in version.json. A higher value than the installed one means
## a new APK/EXE is required -- a content pack cannot deliver this change.
const BINARY_VERSION: int = 0

## Bumped automatically by CI on every release. A higher value than the
## installed one can be delivered as a content pack alone.
const CONTENT_VERSION: int = 0

## Cosmetic, shown in the UI.
const VERSION_NAME: String = "0.0.0-dev"

## Short commit SHA this build came from, or "local" outside CI.
const COMMIT: String = "local"

## RFC3339 build timestamp, or "" outside CI.
const BUILT_AT: String = ""

## True when this build came out of CI rather than a local export/editor run.
const IS_CI_BUILD: bool = false

## What landed in this build, newest first. Baked in so the app can show its own
## patch notes with no network access.
const CHANGES := []
