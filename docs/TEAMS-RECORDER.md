# Teams audio recorder: implementation and evidence

The first milestone is a developer-only AX inspector. Call detection, media
capture, captions, ASR, speaker attribution, and action-item generation are not
enabled yet. Their selectors depend on live evidence from this Teams version.

## Run the inspector

Build with `./build.sh --dev`. The diagnostic exits before normal app startup,
defaults migrations, device services, or background monitoring. Use a short
non-sensitive test call. Turn on captions manually, then open People for a
separate snapshot. Nothing in this diagnostic records audio or presses controls.

List window metadata first (no descendant text):

```sh
./build/VorssaintDeveloper --teams-ax-dump /private/tmp/teams-windows.json --request-accessibility
```

If Accessibility is denied, grant the launching app access in System Settings
and retry using a new output filename. The CLI's TCC identity can be its launching
terminal rather than the installed app. macOS must grant this access; the tool
cannot grant it itself.

Read the local report, identify the test-call window index, and dump only that
window. For example, if it is index 1:

```sh
./build/VorssaintDeveloper --teams-ax-dump /private/tmp/teams-call.json --window-index 1
```

Window indices can change between runs. Check the selected window metadata in
each report. Reports contain meeting text and names: keep them outside Git, and
do not upload real call contents. Files are created with mode 0600 and never
overwrite an existing path. Only the status and destination are printed.

The tool tries `AXManualAccessibility` and waits 300 ms. If the selected window
still has an unpopulated web area, a separate experimental run can add
`--enhanced-accessibility`. That also tries `AXEnhancedUserInterface`, which can
interact with window managers. Each result and read-back is recorded. Readable
prior flag values are restored; unreadable prior values are not guessed. Even a
restored flag does not guarantee Chromium disables internal accessibility again.

The inspector records roles, subroles, identifiers, titles, descriptions, values,
help, enabled/selected state, DOM identifiers and ARIA live-region attributes
where exposed. It does not assume an AXWebArea exists, or interpret English labels
without matching the observed control identifiers. Paths are local to the snapshot,
not durable caption IDs. Schema 2 reports include a `TeamsCallObservation` with
conservative call/microphone evidence, visible roster entries and caption pairs.

Saved reports can be analyzed without contacting Teams or requesting permissions:

```sh
./build/VorssaintDeveloper --teams-ax-analyze /private/tmp/teams-call.json /private/tmp/teams-analysis.json
```

Offline analysis prints only counts and call/microphone states. Display names and
caption text stay in the owner-only output file. It also supports schema 1 reports.
The parser recognizes the observed English `Mute mic` / `Unmute mic` actions;
unknown languages, conflicting labels, disabled controls or duplicate selectors
remain unknown. It never interprets missing controls as an ended call. Caption
rows must be paired static text inside the panel anchored by its dismiss/overflow
controls. Participant names come from their roster avatar text, not from splitting
the combined name/role/mute description. Visible rosters are not assumed complete.

Traversal is breadth-first, bounded to 25 levels from the window, 1,500 nodes,
256 children per node, 2,048 characters per text field, and five seconds of
traversal. Window enumeration has a separate five-second budget. Each AX request
gets at most 500 ms, limited by its remaining budget. Activation and restoration
have their own bounded calls. Image, scrollbar, menu and secure-field descendants
are skipped. Partial/error reports are evidence of an unavailable observation,
not evidence of call termination. A diagnostic is not a 15 ms production poll.

## Evidence needed before milestone 2

Capture test-call snapshots for: unmuted, muted, captions off/on, People open,
minimized/on another Space, and after hang-up. Record Teams version and UI
language, and distinguish meeting, 1:1 call, ringing, and pre-join lobby.

Verify which attributes distinguish the action "Mute" from the state "muted",
whether captions expose separate speaker/text nodes, whether updates reuse nodes,
and whether roster names are complete or virtualized. Test observation loss and
permission revocation separately from an ended call. A two-poll AX failure must
not finalize a live recording.

## Corrections to the proposed architecture

- Apple documents that AX messaging timeouts apply to the individual element,
  not all its descendants. The inspector sets them per request and bounds the
  total traversal: https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout
- Treat Chromium activation attributes and the underlying Teams web renderer as
  hypotheses to test, not a guaranteed WebView2/Electron contract on macOS.
- Device-wide CoreAudio activity is neither zero-cost nor Teams-specific. It can
  wake a verifier, but cannot establish a Teams call. Prefer process-level audio
  activity where available, with app/window lifecycle signals for muted calls.
- Reuse and evaluate `RecorderSystemAudioTap` before adding another audio path.
  Vorssaint already handles app-specific taps on macOS 14.4+ and documents a
  ScreenCaptureKit/mixer double-audio issue. A 2x2 video configuration does not
  select Teams audio by itself; the content/process filter still matters.
- Keep local and remote source tracks distinct and on a shared monotonic clock.
  A stereo pair and two independently selectable audio tracks are different
  formats. Retain lossless source timing and encode a convenient mixed archive
  separately. Validate Bluetooth/output changes and speaker echo.
- A once-per-second AX mute poll cannot guarantee exclusion of private speech.
  Use explicit known-muted/known-unmuted/unknown states. A future privacy mode
  must gate archive audio as well as ASR, buffer before writing, discard uncertain
  intervals conservatively, and expose its limitation. Logging intervals while
  retaining raw mic audio does not remove private room speech from the archive.
- Captions arrive late, revise, and recycle nodes. Observation time is not speech
  time; caption indices are not stable turn IDs. Preserve raw revisions and
  observation timestamps, then align text to ASR with confidence and unknown
  fallbacks. Polling can miss turns; missing captions must remain identifiable.
- Neither a window title nor a two-person roster proves voice identity with 100%
  reliability. Shared rooms, playback and roster changes break that assumption.
  Roster names may help spell an evidenced name; an LLM must never guess a mapping
  between anonymous speaker clusters and names from a list.
- Preserve unknown speakers and uncertain action owners. Every extracted task
  should cite transcript evidence; distinguish explicit commitments from suggested
  follow-ups. Treat transcript contents as data, never as model instructions.
- Keep transcription and summarization retryable after saving audio. Add local
  processing first. External endpoints require an explicit user choice and must
  respect this workspace's restriction against sending client data externally.

## Remaining milestones

1. **Inspector (implemented; live meeting content observed):** bounded AX snapshots,
   diagnostic CLI, offline semantic analysis and tests. Both microphone states,
   caption pairs and two roster entries verified. Call transitions, timing and
   caption revisions still require validation.
2. **Detection and audio capture:** verify selectors, register opt-in feature and
   permissions, add debounced call state with an unknown state, prompt once per
   call, choose destination, capture sources with safe mute handling and recovery.
3. **Captions and transcription:** test revision collection; integrate a selected
   local ASR/diarization backend and its model installation; align named evidence
   conservatively. FluidAudio is a candidate, not an installed dependency.
4. **Action items:** local model adapter, evidence-linked structured extraction,
   Markdown exports, retry and failure state. No invented owners or commitments.

FluidAudio reference API: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md

Live snapshots demonstrate captions, both microphone action labels and roster
exposure on this Teams build. They do not establish reliable detection, transition timing or caption
collection across builds. Do not invent evidence for unobserved states.

## Validation on 2026-10-21

- `./build.sh --test-suite=teams-accessibility`: passed, 22 behavioral checks.
- `./build.sh --dev`: compiled and assembled the Developer bundle. The local
  signing identity was unavailable; the build fell back to ad-hoc signing. The
  adaptive icon catalog was skipped because `actool` was unavailable.
- `./build/VorssaintDeveloper --teams-ax-dump` without arguments: correctly
  rejected with usage and exit code 2 before reading Teams.
- `./build/VorssaintDeveloper --selftest`: failed swap-memory and uptime checks,
  including on an escalated retry. Also reported unavailable AppleSMC, symbolic
  hotkey table, AirPlay routing, and mounted-volume information. This is an
  unresolved environment/runtime validation gap, not a passing selftest.
- Installed Teams bundle identifier confirmed as `com.microsoft.teams2`.
- Live AX attempt during the user's test meeting returned `accessibilityDenied`.
  Requesting permission did not show a visible prompt. Launch Services rejected
  the staged bundle with `kLSNoExecutableErr` despite its executable being present.
  The computer-use connection was unavailable. Subsequent probes launched by
  the user from Terminal had Accessibility trust and returned window data.

### Live Teams AX observations

Environment: Teams `26261.303.5165.1465`, macOS `27.0.1 (26A434)`, English call
controls. Raw reports stay in `/private/tmp`; meeting titles, participant names
and caption contents are deliberately not copied into the repository.

- `AXManualAccessibility` returned `attributeUnsupported` (-25205). The first
  call-window traversal found only 19 outer-shell nodes, no call controls.
- With `AXEnhancedUserInterface`, the set returned `cannotComplete` (-25208),
  but read-back was **true** and the web area became accessible. The restore
  also returned -25208; the current inspector has no restore read-back, so
  restoration is not verified by this report. Return codes alone are insufficient.
- Enhanced traversal found 216 nodes in approximately 69 ms. Its only incomplete
  reason was `depthLimit`; the AXWebArea began at depth 10. The diagnostic's
  depth-25-from-window limit cut some content below the web area. This is not a
  timeout, and neither a complete semantic observation nor a 15 ms poll.
- Observed `AXDOMIdentifier=horizontalMiddleEnd`, role `AXToolbar`, description
  `Meeting controls`; `horizontalEnd` grouped `Calling controls`.
- `hangup-button`: role `AXButton`, title/description `Leave`, enabled true.
- `microphone-button`: role `AXButton`, title/description `Unmute mic`, enabled
  true, selected false, empty value. The actionable label indicates muted state;
  `AXSelected=false` does not establish that the microphone is unmuted.
- Caption controls: `closed-captions-overflow-menu-button` and
  `captions-panel-dismiss-button` (`Hide live captions`). Nearby caption rows
  exposed sibling `AXStaticText` values for display name and utterance. The test
  sentence was present. Row paths and empty identifiers are not stable turn IDs.
- This snapshot does not verify the opposite mic state, roster extraction,
  caption update events or latency, call ending, localization, or continuous
  monitoring. It also does not establish that caption display names identify
  real-world speakers correctly when a participant plays another audio source.

### Follow-up: microphone and roster parser

The first People-panel snapshot still showed `Unmute mic` and a muted local
roster indicator. The subsequent snapshot showed `Mute mic` and an `Unmuted`
roster indicator. `AXSelected` was false in **both** states and must not be used
as microphone state. Traversal took approximately 119 and 128 ms respectively,
with only depth-limit truncation.

The roster exposes `calling-roster-item-<participant identity>` groups under an
`AXOutline`, anchored in the panel containing `roster-participants-search-input`.
Each item contains `roster-avatar-img-<same identity>` with a static display name,
and `roster-mic-button-<same identity>` with `Muted` / `Unmuted` descriptions.
These are observed identifiers, not a guaranteed API. Names, identity suffixes
and raw fixtures remain outside the repository; tests use invented identities.

The parser was run offline against all four actual call-tree reports:

| Report | Call evidence | Mic | Caption pairs | Visible participants |
| --- | --- | --- | --- | --- |
| Outer shell, manual flag only | unknown | unknown | 0 | 0 |
| Enhanced, captions | present | muted | 19 | 0 |
| Enhanced, People panel | present | muted | 19 | 2 |
| Enhanced, actually unmuted | present | unmuted | 18 | 2 |

Counts describe displayed rows, not finalized turns or total meeting attendance.
The follow-up tests pass **41 checks**, including conflicting/disabled/duplicate
controls, unsupported labels, bounded text, caption panel scoping and numeric row
ordering. Reader-side text truncation is now preserved in snapshot omissions, and
activation restoration now records read-back rather than relying on its error code.
That new restoration read-back still needs a live run; old reports cannot prove it.

The updated Developer executable compiled and successfully analyzed the saved
reports. Bundle packaging failed replacing `build/stage.noindex` with
`Operation not permitted`, including after an escalated retry. It is not an
installed or fully packaged feature. The current executable's app-wide selftest
still fails swap-memory and uptime checks as above. Recording, automatic prompts,
continuous caption collection and ASR/LLM processing are not implemented yet.
