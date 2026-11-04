import SiriEvaluations
import Testing

struct AirSIMEvaluation: Evaluation {
    let name: String
    let dataset: SiriScenarioLoader

    func subject(from sample: SiriScenario) async throws -> SiriScenarioSubject {
        try await SiriService.run(scenario: sample)
    }

    var evaluators: Evaluators {
        SiriExpectationEvaluator()
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        Self.computeSiriMetrics(into: &aggregator)
    }
}

@Suite("AirSIM - Siri", .serialized)
struct AirSIMSiriEvaluationTests {
    static let appDefinitions = IntentDefinitions(bundleIdentifier: "com.se0nghe0n.airsim.q25")
    static let StartAirSIMCallIntent = appDefinitions.intents["StartAirSIMCallIntent"]
    static let DraftAirSIMMessageIntent = appDefinitions.intents["DraftAirSIMMessageIntent"]
    static let AnswerCurrentAirSIMCallIntent = appDefinitions.intents["AnswerCurrentAirSIMCallIntent"]
    static let DeclineCurrentAirSIMCallIntent = appDefinitions.intents["DeclineCurrentAirSIMCallIntent"]
    static let EndCurrentAirSIMCallIntent = appDefinitions.intents["EndCurrentAirSIMCallIntent"]
    static let SetAirSIMMuteIntent = appDefinitions.intents["SetAirSIMMuteIntent"]
    static let SendAirSIMCallDigitsIntent = appDefinitions.intents["SendAirSIMCallDigitsIntent"]
    static let SetAirSIMConnectionModeIntent = appDefinitions.intents["SetAirSIMConnectionModeIntent"]
    static let OpenAirSIMTabIntent = appDefinitions.intents["OpenAirSIMTabIntent"]

    // `.equals` only matches string values, so Bool and AppEnum parameters are checked with predicates.
    static let isOn = PredicateExpectation.matches(#Predicate<Bool> { $0 }, requirement: "is on")

    static func isCase(_ rawValue: String) -> PredicateExpectation {
        .matches(#Predicate<AnyAppEnum> { $0.rawValue == rawValue }, requirement: "is \(rawValue)")
    }

    static let draftRunningLate = SiriScenario {
        UserTurn("Text Alex running late with AirSIM") {
            Calls {
                DraftAirSIMMessageIntent.expect(
                    recipient: .notNil,
                    text: .contains(regex: "(?i)^\\s*running late[.!]?\\s*$")
                )
            }
            Calls(.disallowed) { StartAirSIMCallIntent }
        }
    }

    static let draftRunningLateParaphrase = SiriScenario {
        UserTurn("In AirSIM, draft an SMS to Alex that says running late") {
            Calls {
                DraftAirSIMMessageIntent.expect(
                    recipient: .notNil,
                    text: .contains(regex: "(?i)^\\s*running late[.!]?\\s*$")
                )
            }
            Calls(.disallowed) { StartAirSIMCallIntent }
        }
    }

    static let draftEvaluation = AirSIMEvaluation(
        name: "AirSIM - Draft an SMS",
        dataset: SiriScenarioLoader {
            draftRunningLate
            draftRunningLateParaphrase
        }
    )

    @Test("Siri drafts an AirSIM SMS to the named contact without calling them", .evaluates(draftEvaluation))
    func draftsMessage() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: .intentsAllPass)) == 1.0)
    }

    static let openRecents = SiriScenario {
        UserTurn("Open Recents in AirSIM") {
            Calls { OpenAirSIMTabIntent.expect(tab: isCase("recents")) }
        }
    }

    static let showSettings = SiriScenario {
        UserTurn("Show AirSIM Settings") {
            Calls { OpenAirSIMTabIntent.expect(tab: isCase("settings")) }
            Calls(.disallowed) { SetAirSIMConnectionModeIntent }
        }
    }

    static let tabEvaluation = AirSIMEvaluation(
        name: "AirSIM - Open a tab",
        dataset: SiriScenarioLoader {
            openRecents
            showSettings
        }
    )

    @Test("Siri opens the requested AirSIM tab", .evaluates(tabEvaluation))
    func opensTab() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: .intentsAllPass)) == 1.0)
    }

    static let setCloud = SiriScenario {
        UserTurn("Set AirSIM's connection mode to Cloud") {
            Calls { SetAirSIMConnectionModeIntent.expect(mode: isCase("cloud")) }
        }
    }

    // Runs after setCloud and returns the device to AirSIM's default mode.
    static let setAutomatic = SiriScenario {
        UserTurn("Switch AirSIM's connection mode back to Automatic") {
            Calls { SetAirSIMConnectionModeIntent.expect(mode: isCase("automatic")) }
        }
    }

    static let connectionModeEvaluation = AirSIMEvaluation(
        name: "AirSIM - Connection mode",
        dataset: SiriScenarioLoader {
            setCloud
            setAutomatic
        }
    )

    @Test("Siri sets AirSIM's connection mode", .evaluates(connectionModeEvaluation))
    func setsConnectionMode() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: .intentsAllPass)) == 1.0)
    }

    // One conversation, so the call the first turn places is the call the later turns control.
    static let callAndControl = SiriScenario {
        UserTurn("Call Alex using AirSIM") {
            Calls {
                StartAirSIMCallIntent.expect(destination: .notNil, audioVisualMode: isCase("audio"))
            }
            Calls(.disallowed) { DraftAirSIMMessageIntent }
        }
        UserTurn("Mute the AirSIM call") {
            Calls { SetAirSIMMuteIntent.expect(muted: isOn) }
            Calls(.disallowed) {
                EndCurrentAirSIMCallIntent
                DeclineCurrentAirSIMCallIntent
            }
        }
        UserTurn("On the AirSIM call, press 1 2 3 4 pound") {
            Calls { SendAirSIMCallDigitsIntent.expect(digits: .contains(regex: "^\\s*1\\s*2\\s*3\\s*4\\s*#\\s*$")) }
            Calls(.disallowed) {
                EndCurrentAirSIMCallIntent
                DeclineCurrentAirSIMCallIntent
            }
        }
        UserTurn("Hang up the AirSIM call") {
            Calls { EndCurrentAirSIMCallIntent }
        }
    }

    static let callEvaluation = AirSIMEvaluation(
        name: "AirSIM - Call a contact and control the call",
        dataset: SiriScenarioLoader { callAndControl }
    )

    @Test("Siri places an AirSIM audio call, mutes it, sends digits and hangs up", .evaluates(callEvaluation))
    func callsAndControlsCall() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: .intentsAllPass)) == 1.0)
    }

    static let answerIncoming = SiriScenario {
        UserTurn("Answer the AirSIM call") {
            Calls { AnswerCurrentAirSIMCallIntent }
            Calls(.disallowed) {
                DeclineCurrentAirSIMCallIntent
                EndCurrentAirSIMCallIntent
            }
        }
    }

    static let answerEvaluation = AirSIMEvaluation(
        name: "AirSIM - Answer an incoming call",
        dataset: SiriScenarioLoader { answerIncoming }
    )

    @Test("Siri answers a ringing AirSIM call instead of declining it", .evaluates(answerEvaluation))
    func answersIncomingCall() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: .intentsAllPass)) == 1.0)
    }
}
