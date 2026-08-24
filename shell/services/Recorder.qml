pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.utils

Singleton {
    id: root

    readonly property string recordBin: Paths.absolutePath("~/.local/bin/caelestia-record")

    readonly property alias running: props.running
    readonly property alias paused: props.paused
    readonly property alias elapsed: props.elapsed
    property bool needsStart
    property list<string> startArgs
    property bool needsStop
    property bool needsPause

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

    function refresh(): void {
        if (!checkProc.running)
            checkProc.running = true;
    }

    function launchSpectacle(): void {
        Quickshell.execDetached(["spectacle", "-R", "r"]);
    }

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

        command: ["sh", "-c", "pidof gpu-screen-recorder >/dev/null && f=\"$(cat $HOME/.local/state/caelestia/record/current_recording_path 2>/dev/null)\" && [ -n \"$f\" ] && test -f \"$f\""]
        onExited: code => { // qmllint disable signal-handler-parameters
            let isRunning = (code === 0);

            if (isRunning && !root._wasRunning) {
                props.elapsed = 0;
                props.paused = false;
            }

            root._wasRunning = isRunning;
            props.running = isRunning;

            if (isRunning) {
                if (root.needsStop) {
                    Quickshell.execDetached([root.recordBin, "--stop"]);
                } else if (root.needsPause) {
                    Quickshell.execDetached([root.recordBin, "--pause"]);
                    props.paused = !props.paused;
                }
            } else if (root.needsStart) {
                Quickshell.execDetached([root.recordBin, ...root.startArgs]);
            }

            root.needsStart = false;
            root.needsStop = false;
            root.needsPause = false;
        }
    }

    // caelestia-record writes the in-progress recording's path here, so a
    // recording started or stopped outside the shell shows up as a change to
    // this file. Reacting to it is what lets the poll below be slow.
    FileView {
        path: `${Paths.state}/record/current_recording_path`
        watchChanges: true
        printErrors: false

        onFileChanged: root.refresh()
        onLoadFailed: root.refresh()
    }

    // Backstop poll.
    //
    // This used to be a flat 500 ms, repeat, running: true -- an `sh -c` plus a
    // `pidof` (plus a subshell and a `cat` on the hot path) twice a second for
    // the entire life of the shell, roughly 170k process spawns a day, to answer
    // a question whose answer is almost always "no".
    //
    // start()/stop()/togglePause() already poke checkProc directly, and the
    // watcher above covers external changes, so this only has to catch what
    // neither notices: a recorder that died without updating its state file
    // (checked every 2 s while a recording is believed active) and a recording
    // started before the watcher had a file to watch (every 10 s when idle).
    Timer {
        interval: props.running ? 2000 : 10000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Connections {
        enabled: props.running && !props.paused

        function onSecondsChanged(): void {
            props.elapsed++;
        }

        target: Time // qmllint disable incompatible-type
    }
}
