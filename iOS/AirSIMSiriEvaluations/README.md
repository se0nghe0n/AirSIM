# AirSIM Siri evaluations

These tests use Apple's SiriEvaluations framework to check how Siri routes spoken requests to AirSIM's App Intents. They drive the real Siri on a physical iPhone and grade which intent Siri calls and with which parameters. They cannot run on a simulator, and the `AirSIM` scheme's simulator suite does not include them.

The target is `AirSIMSiriEvaluations`, its scheme has the same name, and its bundle identifier is `com.se0nghe0n.airsim.q25.sirievaluations`. Its deployment target is iOS 27.3 because SiriEvaluations requires it. The app keeps its own deployment target.

## Scenarios

| Test | Utterance | Expected call |
| --- | --- | --- |
| `draftsMessage` | "Text Alex running late with AirSIM" | `DraftAirSIMMessageIntent`, a recipient, text "running late". Never `StartAirSIMCallIntent`. |
| `draftsMessage` | "In AirSIM, draft an SMS to Alex that says running late" | Same as above. |
| `opensTab` | "Open Recents in AirSIM" | `OpenAirSIMTabIntent`, tab `recents`. |
| `opensTab` | "Show AirSIM Settings" | `OpenAirSIMTabIntent`, tab `settings`. Never `SetAirSIMConnectionModeIntent`. |
| `setsConnectionMode` | "Set AirSIM's connection mode to Cloud" | `SetAirSIMConnectionModeIntent`, mode `cloud`. |
| `setsConnectionMode` | "Switch AirSIM's connection mode back to Automatic" | `SetAirSIMConnectionModeIntent`, mode `automatic`. |
| `callsAndControlsCall` | Turn 1: "Call Alex using AirSIM" | `StartAirSIMCallIntent`, a destination, mode `audio`. Never `DraftAirSIMMessageIntent`. |
| | Turn 2: "Mute the AirSIM call" | `SetAirSIMMuteIntent`, muted on. Never End or Decline. |
| | Turn 3: "On the AirSIM call, press 1 2 3 4 pound" | `SendAirSIMCallDigitsIntent`, digits `1234#` (spaces allowed). Never End or Decline. |
| | Turn 4: "Hang up the AirSIM call" | `EndCurrentAirSIMCallIntent`. |
| `answersIncomingCall` | "Answer the AirSIM call" | `AnswerCurrentAirSIMCallIntent`. Never Decline or End. |

The suite does not check which contact Siri picked for a call or an SMS. SiriEvaluations can only check that a destination or recipient was filled in.

## Before the first run

1. Use a physical iPhone on iOS 27.3 or later, with Developer Mode on, connected to Xcode and prepared for development.
2. Turn on Siri and Apple Intelligence, and wait until the models finish downloading (Settings, Siri).
3. Build and run the `AirSIM` scheme on the device. Launch AirSIM at least once after installing it, so iOS registers its App Intents. Reinstalling resets this.
4. Pair AirSIM with the Android phone, and make sure it can reach the phone.
5. Add a contact named **Alex** with a phone number you control, such as your own second phone or a voicemail line. `callsAndControlsCall` places a real carrier call to that number from the Android phone's SIM and sends the keypad tones 1234#. The draft tests only fill in AirSIM's SMS composer and never send.
6. Keep the device unlocked and untouched during a run. Enter the device passcode when it asks to turn on Automation Mode. Each turn can take up to a minute.

## Per-test setup

- `setsConnectionMode` changes AirSIM's saved connection mode. It sets Cloud, then Automatic, which is AirSIM's default. If you normally use VoWLAN, switch back in AirSIM's Settings afterward.
- `callsAndControlsCall` needs no call in progress. Its first turn places the call, and its last turn hangs up. If a turn fails, end the call by hand before the next run.
- If Siri asks to confirm the call before dialing, turn 1 does not count, and turns 2 to 4 run with no call. A "Yes" turn would then be added after turn 1. That is a change for after the first run.
- `answersIncomingCall` needs an incoming AirSIM call ringing when the test starts. Call the Android phone's number from another phone, wait until AirSIM rings, then start the test. Nothing in the app can create a ringing call.

## Running

Run one test at a time. The suite is `.serialized`, and Siri handles one conversation at a time. In Xcode, select the `AirSIMSiriEvaluations` scheme and the iPhone, open the Test navigator, and click the run button next to a single test. From the command line:

```sh
xcodebuild test -project iOS/AirSIM.xcodeproj -scheme AirSIMSiriEvaluations \
  -destination 'platform=iOS,id=<device UDID>' \
  -only-testing:AirSIMSiriEvaluations/AirSIMSiriEvaluationTests/opensTab()
```

If a test fails before any scenario is graded, or every scenario fails the same way, the environment is the problem. Check the list above, then rerun. Do not change the scenarios for it.

## Reading the report

In Xcode, open the Report navigator (Command-9), select the test run, then select the evaluation. Each scenario row shows its turns, every expectation, and Siri's reply. Read the per-scenario checks, because the test's own pass or fail is only the summary.

From a result bundle, export the evaluation results:

```sh
xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path <directory>
```

Each evaluation becomes one `.xcevalresult` JSON file.
