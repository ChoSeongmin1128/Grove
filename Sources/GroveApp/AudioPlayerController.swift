@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AudioPlayerController: ObservableObject {
    @Published private(set) var playingSegmentID: UUID?
    private var player: AVAudioPlayer?

    func play(meeting: MeetingRecord, segment: TranscriptSegment) {
        guard let path = meeting.audioPath else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.currentTime = max(0, segment.startTime - 3)
            player.prepareToPlay()
            player.play()
            self.player = player
            playingSegmentID = segment.id
        } catch {
            playingSegmentID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingSegmentID = nil
    }
}
