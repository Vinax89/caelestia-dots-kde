pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property alias running: props.running
    readonly property alias paused: props.paused
    readonly property alias elapsed: props.elapsed
    property bool needsStart
    property list<string> startArgs
    property bool needsStop
    property bool needsPause

    // gpu-screen-recorder (via `caelestia record`) links against an OpenCV
    // SONAME the distro may not ship. Older installs papered over that by
    // symlinking libopencv_*.so.413 next to the real libraries in /usr/lib,
    // which lies to the dynamic linker for every process on the machine.
    // 08-build-shell.sh now puts those compat links in a private directory
    // instead, and this is what actually scopes them to the recorder.
    readonly property string compatLibDir: Quickshell.env("CAELESTIA_COMPAT_LIB_DIR")
        || (Quickshell.env("HOME") + "/.local/lib/caelestia/compat")

    // ["caelestia", "record", ...] with the compat directory prepended to
    // LD_LIBRARY_PATH, which child processes inherit.
    function recordCommand(extraArgs = []): list<string> {
        const existing = Quickshell.env("LD_LIBRARY_PATH") || "";
        const libPath = existing ? root.compatLibDir + ":" + existing : root.compatLibDir;
        return ["env", "LD_LIBRARY_PATH=" + libPath, "caelestia", "record"].concat(extraArgs);
    }

    function start(extraArgs = []): void {
        needsStart = true;
        startArgs = extraArgs;
        checkProc.running = true;
    }

    function stop(): void {
        needsStop = true;
        checkProc.running = true;
    }

    function togglePause(): void {
        needsPause = true;
        checkProc.running = true;
    }

    function launchSpectacle(): void {
        Quickshell.execDetached(["spectacle", "-R", "r"]);
    }

    Component.onCompleted: checkProc.running = true

    PersistentProperties {
        id: props

        property bool running: false
        property bool paused: false
        property real elapsed: 0 // Might get too large for int

        reloadableId: "recorder"
    }

    property bool _wasRunning: false

    Process {
        id: checkProc

        command: ["pidof", "gpu-screen-recorder"]
        onExited: code => { // qmllint disable signal-handler-parameters
            let isRunning = (code === 0);

            if (isRunning && !root._wasRunning) {
                props.elapsed = 0;
                props.paused = false;
            }

            root._wasRunning = isRunning;
            props.running = isRunning;

            if (isRunning && !exitWatcher.running)
                exitWatcher.running = true;

            if (isRunning) {
                if (root.needsStop) {
                    Quickshell.execDetached(root.recordCommand());
                    confirmTimer.restart();
                } else if (root.needsPause) {
                    Quickshell.execDetached(root.recordCommand(["-p"]));
                    props.paused = !props.paused;
                }
            } else if (root.needsStart) {
                Quickshell.execDetached(root.recordCommand(root.startArgs));
                confirmTimer.restart();
            }

            root.needsStart = false;
            root.needsStop = false;
            root.needsPause = false;
        }
    }

    Process {
        id: exitWatcher

        command: ["pidwait", "-e", "gpu-screen-recorder"]
        onExited: {
            props.running = false;
            props.paused = false;
            root._wasRunning = false;
        }
    }

    Timer {
        id: confirmTimer

        interval: 350
        repeat: false
        onTriggered: checkProc.running = true
    }

    Connections {
        enabled: props.running && !props.paused

        function onSecondsChanged(): void {
            props.elapsed++;
        }

        target: Time // qmllint disable incompatible-type
    }
}
