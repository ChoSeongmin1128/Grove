import Foundation
import GroveInference
import Testing
@testable import GroveApp

struct MeetingSpeakerOptionsTests {
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9, 12])
    func enteredCountChoosesEngineAndIsPassedWithoutClamping(_ count: Int) throws {
        var options = MeetingSpeakerOptions()
        options.engineChoice = count <= 8 ? .nemotron3 : .community1
        options.mode = .manualCount
        options.countText = String(count)
        let config = try options.plan(isDual: false).configuration
        #expect(config.expectedSpeakerCount == count)
        let args = try NativeInferenceBackend.diarizationArguments(audio: URL(fileURLWithPath: "/tmp/input.wav"),
            output: URL(fileURLWithPath: "/tmp/output.json"), configuration: config,
            nemotronModel: URL(fileURLWithPath: "/tmp/model.gguf"))
        if count <= 8 {
            #expect(try config.resolvedEngine() == .nemotron3)
            #expect(config.speakerCountPolicy == .advisory)
            #expect(!args.contains("--num-speakers"))
        } else {
            #expect(try config.resolvedEngine() == .community1)
            #expect(config.speakerCountPolicy == .exact)
            #expect(args.suffix(2) == ["--num-speakers", String(count)])
        }
    }

    @Test(arguments: ["", " ", "0", "-2", "4.5", "네 명", "999999999999999999999999"])
    func invalidCountsCannotStartAJob(_ input: String) {
        var options = MeetingSpeakerOptions()
        options.mode = .manualCount
        options.countText = input
        #expect(throws: InferenceError.self) { try options.plan(isDual: false) }
    }

    @Test func fullWidthDigitsAndStoredCountsRoundTrip() throws {
        var options = MeetingSpeakerOptions()
        options.mode = .manualCount
        options.countText = " ５ "
        let config = try options.plan(isDual: false).configuration
        let reopened = MeetingSpeakerOptions(configuration: config)
        #expect(reopened.mode == .manualCount)
        #expect(reopened.countText == "5")
        #expect(try reopened.plan(isDual: false).configuration == config)
    }

    @Test func oldFourOrFewerSelectionDoesNotInventAnExactCount() throws {
        let options = MeetingSpeakerOptions(configuration: .init(diarizationPreference: .sortformerStreaming))
        #expect(options.mode == .automatic)
        #expect(options.countText.isEmpty)
        #expect(try options.plan(isDual: false).configuration.expectedSpeakerCount == nil)
    }

    @Test func dualSourceCountsAreIndependentAndPersistable() throws {
        var options = MeetingSpeakerOptions()
        options.mode = .manualCount
        options.systemCountText = "5"
        options.microphoneCountText = "1"
        let plan = try options.plan(isDual: true)
        let configs = try plan.configurations(for: ["system", "microphone"])
        #expect(configs["system"]?.expectedSpeakerCount == 5)
        #expect(try configs["system"]?.resolvedEngine() == .nemotron3)
        #expect(configs["microphone"]?.expectedSpeakerCount == 1)
        #expect(try configs["microphone"]?.resolvedEngine() == .nemotron3)
        let reopened = MeetingSpeakerOptions(configuration: plan.configuration, channels: plan.channelConfigurations)
        #expect(try reopened.plan(isDual: true) == plan)
        let global = MeetingInferencePlan(configuration: try MeetingEngineChoice.nemotron3.configuration(count: 5))
        #expect(throws: InferenceError.self) { try global.configurations(for: ["system", "microphone"]) }
        #expect(throws: InferenceError.self) { try plan.configurations(for: ["recording"]) }
    }
}
