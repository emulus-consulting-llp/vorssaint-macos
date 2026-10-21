// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

#if VORSSAINT_DEVELOPMENT
// Diagnostics must run before defaults, device services or recovery hooks.
if CommandLine.arguments.contains(TeamsRecordingTrial.flag) {
    MainActor.assumeIsolated { TeamsRecordingTrial.runAndExit() }
}
if CommandLine.arguments.contains(TeamsAXDiagnostic.flag)
    || CommandLine.arguments.contains(TeamsAXDiagnostic.analyzeFlag) {
    TeamsAXDiagnostic.runAndExit()
}
#endif

SuperKeyMappingGuard.runIfRequestedAndExit()
Defaults.register()
NotchControlItem.keyboardLightIsSupported = { BrightnessService.keyboardLightIsSupported }
MouseAccelerationGuard.runIfRequestedAndExit()
MouseAccelerationService.recoverPendingAtLaunch()

if CommandLine.arguments.contains("--selftest") {
    SelfTest.runAndExit()
}
if CommandLine.arguments.contains("--sensors") {
    SensorDump.runAndExit()
}
if CommandLine.arguments.contains("--uninstall") {
    Uninstaller.runAndExit()
}

#if VORSSAINT_DEVELOPMENT
// A probe mode on its own would otherwise launch the whole app, and TCC kills
// that from a shell whose host app lacks a Bluetooth usage description. The
// commands above come first, so `--selftest` beside a probe mode runs the
// selftest, not the probe.
if NotchPresentationProbe.isRequested(by: CommandLine.arguments) {
    NotchPresentationProbe.runAndExit()
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
