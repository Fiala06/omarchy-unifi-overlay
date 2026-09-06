.pragma library

// Presentation helpers. Kept out of the QML so they stay readable and can be
// reasoned about without a running shell.

var SIZES = ["small", "medium", "large"]
var SIZE_LABELS = { small: "S", medium: "M", large: "L" }
var QUALITIES = ["high", "medium", "low", "package"]

function nextSize(size) {
  var i = SIZES.indexOf(size)
  return SIZES[(i < 0 ? 0 : i + 1) % SIZES.length]
}

function sizeLabel(size) {
  return SIZE_LABELS[size] || "M"
}

// The bar icon carries the whole state at a glance: pinned, ready, or broken.
function barGlyph(state) {
  if (!state.configured) return "󰜥"   // camera-off: nothing set up yet
  if (state.pipRunning) return "󰜐"    // cctv: live view is on screen
  if (!state.reachable) return "󰜥"
  return "󰃅"                          // camera: ready, not pinned
}

function stateDot(camera) {
  return camera && camera.connected ? "●" : "○"
}

function cameraMeta(camera) {
  if (!camera) return ""
  var state = String(camera.state || "UNKNOWN").toLowerCase()
  return state.charAt(0).toUpperCase() + state.slice(1)
}

// One line under the title that answers "what is this doing right now".
function heroMeta(state) {
  if (!state.configured) return "Not connected"
  if (state.busy) return "Working…"
  if (!state.reachable && state.lastError) return "Unreachable"
  var parts = []
  if (state.pipRunning) parts.push("Pinned · " + sizeName(state.pipSize))
  else if (state.mode === "grid") parts.push("Grid ready")
  else if (!state.activeCameraId) parts.push("No camera selected")
  else parts.push("Ready")
  if (state.alertsRunning) parts.push("alerts on")
  return parts.join(" · ")
}

// Names of the cameras making up the grid, in the order they are composited.
function gridNames(cameras, ids) {
  var names = []
  for (var i = 0; i < ids.length; i++) {
    var camera = findCamera(cameras, ids[i])
    names.push(camera ? camera.name : "unknown")
  }
  return names.join(", ")
}

function sizeName(size) {
  if (size === "small") return "small"
  if (size === "large") return "large"
  return "medium"
}

function heroTitle(state) {
  if (state.activeCameraName) return state.activeCameraName
  if (!state.configured) return "UniFi Overlay"
  return "UniFi Overlay"
}

// Turn the bridge's error into something worth reading in a 380px panel.
function friendlyError(message) {
  var text = String(message || "").trim()
  if (!text) return ""
  if (text.indexOf("No API key") === 0) return "No API key stored. Open settings."
  if (text.indexOf("No UniFi console") === 0) return "No console set. Open settings."
  if (text.indexOf("API key rejected") === 0) return "API key rejected. Regenerate it."
  if (text.indexOf("Cannot reach") === 0) return text
  if (text.length > 120) return text.slice(0, 117) + "…"
  return text
}

function parseJson(text) {
  try {
    var value = JSON.parse(String(text || "").trim())
    return (value && typeof value === "object") ? value : null
  } catch (e) {
    return null
  }
}

function findCamera(cameras, id) {
  if (!id) return null
  for (var i = 0; i < cameras.length; i++) {
    if (cameras[i].id === id) return cameras[i]
  }
  return null
}
