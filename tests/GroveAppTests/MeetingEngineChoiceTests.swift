import Foundation
import GroveInference
import Testing
@testable import GroveApp

struct MeetingEngineChoiceTests {
    @Test func freshDefaultIsNemotronWithoutInventingACount() throws {
        let configuration = try MeetingSpeakerOptions().plan(isDual: false).configuration
        #expect(try configuration.resolvedEngine() == .nemotron3)
        #expect(configuration.expectedSpeakerCount == nil && configuration.speakerCountPolicy == .advisory)
    }

    @Test(arguments: ["automatic", "ultra8", "sortformerStreaming", nil])
    func retiredSavedChoicesOpenAsNemotron(_ saved: String?) throws {
        let field = saved.map { #","engineChoice":"\#($0)""# } ?? ""
        let json = Data(#"{"mode":"automatic","countText":""\#(field)}"#.utf8)
        let options = try JSONDecoder().decode(MeetingSpeakerOptions.self, from: json)
        #expect(options.engineChoice == .nemotron3)
        #expect(try options.plan(isDual: false).configuration.resolvedEngine() == .nemotron3)
    }

    @Test func retiredSavedChoiceThatNeededCommunityKeepsItsCount() throws {
        let json = Data(#"{"mode":"manualCount","countText":"9","engineChoice":"automatic"}"#.utf8)
        let options = try JSONDecoder().decode(MeetingSpeakerOptions.self, from: json)
        #expect(options.engineChoice == .community1)
        let configuration = try options.plan(isDual: false).configuration
        #expect(try configuration.resolvedEngine() == .community1)
        #expect(configuration.expectedSpeakerCount == 9 && configuration.speakerCountPolicy == .exact)
    }

    @Test func reopeningRetiredConfigurationsChoosesASupportedEngine() throws {
        #expect(MeetingSpeakerOptions(configuration: .init(diarizationPreference: .ultra8)).engineChoice == .nemotron3)
        #expect(MeetingSpeakerOptions(configuration: .init(expectedSpeakerCount: 4, diarizationPreference: .sortformerStreaming)).engineChoice == .nemotron3)
        let exactFive = InferenceConfiguration(expectedSpeakerCount: 5, speakerCountPolicy: .exact)
        let reopened = MeetingSpeakerOptions(configuration: exactFive)
        #expect(reopened.engineChoice == .community1)
        let next = try reopened.plan(isDual: false).configuration
        #expect(try next.resolvedEngine() == .community1)
        #expect(next.expectedSpeakerCount == 5 && next.speakerCountPolicy == .exact)
        #expect(MeetingSpeakerOptions(configuration: .init(expectedSpeakerCount: 9)).engineChoice == .community1)
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

    @Test func nemotronCountIsAdvisoryAndLimitedToEight() throws {
        var options = MeetingSpeakerOptions()
        options.mode = .manualCount
        options.countText = "8"
        let eight = try options.plan(isDual: false).configuration
        #expect(eight.speakerCountPolicy == .advisory)
        #expect(try MeetingSpeakerOptions(configuration: eight).plan(isDual: false).configuration == eight)
        options.countText = "9"
        #expect(options.validationMessage(isDual: false)?.contains("최대 8명") == true)
    }

    @Test func explicitCommunityChoiceSurvivesPersistence() throws {
        var options = MeetingSpeakerOptions()
        options.engineChoice = .community1
        let copy = try JSONDecoder().decode(MeetingSpeakerOptions.self, from: JSONEncoder().encode(options))
        #expect(copy == options)
    }
}
