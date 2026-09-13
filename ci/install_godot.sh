#!/usr/bin/env bash
# Installs the pinned Godot editor and its export templates for headless export.
#
# Both land in the exact locations Godot looks in, so every later command is a
# plain `godot ...` with no extra flags. Skips work that a warm cache already did.
set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:?GODOT_VERSION must be set, e.g. 4.7}"
GODOT_RELEASE="${GODOT_RELEASE:-stable}"
FULL="${GODOT_VERSION}-${GODOT_RELEASE}"

BASE="https://github.com/godotengine/godot/releases/download/${FULL}"
INSTALL_DIR="${HOME}/godot"
# Godot resolves templates by "<version>.<status>" and will not look anywhere else.
TEMPLATE_DIR="${HOME}/.local/share/godot/export_templates/${GODOT_VERSION}.${GODOT_RELEASE}"

mkdir -p "$INSTALL_DIR" "$TEMPLATE_DIR"

if [[ ! -x "${INSTALL_DIR}/godot" ]]; then
	echo "Downloading Godot ${FULL} editor…"
	curl -fsSL --retry 3 -o /tmp/godot.zip "${BASE}/Godot_v${FULL}_linux.x86_64.zip"
	unzip -q -o /tmp/godot.zip -d /tmp/godot-editor
	mv "/tmp/godot-editor/Godot_v${FULL}_linux.x86_64" "${INSTALL_DIR}/godot"
	chmod +x "${INSTALL_DIR}/godot"
	rm -rf /tmp/godot.zip /tmp/godot-editor
else
	echo "Godot editor already present (cache hit)."
fi

if [[ -z "$(ls -A "$TEMPLATE_DIR" 2>/dev/null)" ]]; then
	echo "Downloading Godot ${FULL} export templates…"
	curl -fsSL --retry 3 -o /tmp/templates.tpz "${BASE}/Godot_v${FULL}_export_templates.tpz"
	unzip -q -o /tmp/templates.tpz -d /tmp/templates
	mv /tmp/templates/templates/* "$TEMPLATE_DIR/"
	rm -rf /tmp/templates.tpz /tmp/templates
else
	echo "Export templates already present (cache hit)."
fi

"${INSTALL_DIR}/godot" --version
