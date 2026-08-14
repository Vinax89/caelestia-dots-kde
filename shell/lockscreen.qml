pragma ComponentBehavior: Bound

import "modules/lock"
import QtQml
import Quickshell
import Caelestia.Config

ShellRoot {
    readonly property bool _appIdentifiersSet: (function() {
        Qt.application.organization = "Caelestia";
        Qt.application.domain = "caelestia.dots";
        Qt.application.name = "caelestia-lockscreen";
        return true;
    })()

    // Force application identifiers to be set before imported singletons and
    // child components initialize any QtCore.Settings backends.
    settings.watchFiles: _appIdentifiersSet && false

    Variants {
        model: Quickshell.screens
        
        LockBackgroundWindow {
            required property var modelData

            screen: modelData
        }
    }
}
