import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "ryuhzk.simfarm"

  readonly property string serverUrl: String(setting("serverUrl", "")).trim()
  readonly property string sshHost: String(setting("sshHost", "")).trim()
  readonly property int localPort: boundedInt(setting("localPort", 8801), 1, 65535)
  readonly property int refreshIntervalSec: boundedInt(setting("refreshIntervalSec", 20), 5, 300)

  readonly property bool secureDirect: serverUrl.indexOf("https://") === 0
  // An https URL is already a secure origin, so it is polled and opened as-is.
  // A plain http one is tunnelled, and then everything speaks to localhost.
  readonly property string healthUrl: secureDirect
    ? serverUrl.replace(/\/$/, "") + "/healthz"
    : "http://127.0.0.1:" + localPort + "/healthz"

  readonly property bool configured: serverUrl !== "" && (secureDirect || sshHost !== "")
  readonly property string openerPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/simfarm-open")).replace(/^file:\/\//, ""))

  // Two orders of magnitude above a real /healthz body, and small enough that a
  // hostile or broken server cannot grow the bar's memory by answering.
  readonly property int healthByteCap: 65536

  // Whether a panel window exists. The widget is a launcher when it does not,
  // and a status readout only while there is a window the status is about.
  property bool panelOpen: false

  // -1 means "no answer yet or unreachable", which reads differently from a
  // reachable farm with nothing booted (0). The bar has to tell those apart:
  // one is a broken link, the other is an idle Mac.
  property int bootedCount: -1
  property int deviceCount: 0
  property string lastError: ""

  function boundedInt(value, minimum, maximum) {
    var parsed = parseInt(String(value), 10)
    if (!isFinite(parsed)) parsed = minimum
    return Math.max(minimum, Math.min(maximum, parsed))
  }

  function refresh() {
    if (!configured || healthProc.running) return
    // Two things happen here, and the order matters.
    //
    // First the gate: the launcher holds a pid file open for exactly as long as
    // the panel window exists. No live panel means nothing is asking on anyone's
    // behalf, so the widget says so and touches the network not at all — no
    // request to the Mac, no tunnel held open for a window nobody has.
    //
    // Then the read, capped. StdioCollector accumulates whatever arrives with no
    // cap of its own, so the cap belongs on the producer: curl refuses a response
    // that declares itself larger, and head bounds the ones that declare no size
    // at all. Truncated input fails JSON.parse below and reads as "no answer",
    // which is the right reading of a server behaving that way.
    //
    // The URL is a positional argument, never spliced into the script text.
    healthProc.command = ["sh", "-c",
                          'p=$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/simfarm/panel.pid" 2>/dev/null); ' +
                            'if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then ' +
                            "curl --silent --max-time 3 --max-filesize " + healthByteCap +
                            ' --url "$1" | head -c ' + healthByteCap + "; " +
                            'else printf \'{"panel":false}\'; fi',
                          "sh", healthUrl]
    healthProc.running = true
  }

  Process {
    id: healthProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d.panel === false) {
            // Not a failure — the panel is simply closed, and nothing was asked.
            root.panelOpen = false
            root.bootedCount = -1
            root.lastError = ""
            return
          }
          root.panelOpen = true
          root.bootedCount = typeof d.booted === "number" ? d.booted : 0
          root.deviceCount = typeof d.devices === "number" ? d.devices : 0
          root.lastError = ""
        } catch (e) {
          // The panel is up but the farm did not answer: the Mac is asleep, the
          // server is not running, or the tunnel came up and the far end did not.
          root.panelOpen = true
          root.bootedCount = -1
          root.lastError = "no answer from " + root.healthUrl
        }
      }
    }
  }

  Process { id: openProc }

  function openPanel() {
    if (!configured) return
    openProc.running = false
    // setsid --fork so the launcher outlives this Process object: it supervises
    // the panel and owns the tunnel, and the next click sets running=false here,
    // which would otherwise kill the supervisor and cut the tunnel out from
    // under the window that is still open.
    openProc.command = ["setsid", "--fork", openerPath,
                        "--url", serverUrl,
                        "--ssh", sshHost,
                        "--local-port", String(localPort)]
    openProc.running = true
    // The tunnel comes up as part of opening, so the next reading is the one
    // that actually has something to say.
    reprobe.restart()
  }

  Timer {
    id: reprobe
    interval: 4000
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.configured
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Hidden until it is pointed at a Mac — an unconfigured widget has nothing
  // true to show, and a permanent "—" on the bar is just noise.
  visible: configured
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Style.bar.iconFont, not font.caption — caption is ~10px, sized for words.
    // A glyph set at it reads a size smaller than every neighbour on the bar.
    fontSize: Style.bar.iconFont
    horizontalMargin: 6
    // Icon only. The count belongs in the tooltip: a number on the bar invites
    // you to read it, and how many simulators are booted is not something you
    // act on at a glance.
    // U+F10B is the Nerd Font phone glyph. Written as an escape because a raw
    // private-use character does not reliably survive being edited or copied.
    text: "\uf10b"
    tooltipText: !root.panelOpen
      ? "simfarm — click to open the panel"
      : root.bootedCount < 0
        ? ("simfarm — not connected\n" + root.lastError + "\nClick to open the panel")
        : (root.bootedCount + " booted of " + root.deviceCount + " devices\nClick to open the panel")
    onPressed: function() { root.openPanel() }
  }
}
