import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owner of all UniFi Protect state.
//
// A `service` is mounted once per session while a `bar-widget` is mounted once
// per monitor, so the console config, the camera list, and the pinned-window
// lifetime all live here. Surfaces reach them through
// `bar.shell.serviceFor("unifi-overlay")`.
QtObject {
  id: root

  // Injected by the shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/unifi-overlay"
  readonly property string bridge: pluginDir + "/bin/unifi-protect"

  // ------------------------------------------------------------------ state
  property string host: ""
  property bool hasKey: false
  property string activeCameraId: ""
  property string activeCameraName: ""
  property string quality: "high"
  property string pipSize: "medium"
  property bool pipRunning: false
  property bool reachable: false
  property string consoleVersion: ""
  property var cameras: []

  // --- presentation
  property string mode: "single"
  property real opacity: 1.0
  property string monitor: ""
  property var monitors: []
  property bool autoHideFullscreen: true

  // --- selection
  property var favorites: []
  property var gridCameras: []

  // --- alerts
  property bool alertsEnabled: false
  property bool alertsRunning: false
  property int alertPort: 8723
  property int alertSeconds: 30
  property string webhookUrl: ""

  property bool busy: false
  property bool loadingCameras: false
  property string lastError: ""
  property string actionStatus: ""

  // Surfaces that are on screen bump this, so the liveness poll runs often
  // while someone is looking and rarely when nobody is.
  property int panelWatchers: 0

  property string snapshotPath: ""
  // Bumped on every successful still so Image sources change and miss the cache.
  property int snapshotStamp: 0
  property bool snapshotBusy: false

  readonly property bool configured: host.length > 0 && hasKey
  readonly property var activeCamera: Model.findCamera(cameras, activeCameraId)
  readonly property string errorText: Model.friendlyError(lastError)
  readonly property bool gridReady: gridCameras.length > 0

  // The cameras the scroll wheel steps through: favourites if any are marked,
  // otherwise everything.
  readonly property var cyclePool: {
    if (!favorites || favorites.length === 0) return cameras
    var pool = []
    for (var i = 0; i < cameras.length; i++) {
      if (favorites.indexOf(cameras[i].id) !== -1) pool.push(cameras[i])
    }
    return pool.length > 0 ? pool : cameras
  }

  // Everything the surfaces need for a glance, in one object.
  readonly property var glanceState: ({
    configured: root.configured,
    reachable: root.reachable,
    pipRunning: root.pipRunning,
    pipSize: root.pipSize,
    mode: root.mode,
    busy: root.busy,
    activeCameraId: root.activeCameraId,
    activeCameraName: root.activeCameraName,
    alertsRunning: root.alertsRunning,
    lastError: root.lastError
  })

  signal statusRefreshed()
  signal camerasRefreshed()
  signal snapshotReady()

  // -------------------------------------------------------------- commands

  function refreshStatus() {
    if (statusProc.running) return
    statusProc.command = [root.bridge, "status"]
    statusProc.running = true
  }

  // Everything that needs a reachable console, run once the config actually
  // says we have one. This used to hang off a fixed 1200ms timer, which lost
  // the race whenever the first status call was slow -- the camera list never
  // loaded and the bar icon stayed struck through until the panel was opened.
  onConfiguredChanged: if (root.configured) root.onBecameConfigured()

  function onBecameConfigured() {
    root.refreshCameras()
    root.ensureAlerts()
  }

  // `alerts ensure` is a no-op unless the config says alerts are enabled and
  // the listener is down, so the decision stays in the bridge rather than in
  // a race between a status read and a start.
  function ensureAlerts() {
    if (alertsProc.running || !root.configured) return
    alertsProc.command = [root.bridge, "alerts", "ensure"]
    alertsProc.running = true
  }

  // `status` is a local read, so it never notices a console that has gone
  // away. This is the only call that does, kept to its own slow cadence.
  function probeReachable() {
    if (reachProc.running || !root.configured) return
    reachProc.command = [root.bridge, "check"]
    reachProc.running = true
  }

  function refreshCameras() {
    if (camerasProc.running) return
    root.loadingCameras = true
    camerasProc.command = [root.bridge, "cameras"]
    camerasProc.running = true
  }

  function grabSnapshot(highQuality) {
    if (snapshotProc.running || !root.activeCameraId || !root.configured) return
    root.snapshotBusy = true
    var args = [root.bridge, "snapshot", "--camera-id", root.activeCameraId]
    if (highQuality) args.push("--high")
    snapshotProc.command = args
    snapshotProc.running = true
  }

  // `kind` labels the in-flight call so onStreamFinished knows what it read
  // back; one Process keeps the mutating calls serialized, which is what we
  // want anyway (starting a pin while stopping one is nonsense).
  property string pendingAction: ""

  function runAction(kind, args, status) {
    if (actionProc.running) return false
    root.pendingAction = kind
    root.busy = true
    root.actionStatus = status || ""
    root.lastError = ""
    actionProc.command = [root.bridge].concat(args)
    actionProc.running = true
    return true
  }

  function togglePip() {
    return runAction("pip", ["pip", "toggle", "--size", root.pipSize,
                             "--mode", root.mode],
                     root.pipRunning ? "Unpinning…" : "Pinning…")
  }

  function startPip() {
    return runAction("pip", ["pip", "start", "--size", root.pipSize,
                             "--mode", root.mode], "Pinning…")
  }

  function stopPip() {
    return runAction("pip", ["pip", "stop"], "Unpinning…")
  }

  function openWindow() {
    return runAction("open", ["open"], "Opening…")
  }

  function selectCamera(cameraId, cameraName) {
    if (!cameraId) return false
    var wasPinned = root.pipRunning && root.mode === "single"
    root.activeCameraId = cameraId
    root.activeCameraName = cameraName || ""
    root.snapshotStamp = 0
    var args = ["config", "--camera-id", cameraId]
    if (cameraName) args = args.concat(["--camera-name", cameraName])
    // Re-pin onto the new camera so switching from the list does the obvious
    // thing rather than leaving the old feed on screen.
    return runAction(wasPinned ? "select-repin" : "select", args, "Switching…")
  }

  // Step through the cycle pool. The bridge owns the wrap-around and re-pins
  // if a view is already up, so the wheel works whether or not one is.
  function cycleCamera(direction) {
    return runAction("cycle", ["cycle", direction === "prev" ? "prev" : "next"], "")
  }

  function cameraAt(index) {
    if (index < 0 || index >= cameras.length) return null
    return cameras[index]
  }

  function toggleFavorite(cameraId) {
    if (!cameraId) return false
    return runAction("favorite", ["favorites", "toggle", "--camera-id", cameraId], "")
  }

  function setSize(size) {
    if (Model.SIZES.indexOf(size) === -1 || size === root.pipSize) return false
    var wasPinned = root.pipRunning
    root.pipSize = size
    return runAction(wasPinned ? "size-repin" : "size",
                     ["config", "--size", size], "Resizing…")
  }

  function cycleSize() {
    return setSize(Model.nextSize(root.pipSize))
  }

  function setMode(value) {
    if (value !== "single" && value !== "grid") return false
    var wasPinned = root.pipRunning
    root.mode = value
    return runAction(wasPinned ? "mode-repin" : "mode",
                     ["config", "--mode", value], "Switching view…")
  }

  function toggleMode() {
    return setMode(root.mode === "grid" ? "single" : "grid")
  }

  function setGridCameras(ids) {
    return runAction("grid", ["grid", "--cameras", (ids || []).join(",")], "Saving grid…")
  }

  function toggleGridMember(cameraId) {
    if (!cameraId) return false
    var next = []
    var present = false
    for (var i = 0; i < gridCameras.length; i++) {
      if (gridCameras[i] === cameraId) { present = true; continue }
      next.push(gridCameras[i])
    }
    if (!present) {
      if (next.length >= 4) return false      // grid holds four; drop one first
      next.push(cameraId)
    }
    return setGridCameras(next)
  }

  // Opacity is a live window property, so this lands without a re-pin.
  function setOpacity(value) {
    var next = Math.max(0.1, Math.min(1.0, Number(value)))
    root.opacity = next
    return runAction("opacity", ["config", "--opacity", String(next)], "")
  }

  function setMonitor(name) {
    root.monitor = name || ""
    return runAction("monitor", ["config", "--monitor", root.monitor], "Applying…")
  }

  function setAutoHide(enabled) {
    root.autoHideFullscreen = enabled === true
    return runAction("autohide",
                     ["config", "--autohide", enabled ? "true" : "false"], "")
  }

  function setQuality(value) {
    if (Model.QUALITIES.indexOf(value) === -1) return false
    root.quality = value
    return runAction("quality", ["config", "--quality", value], "Saving…")
  }

  function setAlertSeconds(seconds) {
    return runAction("alert-seconds",
                     ["config", "--alert-seconds", String(Math.max(5, seconds))], "")
  }

  function toggleAlerts() {
    return runAction("alerts",
                     ["alerts", root.alertsRunning ? "stop" : "start"],
                     root.alertsRunning ? "Stopping…" : "Starting…")
  }

  function setHost(value) {
    var next = String(value || "").trim()
    if (!next) return false
    root.host = next
    return runAction("host", ["config", "--host", next], "Saving…")
  }

  function storeKey(key) {
    if (keyProc.running) return false
    var text = String(key || "").trim()
    if (!text || !root.host) return false
    root.busy = true
    root.actionStatus = "Storing key…"
    root.lastError = ""
    keyProc.command = [root.bridge, "key", "set", "--host", root.host]
    keyProc.stdinEnabled = true
    keyProc.running = true
    keyProc.pendingKey = text
    return true
  }

  function clearKey() {
    return runAction("key-clear", ["key", "clear"], "Removing key…")
  }

  function checkConnection() {
    return runAction("check", ["check"], "Testing…")
  }

  // --------------------------------------------------------------- parsing

  function applyStatus(payload) {
    if (!payload) return
    var config = payload.config || {}
    root.host = String(config.host || "")
    root.activeCameraId = String(config.cameraId || "")
    root.activeCameraName = String(config.cameraName || "")
    root.quality = String(config.quality || "high")
    root.pipSize = String(config.size || "medium")
    root.mode = String(config.mode || "single")
    root.monitor = String(config.monitor || "")
    root.opacity = Number(config.opacity === undefined ? 1.0 : config.opacity)
    root.autoHideFullscreen = config.autoHideFullscreen !== false
    root.favorites = config.favorites || []
    root.gridCameras = config.gridCameras || []
    root.alertsEnabled = config.alertsEnabled === true
    root.alertPort = Number(config.alertPort || 8723)
    root.alertSeconds = Number(config.alertSeconds || 30)
    if (payload.monitors) root.monitors = payload.monitors
    if (payload.alertsRunning !== undefined) root.alertsRunning = payload.alertsRunning === true
    if (payload.webhook) root.webhookUrl = String(payload.webhook)
    root.hasKey = payload.hasKey === true
    root.pipRunning = payload.pipRunning === true
    if (payload.snapshotPath) root.snapshotPath = String(payload.snapshotPath)
    root.statusRefreshed()
  }

  // ------------------------------------------------------------- processes

  property Process statusProc: Process {
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = Model.parseJson(text)
        if (payload) root.applyStatus(payload)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.lastError) {
        root.lastError = "Bridge failed to report status."
      }
    }
  }

  property Process camerasProc: Process {
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = Model.parseJson(text)
        root.loadingCameras = false
        if (!payload) {
          root.lastError = "Could not read the camera list."
          root.reachable = false
          return
        }
        if (payload.ok === false) {
          root.lastError = payload.error || "Could not list cameras."
          root.reachable = false
          root.cameras = []
          return
        }
        root.cameras = payload.cameras || []
        if (payload.favorites) root.favorites = payload.favorites
        if (payload.gridCameras) root.gridCameras = payload.gridCameras
        root.reachable = true
        root.lastError = ""
        // A camera can be renamed or removed on the console between sessions.
        var active = Model.findCamera(root.cameras, root.activeCameraId)
        if (active && active.name !== root.activeCameraName) {
          root.activeCameraName = active.name
        }
        root.camerasRefreshed()
      }
    }
    onExited: function(exitCode) {
      root.loadingCameras = false
      if (exitCode !== 0 && !root.lastError) root.lastError = "Bridge failed."
    }
  }

  property Process snapshotProc: Process {
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.snapshotBusy = false
        var payload = Model.parseJson(text)
        if (!payload || payload.ok === false) return
        root.snapshotPath = String(payload.path || root.snapshotPath)
        root.snapshotStamp = root.snapshotStamp + 1
        root.snapshotReady()
      }
    }
    onExited: root.snapshotBusy = false
  }

  property Process actionProc: Process {
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var kind = root.pendingAction
        root.pendingAction = ""
        root.busy = false
        root.actionStatus = ""
        var payload = Model.parseJson(text)

        if (!payload) {
          root.lastError = "The bridge returned nothing usable."
          return
        }
        if (payload.ok === false) {
          root.lastError = payload.error || "Command failed."
          if (kind === "pip") root.pipRunning = payload.running === true
          return
        }

        root.lastError = ""
        if (kind === "pip") {
          root.pipRunning = payload.running === true
          if (payload.cameraName) root.activeCameraName = String(payload.cameraName)
          if (payload.size) root.pipSize = String(payload.size)
          if (payload.mode) root.mode = String(payload.mode)
        } else if (kind === "check") {
          root.reachable = true
          root.consoleVersion = String(payload.version || "")
          root.actionStatus = "Connected to Protect " + root.consoleVersion
          statusClear.restart()
          root.refreshCameras()
        } else if (kind === "cycle") {
          root.activeCameraId = String(payload.cameraId || root.activeCameraId)
          root.activeCameraName = String(payload.cameraName || root.activeCameraName)
          root.pipRunning = payload.pinned === true
          root.snapshotStamp = 0
          root.grabSnapshot(false)
        } else if (kind === "favorite") {
          root.favorites = payload.favorites || []
        } else if (kind === "grid") {
          root.gridCameras = payload.gridCameras || []
        } else if (kind === "alerts") {
          root.alertsRunning = payload.running === true
          root.alertsEnabled = root.alertsRunning
          if (payload.webhook) root.webhookUrl = String(payload.webhook)
        } else if (kind === "select-repin" || kind === "size-repin"
                   || kind === "mode-repin") {
          // The config write landed; now move the live window onto it.
          root.startPip()
          return
        } else if (kind === "select") {
          root.grabSnapshot(false)
        } else if (kind === "host" || kind === "key-clear") {
          root.refreshStatus()
          root.cameras = []
          root.reachable = false
        }
        if (payload.config) root.applyStatus(payload)
      }
    }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0 && !root.lastError) {
        root.lastError = "Bridge exited with code " + exitCode + "."
      }
    }
  }

  property Process keyProc: Process {
    property string pendingKey: ""
    command: []
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        root.actionStatus = ""
        var payload = Model.parseJson(text)
        if (!payload || payload.ok === false) {
          root.lastError = (payload && payload.error) || "Could not store the key."
          return
        }
        root.hasKey = payload.hasKey === true
        root.lastError = ""
        root.actionStatus = "API key stored"
        statusClear.restart()
        root.checkConnection()
      }
    }
    onStarted: {
      // The key goes down stdin so it never appears in argv, where any other
      // process on the box could read it out of /proc.
      keyProc.write(keyProc.pendingKey + "\n")
      keyProc.pendingKey = ""
      keyProc.stdinEnabled = false
    }
    onExited: root.busy = false
  }

  property Process alertsProc: Process {
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = Model.parseJson(text)
        if (!payload) return
        if (payload.ok === false) {
          // A listener that cannot bind used to fail silently, which read as
          // a toggle that flipped itself back off for no stated reason.
          root.alertsRunning = false
          root.alertsEnabled = false
          root.lastError = payload.error || "Could not start the alert listener."
          return
        }
        root.alertsRunning = payload.running === true
        if (payload.enabled !== undefined) root.alertsEnabled = payload.enabled === true
        if (payload.webhook) root.webhookUrl = String(payload.webhook)
        if (payload.seconds) root.alertSeconds = Number(payload.seconds)
      }
    }
  }

  function refreshAlerts() {
    if (alertsProc.running) return
    alertsProc.command = [root.bridge, "alerts", "status"]
    alertsProc.running = true
  }

  property Process reachProc: Process {
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = Model.parseJson(text)
        if (!payload) return
        if (payload.ok === false) {
          root.reachable = false
          return
        }
        root.reachable = true
        if (payload.version) root.consoleVersion = String(payload.version)
      }
    }
  }

  // ----------------------------------------------------------------- timers

  property Timer statusClear: Timer {
    interval: 4000
    onTriggered: root.actionStatus = ""
  }

  // The pinned window can also die on its own -- mpv killed, camera gone --
  // so the icon re-syncs with reality rather than trusting the last command.
  //
  // Each tick is a process spawn, and the only thing it catches is mpv dying,
  // so it runs at 5s while something is pinned or a panel is open and backs
  // right off otherwise rather than spawning ~17k processes a day for nothing.
  property Timer pipPoll: Timer {
    interval: (root.pipRunning || root.panelWatchers > 0) ? 5000 : 30000
    running: true
    repeat: true
    onTriggered: if (!root.busy) root.refreshStatus()
  }

  // The only poll that touches the network, so it gets its own slow cadence.
  property Timer reachPoll: Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: if (!root.busy) root.probeReachable()
  }

  property Timer boot: Timer {
    interval: 400
    running: true
    repeat: false
    // onConfiguredChanged picks it up from here once the config lands.
    onTriggered: root.refreshStatus()
  }
}
