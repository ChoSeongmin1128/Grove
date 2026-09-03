import Foundation
import GroveInference
import Testing
@testable import GroveApp

struct MeetingEngineChoiceTests {
    @Test func automaticEngineRemainsAutomaticAfterReopeningAndChangingCount() throws {
        let initial = try MeetingSpeakerOptions().plan(isDual: false)
        var reopened = MeetingSpeakerOptions(configuration: initial.configuration)
        #expect(reopened.engineChoice == .automatic)
        reopened.mode = .manualCount
        reopened.countText = "4"
        #expect(try reopened.plan(isDual: false).configuration.resolvedEngine() == .ultra8)
        reopened.countText = "9"
        #expect(try reopened.plan(isDual: false).configuration.resolvedEngine() == .community1)
        reopened.mode = .automatic
        #expect(try reopened.plan(isDual: false).configuration.resolvedEngine() == .ultra8)
    }
    @Test func legacyDefaultsDecodeWithoutChangingAutomaticChoice() throws {
        let json = Data(#"{"mode":"manualCount","countText":"4","systemCountText":"","microphoneCountText":""}"#.utf8)
        let options = try JSONDecoder().decode(MeetingSpeakerOptions.self, from: json)
        #expect(options.engineChoice == .automatic)
        #expect(try options.plan(isDual: false).configuration.resolvedEngine() == .ultra8)
    }

    @Test func ultraCanBeChosenWithOrWithoutAnAdvisoryCountAndRestored() throws {
        var options = MeetingSpeakerOptions()
        options.engineChoice = .ultra8
        let auto = try options.plan(isDual: false).configuration
        #expect(auto.expectedSpeakerCount == nil)
        #expect(try auto.resolvedEngine() == .ultra8)
        #expect(MeetingSpeakerOptions(configuration: auto).mode == .automatic)
        options.mode = .manualCount
        options.countText = "4"
        let known = try options.plan(isDual: false).configuration
        #expect(known.speakerCountPolicy == .advisory)
        #expect(try MeetingSpeakerOptions(configuration: known).plan(isDual: false).configuration == known)
        options.countText = "9"
        #expect(options.validationMessage(isDual: false)?.contains("최대 8명") == true)
    }

    @Test func sameCommunityEngineCanCompareAutoAndExactFour() throws {
        var options = MeetingSpeakerOptions()
        options.engineChoice = .community1
        let auto = try options.plan(isDual: false).configuration
        options.mode = .manualCount
        options.countText = "4"
        let fixed = try options.plan(isDual: false).configuration
        #expect(try auto.resolvedEngine() == .community1)
        #expect(try fixed.resolvedEngine() == .community1)
        #expect(auto.expectedSpeakerCount == nil)
        #expect(fixed.expectedSpeakerCount == 4 && fixed.speakerCountPolicy == .exact)
    }

    @Test func explicitUltraDoesNotGetLostAcrossDefaultOrPerMeetingPersistence() throws {
        var options = MeetingSpeakerOptions()
        options.engineChoice = .ultra8
        let copy = try JSONDecoder().decode(MeetingSpeakerOptions.self, from: JSONEncoder().encode(options))
        #expect(copy == options)
        #expect(copy.engineChoice == .ultra8)
    }

    @Test func explicitSortformerSurvivesTheNewAutomaticDefault() throws {
        var options = MeetingSpeakerOptions()
        options.engineChoice = .sortformerStreaming
        options.mode = .manualCount
        options.countText = "4"
        let copy = try JSONDecoder().decode(MeetingSpeakerOptions.self, from: JSONEncoder().encode(options))
        let config = try copy.plan(isDual: false).configuration
        #expect(try config.resolvedEngine() == .sortformerStreaming)
        #expect(try MeetingSpeakerOptions(configuration: config).plan(isDual: false).configuration == config)
        options.countText = "5"
        #expect(throws: InferenceError.self) { try options.plan(isDual: false) }
    }

    @Test func legacyAutomaticFiveUsesNewPolicyOnlyForTheNextRequestedJob() throws {
        let saved = InferenceConfiguration(expectedSpeakerCount: 5, speakerCountPolicy: .exact)
        let reopened = MeetingSpeakerOptions(configuration: saved)
        let next = try reopened.plan(isDual: false).configuration
        #expect(reopened.engineChoice == .automatic)
        #expect(next.expectedSpeakerCount == 5 && next.speakerCountPolicy == .advisory)
        #expect(try next.resolvedEngine() == .ultra8)
        #expect(saved.speakerCountPolicy == .exact)
        #expect(try saved.resolvedEngine() == .community1)
    }
}
