"""Headless Quickshell test of the real Main.qml and real pidfd helper.

Only Noctalia's compositor facade/logger are stubbed; Qt, Hyprland bindings,
Process, SplitParser and the plugin host are the installed runtime versions.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('qs'), 'Quickshell is not installed')
class QmlIntegrationTests(unittest.TestCase):
    def test_registration_and_exit_reach_qml(self):
        with tempfile.TemporaryDirectory(prefix='taskdock-qml-') as directory:
            directory = Path(directory)
            shutil.copy(ROOT / 'Main.qml', directory / 'Main.qml')
            os.symlink(ROOT / 'scripts', directory / 'scripts')
            commons = directory / 'Commons'
            commons.mkdir()
            (commons / 'Logger.qml').write_text('''pragma Singleton
import QtQuick
QtObject {
  function d(tag, message) {}
  function w(tag, message) { console.warn(tag + ": " + message); }
}
''')
            compositor = directory / 'Services/Compositor'
            compositor.mkdir(parents=True)
            (compositor / 'CompositorService.qml').write_text('''pragma Singleton
import QtQuick
QtObject {
  property bool isHyprland: true
  property ListModel windows: ListModel {}
  signal windowListChanged()
  signal activeWindowChanged()
  signal workspaceChanged()
}
''')
            (directory / 'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services.Compositor
ShellRoot {
  id: test
  property int phase: 0
  property bool launched: false
  QtObject {
    id: api
    property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\\/\\//, "").replace(/\\/$/, "")
    property var pluginSettings: ({})
    property var manifest: ({})
  }
  Main { id: main; pluginApi: api }
  Process {
    id: child
    command: ["sleep", "60"]
    running: true
    onStarted: Qt.callLater(test.registerChild)
  }
  function registerChild() {
    if (!main.processReady || !child.running || launched)
      return;
    launched = true;
    // Validate host snapshot deduplication and stable/address-reuse tokens.
    CompositorService.windows.append({id: "0xabc", appId: "test", title: "test"});
    CompositorService.windows.append({id: "abc", appId: "test", title: "test"});
    main.captureWindows();
    if (main.trackedWindows.length !== 1)
      throw new Error("snapshot did not deduplicate addresses");
    const oldToken = main.trackedWindows[0].trackId;
    const generation = main.processGeneration;
    main.captureWindows();
    if (main.trackedWindows[0].trackId !== oldToken)
      throw new Error("token changed without window replacement");
    if (main.processGeneration !== generation)
      throw new Error("unchanged processes were re-registered");
    CompositorService.windows.clear();
    main.captureWindows();
    CompositorService.windows.append({id: "abc", appId: "test", title: "test"});
    main.captureWindows();
    if (main.trackedWindows[0].trackId === oldToken)
      throw new Error("reused address retained old token");
    main.trackedWindows = [{id: "test-address", trackId: "test-token", pid: child.processId}];
    main.sendProcessSnapshot();
  }
  Connections {
    target: main
    function onProcessReadyChanged() { Qt.callLater(test.registerChild); }
    function onAliveWindowIdsChanged() {
      if (test.phase === 0 && main.aliveWindowIds["test-token"]) {
        test.phase = 1;
        child.signal(15);
      } else if (test.phase === 1 && !main.aliveWindowIds["test-token"]) {
        console.log("TASKDOCK_QML_INTEGRATION_OK");
        Qt.quit();
      }
    }
  }
  Timer {
    interval: 5000; running: true
    onTriggered: { child.signal(15); console.error("TASKDOCK_QML_TIMEOUT"); Qt.quit(); }
  }
}
''')
            result = subprocess.run(['qs', '-p', str(directory)],
                                    env=dict(os.environ, QT_QPA_PLATFORM='offscreen'),
                                    capture_output=True, text=True, timeout=10)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('TASKDOCK_QML_INTEGRATION_OK', output, output)
            self.assertNotIn('ReferenceError', output, output)
            self.assertNotIn('TypeError', output, output)


if __name__ == '__main__':
    unittest.main()
