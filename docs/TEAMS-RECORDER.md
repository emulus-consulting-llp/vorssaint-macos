# Teams audio recorder: implementation and evidence

The recorder is available inside Vorssaint at **Settings → Screen Capture →
Recording → Teams Meeting Recorder**. Enable **Detect Teams meetings** to arm
it; it prompts before each call and records only after Start. Monitoring is off
by default. Microphone capture remains an explicit per-call choice, off by
default. The default destination is `~/Documents/Vorssaint Meetings`; choose a
different folder in Settings if needed.

The app saves separate audio sources, mixed playback and readable Teams captions.
Optional local whisper.cpp ASR and conservative caption-text name matching run
after audio finalizes. Settings shows progress, cancellation, saved-folder links,
and **Export Saved Captions…** / **Transcribe Saved Meeting…** for existing folders.
Settings also offers **Stop and Save** during capture; turn off **Detect Teams
meetings** to stop monitoring. The integrated recorder adds no menu-bar item.
Quitting Vorssaint finalizes capture, cancels pending inference, and restores the
readable prior Teams accessibility flags before termination.

The developer trial uses the same recording service. Local recognition is
verified on saved two-source recordings. Remote voice diarization and action-item
generation are still pending. The new native Settings workflow requires a live
call check after installing the rebuilt app.

## Open test: minimized Teams window

- [ ] Verify capture while Teams is minimized. Process-level app audio is expected
  to continue, but this has not been demonstrated in a live minimized call.
- [ ] Verify that mute controls and captions remain accessible while minimized.
  Unknown mute state excludes microphone audio; missing captions can leave remote
  speech unnamed. An unavailable AX observation must not imply the call ended.
- [ ] Record remote/local speech with captions on, minimize, toggle mute and speak,
  restore, then hang up. Inspect source continuity, excluded mic intervals and
  recovery, caption gaps, transcript timing/name fallback and finalization.
- [ ] Separately test initial call detection when the call window is already
  minimized, and automatic post-call transcription in the rebuilt trial UI.

Do not promise complete two-sided recording while minimized until these checks
have live evidence. Keep this open independently of the passing synthetic tests.

## Run the recording trial

After building the Developer executable, run from the repository in Terminal:

```sh
./build/VorssaintDeveloper --teams-record-trial /private/tmp
```

The argument must be an existing output folder. Substitute a preferred absolute
folder path when desired. The command starts its own small menu-bar app before
the utility's other services. It watches Teams only while this trial is running.
An identified call opens a Start/Skip window. No audio is captured before Start.
Use **Teams ● → Stop and Save** to finish; **Stop Meeting Detection** and
Terminal Ctrl-C also finalize capture and restore readable prior AX flags.

The microphone checkbox defaults off. When enabled, it records the Mac's default
input, which may differ from the microphone selected inside Teams. It retains
audio in bounded memory until unmuted observations bracket it. Unknown/muted
intervals, startup/tail audio without a confirming observation and the scans
themselves are discarded from the archive. Quick changes between polls can still
be missed. Live gate results are documented below; this mode does not guarantee
exclusion of private room speech. Headphones reduce remote sound bleeding into the microphone.

Each Start creates an exclusive owner-only subfolder named with date, sanitized
title and a random suffix. It contains:

- `sources.mov`: audio-only uncompressed PCM master (48 kHz, 16-bit stereo), with identifiable Teams and
  optional microphone tracks on a shared host clock; no dummy video.
- `recording.m4a`: mixed playback with headroom for overlapping speech, or
  `recording.wav` if compact export is unavailable. A failed export retains the
  source master and marks the manifest incomplete. Partial exports may remain.
- `observations.jsonl`: locally observed caption/roster revisions and microphone
  states with scan times. Unchanged text is not repeatedly written. These are
  observation times, not finalized speech timestamps or a transcript.
- `captions.md` and `captions.json`: readable Teams captions and structured rows,
  independent of ASR. Repeated visible rows and identifiable consecutive revisions
  are combined; later repeated speech is preserved. Timestamps mean first observed
  on screen, not exact speech times. These exports may include gaps or remaining
  revisions and are not claimed to be Teams' official transcript.
- `manifest.json`: state, requested sources, audio verification, buffer counts,
  warnings and processing status. Transcription has an independent processing
  state; action items remain not implemented.

## Local transcription setup and retries

Run this from the repository in Terminal after approving installation:

```sh
/bin/zsh Tools/setup-teams-transcription.sh
```

The script installs the [Homebrew whisper.cpp formula](https://formulae.brew.sh/formula/whisper.cpp)
when `whisper-cli` is absent, then downloads the upstream multilingual
[`ggml-small.bin`](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-small.bin)
model (about 488 MB). It verifies SHA-256
`1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`
before publishing into
`~/Library/Application Support/com.vorssaint.utils/MeetingModels/`.
An existing model is verified and never replaced. Setup accesses public package
and model servers; transcription itself runs locally without uploading audio.

When the engine and model are present, the trial offers **Transcribe locally
after saving audio**, enabled by default. Audio finalizes first; the menu then
shows local processing. The trial watches for the next call after processing
finishes. Quitting cancels inference and preserves saved audio for retry.
Restart the trial to load a rebuilt executable.

An already finalized recording can be processed without another Teams call:

```sh
./build/VorssaintDeveloper --teams-transcribe /absolute/recording-folder
```

For captions alone, with no model or audio recognition required:

```sh
./build/VorssaintDeveloper --teams-export-captions /absolute/recording-folder
```

Exports preserve existing files. Move a user-edited export aside explicitly if
you want to regenerate it. Local transcription requests sentence JSON (`-oj`),
avoiding full token diagnostics that can contain split UTF-8 bytes in multilingual
speech. The decoder also accepts legacy full output when only unused diagnostics
contain malformed bytes. Malformed sentence characters are replaced with `�`
and the affected turns are marked `[text encoding repaired]` for review against
the captions or audio. Invalid JSON structure still fails explicitly.
Transcription errors are recorded in the manifest and never erase saved audio
or caption exports.

Retries can reuse completed chunk results from a failed attempt when the PCM
input matches byte for byte, model path/language/translation settings match,
and the model and engine have not changed since the result was written. Temporary
WAV inputs are retained until the whole transcript publishes, allowing a later
decoder fix or interrupted run to recover prior work. Audio from another chunk
or recording is never accepted merely because its filename matches.

The service automatically retries on CPU after a recognized Metal buffer
allocation failure and uses CPU for the remaining chunks. Other engine errors
and timeouts remain explicit failures. The transcript discloses a fallback;
the manifest records the selected backend. Bounded failure diagnostics can
contain speech and are retained only inside the private attempt folder.
The engine's `-np` flag is deliberately omitted: on 1.9.5 it suppresses the
allocation failure reason as well as routine diagnostics. Engine output is
captured/drained privately, with at most 128 KiB retained; it is never forwarded
to the console.

Add `--cpu` to disable GPU inference, or `--language en` to select a language
instead of automatic detection. Custom engines/models can be supplied together
with `--whisper-cli /absolute/whisper-cli --model /absolute/model.bin`.
These arguments follow the [upstream CLI](https://github.com/ggml-org/whisper.cpp/tree/master/examples/cli).
Only progress and counts appear on the console. Meeting text stays in local
files. The command requires a completed source master; it does not re-record
audio, contact Teams or request Accessibility permission.

Source metadata identifies the microphone as **You** and app audio as **Remote**.
Each source is resampled to 16 kHz mono using a low-pass filter, in bounded
ten-minute chunks retaining the common recording origin and excluded mic gaps.
All-silent chunks are skipped. Chunk edges may truncate a word. A six-hour limit
bounds preparation; inference has a per-chunk timeout and cancellation support.
There is no remote-speaker diarizer in this version. Caption text can supply a
display name only for a nearby, substantial and unambiguous textual match; the
Markdown marks these labels with †. A roster or window title never supplies an
unevidenced identity. Recognized words and speaker labels still need review.

A successful run publishes `transcript.md` exclusively with mode 0600. Existing
transcripts are preserved; move one aside intentionally before a retry. Private
`transcription-<UUID>/` directories retain engine JSON, timestamped `turns.json`
and the generated draft for inspection. Prepared WAVs are removed after each
successful chunk; a failed/cancelled attempt can retain private intermediate
audio. A lock prevents simultaneous jobs for the same recording. The manifest
records processing/complete/failed/cancelled independently of audio completion.
No `action-items.md` is generated yet.

Validation: **179 targeted checks pass**, including 30 transcription checks for
milliseconds/chunk offsets, silence filtering, attribution ambiguity/time bounds,
escaping, anti-aliasing, delayed/gapped mic audio, actual PCM preparation,
subprocess execution with paths containing spaces, preserving existing outputs,
failure/retry state, cancellation, concurrent-job rejection, recognized GPU
allocation failure and automatic CPU retry. The subprocess
fixture emits synthetic text; it does not establish ASR quality. The developer
executable compiles without Swift warnings. Bundle staging retains the existing
permission failure; no installed app was updated. App-wide selftest retains the
previously observed swap-memory/uptime failures and hardware-service warnings.

Installation initially failed tool-session sandbox extraction/network access,
then hit an OpenSSL directory collision in the user's Terminal. After the
dependency repair, the user successfully installed whisper.cpp 1.9.5 and the
487,601,967-byte model; a local checksum check matches the expected SHA-256.
No manual dependency deletion or forced linking was performed by this agent.

The real engine initially aborted on Metal buffer allocation (also on an
escalated retry). An explicit CPU run successfully processed the saved 117.59 s
test recording: eight remote segments and three microphone segments were retained,
four remote segments received caption-text-matched display names, and four stayed
Remote. The microphone decoder emitted one additional segment entirely outside
audible ranges, which was excluded. Timestamps are finite, chronological and
within the recording duration. Both source languages were detected as English.
The 1,188-byte transcript and updated manifest have mode 0600; engine JSON and
timestamped turns remain in the private attempt folder. No meeting text or
identities were copied into this document or printed during verification.

Seven of eight remote segments have at least 85% word overlap with a nearby
caption row (median best overlap 97.4%). This is a check against another ASR
system, not a human accuracy score or proof of speaker identity. The actual
transcript needs user review. Automatic post-call UI transcription still needs
a test after restarting the rebuilt trial; offline recognition does not establish
that UI lifecycle.

The rebuilt default command was also run on the earlier 67.35 s two-source
recording. It automatically recognized the Metal allocation failure, retried on
CPU, continued the second source on CPU and published seven segments. Its
manifest reports audio `complete`, transcription `complete` and backend
`cpuFallback`. That earlier call had no saved caption rows, so no remote names
were assigned. This verifies the fallback with the actual engine and recorded
audio, in addition to the synthetic subprocess tests.

Source capture uses Vorssaint's existing app-specific CoreAudio process tap
(macOS 14.4+) and microphone collector. It does not capture video or operate Teams
screen-sharing controls. Concurrent sharing, device changes and echo still need
a live test. Silent tap buffers do not prove permission was granted: the menu and
manifest distinguish actual non-silent remote audio from an unverified source.

The trial scans at most once per second with no overlapping scans and a 1.5 s
AX budget. It activates enhanced accessibility once per Teams process and bounds
window count, tree size/depth and microphone/audio backlog. This trial polling
is not the final low-wakeup production detector. Only two successful no-window
or not-running observations at least two seconds apart auto-stop capture. A Teams
main window left open after hang-up can leave state unknown; use Stop and Save.
AX errors or missing controls do not infer hang-up. Multiple detected call windows
remain unknown. Source PCM uses roughly 0.69 GB/hour per stereo track, and WAV
playback uses a similar amount; standard WAV fallback is bounded to its ~4 GB
format limit. Compact export and source retention need product settings later.

For a live check, use a non-sensitive short call: record remote speech, optionally
enable the microphone and speak while unmuted/muted, stop from the menu, and play
the mixed file. Check both voices and muted intervals. Then test hang-up with
Teams windows both closed and left open. Do not use a real meeting as the first
recording test. Basic capture UI, permissions and both sources have live evidence
below; concurrent sharing and the other listed hardware states remain unverified.

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
2. **Detection and audio capture (developer trial implemented):** live-test the
   prompt, per-app tap, microphone filtering, output, call end and failure paths;
   then register the opt-in production feature, settings and permissions. Add
   process/window event wakeups and recovery UI before treating it as finished.
3. **Captions and transcription:** validate collected revisions; integrate a selected
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
still fails swap-memory and uptime checks as above. This validation predates the
audio trial described at the start of this document.

### Follow-up: after hang-up and lifecycle policy

The after-call report had Accessibility trust, Teams still running, a successful
`windowsListed` result and zero windows. This is explicit absence evidence for
that run. It does not establish that all Teams call endings close every window.
The reader now treats an unsupported root windows attribute as an error, rather
than silently converting it into an empty list.

The pure recording lifecycle offers once per call, suppresses a dismissed or
manually stopped call, and requires two successful absence checks at least two
seconds apart before automatic stop. Observation failure breaks that debounce;
it never means hang-up. Stale prompts cannot start capture, and late startup
completion cannot undo a stop. A different verified call cannot inherit capture.

The microphone policy authorizes only audio bracketed by two timely unmuted
observations. Unknown, muted and slow observations discard their interval. This
is best-effort filtering: a mute/unmute between polls is undetectable, and audio
during the AX scans themselves is excluded. It is not a privacy guarantee.
`./build.sh --test-suite=teams-accessibility` passes 68 checks including the new
lifecycle, observation-loss, startup-cancellation and microphone-gate cases.

### Developer audio trial validation

- `./build.sh --test-suite=teams-audio --test-suite=teams-accessibility`: **108
  checks pass** (40 audio, 68 AX/lifecycle). Audio checks generate synthetic tones
  and round-trip through the actual PCM master and WAV exporter. They verify
  delayed microphone onset, both source frequencies, silence in microphone gaps,
  float/planar format changes, 44.1 kHz mono input, an unused mic track, remote-only
  capture, duration, empty recording failure and refusing an existing export.
- PCM inputs concatenate data across internal timestamp holes, so the writer now
  fills those holes with zeros before later microphone speech. The WAV fallback
  applies source edit mappings and reads/mixes bounded blocks. It does not need
  an AudioUnit mixer or AAC encoder. Device normalization uses AVAudioConverter.
- AAC encoder creation and AVFoundation's audio mixing reader failed here, also
  on escalated retries. WAV round trips pass; compact M4A export remains unverified
  in this environment. Source PCM remains available if playback export fails.
- The Developer executable compiles, including the isolated menu-bar UI and
  asynchronous preparation. Full bundle staging still fails replacing the
  existing `build/stage.noindex` directories with `Operation not permitted`.
  No installed app was updated. The trial runs from the compiled executable.
- Invalid trial arguments and a missing output directory are rejected before
  monitoring or capture. App-wide selftest still reports the unrelated swap
  memory and uptime failures documented above.
- Live UI, microphone/TCC, app-audio routing, concurrent screen sharing, hardware
  changes, call detection and post-call outputs still need the Terminal-launched
  trial on the user's Mac. Synthetic tests do not establish those behaviors.

### First live audio trial

The Terminal-launched trial detected the call, requested capture permission,
recorded non-silent Teams audio, automatically finalized after call end and
successfully exported an AAC M4A on the user's Mac. `afinfo` reports 104.62 s,
48 kHz stereo and one playback track. The source archive, local observations and
manifest were present. Meeting content and identifiers remain outside Git.

The run is incomplete as a two-sided recorder: microphone was requested but all
9,741 mic buffers were discarded. The user confirms speaking while unmuted.
There were 13 unmuted, 88 muted and 4 unknown observations, including 11 intervals
that qualified for the mic gate; AX scans took at most 93 ms. No caption rows or
roster entries were observed. Remote capture reported zero dropped audio buffers.
The original mic cannot be recovered because it was discarded before archiving.

The filter now has real CMSampleBuffer tests in addition to the pure AX policy.
A reproduced rejection case is PCM with an invalid reported duration but valid
frame count and sample rate. That duration is now derived from frames/rate; byte
accounting uses the backing data buffer when sample-size metadata is absent.
Mute/unknown evidence still prevents release. New manifests include categorized
discard counters, inferred metadata counts and numeric arrival-delay bounds to
distinguish timing/clock problems from mute exclusion without saving raw speech.
The saved first-trial report lacks these diagnostics, so the exact live cause and
the fix still require a short repeat recording; this is not a confirmed live fix.

After this change, the targeted suites pass **122 checks** (68 AX/lifecycle and
54 audio/filter). The new tests include missing-duration PCM release, integration
with the actual writer, muted/unknown rejection, pending future audio, unconfirmed
tail rejection, bounded backlog and arrival-delay diagnostics. The executable
compiles; bundle staging retains the same permission failure.

### Repeat live trial: microphone captured

The next recording finalized automatically with manifest state `complete`, no
warnings, zero dropped audio buffers and a valid 67.35 s stereo AAC playback file.
It wrote 6,302 Teams buffers and 2,079 microphone buffers. All 6,267 received mic
buffers needed backing-buffer byte accounting (`inferredByteCounts`); none needed
duration inference. This confirms the zero sample-size metadata case on the real
microphone path. Numeric arrival delays were 11.7–15.8 ms, so this run shows no
clock-epoch mismatch. The filter excluded 4,188 buffers around muted, unknown and
unconfirmed intervals. These counts are not proof of a general privacy guarantee.

A local read-only PCM review found two independently tagged source tracks, both
with nonzero audio. The microphone track had approximately 1.064 million nonzero
frames. No microphone sample data overlapped the 36 intervals bracketed by two
confirmed muted observations. Absent source intervals play as silence. This
verifies the recorded sources in this test, not the content of speech or mute
changes that could occur between AX polls. Only numeric audio statistics were
printed; no transcription or external processing was performed.

Caption capture remains unresolved: the user confirms captions were visible,
but none of the saved observations recognized the expected caption panel. A new
focused live AX diagnostic is required before changing those selectors. No
meeting text or identities are copied into this evidence log.

### Caption toolbar compatibility fix

The follow-up with visible captions exposed a second toolbar layout on the same
Teams version. The older compact layout has a direct
`closed-captions-overflow-menu-button` sibling of the dismiss button. The newer
non-overflow layout instead has
`captions-settings-menu-trigger-button-non-overflow` inside a child group, plus
`closed-captions-pop-out-button` in a separate child group. The dismiss button
remains a direct child of their common controls group. Speaker and utterance
values remain paired static text under the caption content branch.

The parser now accepts either observed layout and requires a unique known
settings anchor, the dismiss button, and the matching parent structure. The wide
layout also requires the observed pop-out control. Duplicate/conflicting anchors,
misplaced controls or AX errors remain unknown. Tests use synthetic names/text.

The updated executable was run offline against the local real reports:

| Snapshot | Caption rows read |
| --- | ---: |
| New visible non-overflow layout | 17 |
| Earlier compact layout | 19 |
| Earlier unmuted/roster layout | 18 |
| Follow-up taken before the caption panel appeared | 0 |

The visible-caption report is partial only because of the inspector's depth
limit; intact rows can still be read. **129 targeted checks pass** (75 AX/lifecycle,
54 audio/filter). The executable compiles; bundle staging and app-wide selftest
retain the previously documented environment failures. A running trial must be
quit and relaunched to use this parser fix. Reading a saved snapshot verifies
selectors but does not establish complete continuous caption capture or ASR.

Desktop UI reading became available during this test and confirmed caption text
was visible. The desktop tool disallows Terminal automation, so the focused dump
was launched by the user. No additional UI controls were pressed by the agent.

### Continuous captions verified; queued audio writing

The next restarted trial saved a 142.37 s M4A, both audio sources, and 108 changed
observations containing caption rows with two distinct display labels. The caption
panel was recognized in 110 saved observations. Labels identify Teams accounts,
not independently verified human voices. This confirms continuous caption
collection with the new toolbar selector, not a finalized/complete transcript.

The manifest also exposed 256 dropped mic buffers: 2,886 passed the filter but
only 2,630 reached the writer. The 13,336 remote buffers were saved. A read-only
PCM review confirmed nonzero audio in both tracks and zero nonzero mic frames
across 4,266,524 frames inside 98 brackets of confirmed muted observations.

Previously the sink appended a released mic batch directly and dropped samples
whenever AVAssetWriterInput was temporarily not ready. The sink now retains
approved samples in an 8 MB / 2,048-buffer queue, retries each source independently
and drains it before finalization. A long silence fill yields to the other source.
Retries do not consume/convert the real sample or count as drops. Queue overflow,
encoder failure and a 10 s final flush timeout stop with an explicit warning;
there is no unbounded backlog or endless save loop. Unapproved mic buffers never
enter this queue. The manifest includes retry and peak-backlog statistics.

Tests cover ordered retry of released mic bursts, other-source progress, buffer
and byte limits, preserving admitted data on overflow, writer failure, bounded
flush timeout, and a burst through the actual PCM writer/exporter. The already
saved recording's dropped mic buffers cannot be recovered. This queue change
needs to be loaded by restarting the trial; it is not a verified live fix yet.

After the queue change, **149 targeted checks pass** (75 AX/lifecycle and 74
audio/filter/queue), without compiler warnings. The actual burst test writes all
200 Teams buffers and all 90 mic buffers, fills a microphone gap, exports playback
and preserves its two-second duration with zero writer drops. The Developer
executable compiles; bundle staging still has the documented permission failure.

### Queue fix verified in the next live trial

The restarted trial finalized a 117.59 s M4A with state `complete`, no warnings,
11,010 Teams buffers, all 1,537 released microphone buffers and **zero dropped
audio buffers**. It retried the writer 28 times; the backlog peaked at 89 buffers
and 182,272 bytes, far below the configured bounds. This verifies the queue
handled actual writer backpressure in this run.

The recording also saved 46 changed observations containing caption rows with
two display labels. A local numeric PCM review confirmed nonzero audio in both
tracks, with zero nonzero microphone frames across 4,040,829 frames inside 91
brackets of confirmed muted observations. Automatic finalization, both audio
sources, caption collection and queued writes now have positive live evidence.
This does not establish coverage of every hardware/Teams state, complete
transcription, or exclusion of quick mute changes between polls.

No `whisper-cli`, `whisper-cpp`, `whisper` or `ollama` executable was available on
the session PATH. Installing a local ASR engine/model is the next dependency;
the workspace's DEV-mode agent-guard rule requires explicit approval before
internet access or package installation. No meeting data has been sent externally.
