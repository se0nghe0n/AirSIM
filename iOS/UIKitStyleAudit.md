# UIKit migration style inventory

Reference: commit `2ed128b4193cd089ab143f477b37b86b35e1ca7c`; original sources are
`RootView.swift`, `PhoneViews.swift`, `AirSIMSetupView.swift`,
`SamsungPairingView.swift`, `CallRecordingsView.swift`, and `AgentVerboseTraceView.swift`.
Coordinator reference captures were kept locally and are not committed.

The table records the implementation mapping, not a claim of physical-device or
pixel-identical acceptance. The final combined review is recorded below; network and carrier behavior
require a paired physical endpoint.

| Original element | UIKit implementation and retained styling |
| --- | --- |
| Root canvas | `PhoneBackdropView`: white in light mode; original blue-black base and bottom gradient in dark mode. |
| Five tabs | `UITabBarController`, filled system symbols and native selection treatment; iOS 26 scroll minimization. Native iPad tab placement remains system-owned. |
| Dial number / contact | Rounded light 36pt number, one line with shrink-to-fit; green subheadline contact; no navigation bar. |
| Dial keys | 84pt circular target at normal phone size, 28pt horizontal /12pt vertical spacing; native iOS 26 glass, system-fill fallback; 31pt digits and 10pt semibold letters. |
| Dial / delete | Icon-only green call circle and secondary delete glyph; disabled opacity, touch/hold delete, accessible Delete hint, long-zero plus, input-click sound. |
| Current agent card | Device/name/number/current state and both route states; agent list selection retained. |
| Recents | Plain 74pt rows, 50pt avatars, 16pt edge inset, 11pt avatar gap, 76pt time column and 44pt call circle; missed entries red. |
| Recents controls / message | Native refresh/recordings toolbars; bottom material status message; pull-to-refresh and swipe actions. |
| Recent details | Over-full-screen 18% dim, centered max340pt material card, 28pt corner, 58pt avatar, original call/message/delete/cancel actions. |
| Conversation list | Plain rows with original avatar/name/last-message/time hierarchy and disclosure navigation; toolbar menu/compose. |
| Thread | Bottom-aligned multiline blue outgoing and system-gray incoming bubbles,18pt corners,14x9pt padding, Sent caption; reply bar follows keyboard. |
| Composer | Medium/large sheet, Cancel/title/Send toolbar,52pt recipient strip, contact picker and suggestions, bottom rounded editor/36pt send circle/tertiary caption. |
| Contacts | Native search and refresh, plain avatar rows, authorization empty state and action. |
| Contact detail | Centered82pt avatar/name header; deduplicated phone rows with42pt blue message/green call circles. |
| Onboarding | Max600pt centered scroll column,24pt padding,76pt blue symbol tile, large bold heading, rounded24pt steps card, segmented mode choice, bottom material pairing/later actions. |
| Settings | Native inset-grouped form, trailing value labels, menu-style mode and appearance pickers, switch, editable Relay URL, connection/self-test sections and footers. |
| Pairing | Grouped connection steps with system symbols; inline local-only switch and footnote; discovery spinner; code input and pair action per discovered service. |
| Recordings | Grouped background, waveform empty state; separate play, timestamp/duration and share controls; original playback-disabled-during-call behavior and swipe delete. |
| Trace | Grouped settings/filter/status sections; colored category symbol, source and monospaced millisecond timestamp, semibold title/two lines, monospaced detail/three lines; share/copy/clear and detail presentation. |
| Incoming call | Original dark blue/cyan radial canvas,116/132pt avatar,38/44pt name, waiting/connectivity pill, separate76pt red/green circles with captions. |
| Connected call |92/112pt avatar, monospaced duration, audio/route status, recording control,62/68pt secondary circles,76pt end circle with caption. |
| Call keypad | Circular digit targets, entered digits/placeholder, haptic feedback, medium sheet and cancel; TCA owns digits/presentation. |
| Accessibility | Action labels/hints retained, text uses Dynamic Type metrics, touch controls retain minimum native targets; VoiceOver delete activates a single deletion. |

## Architecture and behavior checks

All communication effects route through `AirSIMClient`; reducer state contains
value snapshots and feature state, never AppModel/UIKit references. Lifecycle
preparation remains synchronous infrastructure. Observation uses change tracking,
not polling. Input controls survive row insertion and keep keyboard selection.
SMS effects have operation IDs; dismissing/reopening or changing conversations
invalidates presentation ownership without pretending a network send was undone.

Package and build evidence: exact TCA 1.26.2 plus transitive dependency lock included.
Pre-review native suite: **147 passed, 0 failed, 1 skipped** (148 cases), including
controller Back/replacement and TCA draft/cancellation/navigation checks.
The existing TURN environment-dependent test was skipped. Subsequent changes only
adjusted visual properties; the final Xcode build and `git diff --check` passed.

## Visual evidence boundaries

- Baseline captures inspected: phone dial/light+dark, empty/populated recents,
  empty/populated messages, composer, thread, contacts authorization, settings
  top+bottom+dark, pairing/discovery, empty recordings, incoming/active call fixtures,
  onboarding; iPad dial/onboarding references are available to the coordinator.
- The inventory above is a source-to-source styling map. UIKit phone/iPad captures
  and the coordinator comparison verdict are recorded in the final review below.
- Live contact photos, online agent cards, populated recordings, active self-test
  progress, discovered service pairing and trace event details retain authored
  styling through native components but require corresponding runtime data to
  capture. No simulated screenshot establishes real pairing, audio routing,
  proximity, PushKit/CallKit cold wake, or carrier media acceptance.

## Styling follow-up build

The final small styling follow-up adds the composer's two separators and matches
its disabled colors, explicitly sets the Contacts unavailable typography/width/
button metrics, and sets grouped cells/header/footer horizontal margins to16pt.
It changes presentation styling only. Build and diff whitespace checks passed;
the already-passing full suite was not repeated, as directed.

The final Dial backdrop correction connects `PhoneBackdropView` to all four root
edges and explicitly updates its colors when appearance traits change. Build and
diff checks passed.

## Final visual review (2026-10-29)

The coordinator installed the rebuilt app and compared it with the baseline on
an iPhone 18 Pro and iPad Pro 13 simulator. Captures were kept locally and are
not committed.

- Compared dial light/dark, incoming/active call presentation fixtures, message
  list/thread/composer, contact authorization and settings. iPad dial and
  incoming-call geometry were checked separately.
- Corrected absent dial dark gradient, generic empty-state typography, settings
  content margins, composer separators/disabled colors and call control sizing.
- Exercised tab navigation, composer recipient/body editing, and returning from a
  thread; the thread remained dismissed. No carrier call or SMS was sent.
- This is component coverage plus representative visual review, not an automated
  pixel-equality assertion. Native text/material rendering and some spacing still
  differ slightly; runtime states listed above without available data remain
  unverified visually. Physical call/push/audio acceptance remains separate.

## Xcode preview coverage

All 18 concrete main-app UIKit screens have named `#Preview` macros in their
owning source files. There are 35 definitions in total, including alternate
states and reusable components, backed by DEBUG-only in-memory TCA fixtures.

Debug and build-for-testing compilation passed. Xcode RenderPreview also rendered
Root, populated Contacts, discovered-device Pairing, saved Recordings, connected
Settings, Trace timeline and connected Call successfully. The preview compiler
required explicit String array types in the dial/DTMF layout; values and ordering
were retained. These are synthetic preview states, not live device/network proof.

## Adversarial review and fixes (2026-10-29)

Claude Opus 5.5 performed an independent read-only review and one adversarial
challenge round against the migration baseline above. The coordinator verified
the findings, implemented fixes, and owns the final checks. Opus did not run tests;
the final navigation and Live Activity corrections follow its second-round
counterexamples and were verified by the coordinator, not a third review round.

| Finding | Final disposition |
| --- | --- |
| H1: Messages render dismissed unrelated modals | Only the tracked composer can be dismissed. Repeated conversation state is not reapplied. |
| H2: Call teardown dismissed root sheets | Only the call's own keypad is dismissed, including completion of an in-flight presentation. |
| H3 / N1: cancelled or pending Back lost routing / recreated a thread | Route application is edge-triggered and defers new destinations until navigation transitions finish. Completed Back closes only its own route. Replies carry the visible thread's recipient. |
| M1: added multi-window behavior | Disabled; the baseline built plist had no multi-scene manifest. |
| M2: newly exposed diagnostic entry | Removed the Settings entry. Diagnostic controllers and previews remain available as in the original source coverage. |
| M3: eager list construction / replacing controls during taps | Custom bodies are created for visible cells and reused while their content identity is unchanged. The obsolete eager-body height branch was removed. |
| M4: shared contact search | Tab and picker have separate TCA query state; picker resets only its own query. |
| M5: Clear dropped while polling | Trace reads, preference writes and pending clears are serialized. Stale responses cannot overwrite a pending toggle or a departed screen. |
| L1: actions used latest array offsets | Call/recording actions resolve the rendered row's stable identity. |
| L2: duplicate row IDs / cached table counts | Duplicate identities and unsynchronized or hidden tables use a reload; valid visible updates preserve input focus. |
| L3: missing refresh on return | Relevant service refreshes run on appearance instead of only initial loading. |
| L4: SMS error reason / draft loss | Client results preserve the backend error. Existing composer text survives a recipient update; stale sends retain their operation guards. |
| Live Activity projected-state lag | URL commands carry the call ID to the main-actor backend boundary, which applies the original gate immediately before acting. |
| Coordinator: stale section copy / fixed-height reply | Header/footer content configurations are refreshed; replies grow for multiline text while respecting available keyboard space. |

Final full native suite: **164 passed, 0 failed, 1 skipped** (165 cases).
The skipped case requires an external TURN test environment. Build-for-testing
and `git diff --check` passed. Regression tests exercise modal ownership, keypad
teardown, speculative/cancelled Back with a state update, route replacement,
explicit reply recipients, cold-link command identity, independent contact
queries, lazy and stable row bodies, duplicate identities, trace races, SMS
errors/drafts, section copy and multiline reply sizing. The Back tests simulate
UIKit's proposed stack and lifecycle; they are not a physical held-swipe test.

Re-rendered and visually inspected the populated thread, Contacts, Recordings,
Settings, Trace timeline and Recents with Xcode RenderPreview. The renderer used
iPhone Duo / iOS 27.1. All 35 preview definitions remain; these captures verify
representative presentation after the fixes, not pixel equality or live service
behavior. Physical calls, PushKit wakeups, audio and carrier acceptance remain
outside this simulator review. Unrelated Android changes were preserved.

## Dead-code cleanup

After the migration, unused SwiftUI-era and legacy code was removed. This included
unread TCA presentation state, SwiftUI-only `Identifiable` IDs, and unused presentation
helpers. Legacy module/router/eSIM/GPS/update API models were removed, along with
Bluetooth helpers and PCM-era media-health counters. Unused relay, ringtone-preview and
language settings code was also removed. Retained API models keep their decoded fields; only
unread PCM statistics were dropped from the cloud control message. Persisted keys and
Live Activity content-state fields are unchanged.
The connected-call audio badge again uses the cloud audio state
(failed shown in red), matching the original SwiftUI color mapping.

Periphery 3.8.0 reports no remaining unused declarations except intentional
retainers, equality identity fields, and Codable or ActivityKit wire fields.
Debug and Release simulator builds passed. The native suite passed with
**159 passed, 0 failed, 1 skipped** across 160 test functions; the skip is the TURN case above.
All 35 previews remain. Tests only for removed code were deleted.
