import XCTest
@testable import BiliCore

final class HLSPlaylistBuilderTests: XCTestCase {
    private func video(id: Int = 80, codecs: String, width: Int = 1920, height: Int = 1080, fps: Double = 29.412,
                       bandwidth: Int = 2_000_000) -> DashStream {
        DashStream(kind: .video, id: id, baseURL: "https://x.bilivideo.com/v.m4s", bandwidth: bandwidth,
                   codecs: codecs, width: width, height: height, frameRate: fps)
    }

    private let audio = DashStream(kind: .audio, id: 30280, baseURL: "https://x.bilivideo.com/a.m4s",
                                   bandwidth: 319_000, codecs: "mp4a.40.2")

    func testSDRAVCMasterExactText() {
        let text = HLSPlaylistBuilder.masterPlaylist(video: video(codecs: "avc1.640032"), videoURI: "v.m3u8",
                                                     audio: audio, audioURI: "a.m3u8")
        XCTAssertEqual(text, """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS

        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="音轨 (319kbps)",LANGUAGE="zh",DEFAULT=YES,AUTOSELECT=YES,URI="a.m3u8"
        #EXT-X-STREAM-INF:AUDIO="audio",CODECS="avc1.640032",RESOLUTION=1920x1080,FRAME-RATE=29.412,BANDWIDTH=3000000,AVERAGE-BANDWIDTH=2000000,VIDEO-RANGE=SDR
        v.m3u8

        """)
        XCTAssertFalse(text.contains("ENDLIST"))
        XCTAssertFalse(text.contains("I-FRAME"))
    }

    func testHEVCIsWrittenVerbatim() {
        let text = HLSPlaylistBuilder.masterPlaylist(video: video(codecs: "hev1.1.6.L120.90", bandwidth: 1_000_000),
                                                     videoURI: "v.m3u8", audio: audio, audioURI: "a.m3u8")
        XCTAssertTrue(text.contains("""
        #EXT-X-STREAM-INF:AUDIO="audio",CODECS="hev1.1.6.L120.90",RESOLUTION=1920x1080,FRAME-RATE=29.412,BANDWIDTH=1500000,AVERAGE-BANDWIDTH=1000000,VIDEO-RANGE=SDR
        v.m3u8
        """), text)
    }

    func testVideoOnlyMaster() {
        let text = HLSPlaylistBuilder.masterPlaylist(video: video(codecs: "avc1.64001F", width: 1280, height: 720,
                                                                  fps: 30, bandwidth: 900_000),
                                                     videoURI: "v.m3u8", audio: nil, audioURI: nil)
        XCTAssertEqual(text, """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS

        #EXT-X-STREAM-INF:CODECS="avc1.64001F",RESOLUTION=1280x720,FRAME-RATE=30.000,BANDWIDTH=1350000,AVERAGE-BANDWIDTH=900000,VIDEO-RANGE=SDR
        v.m3u8

        """)
    }

    /// 听视频 passes the audio representation as the only track: no video attributes.
    func testAudioOnlyMasterHasNoVideoAttributes() {
        let text = HLSPlaylistBuilder.masterPlaylist(video: audio, videoURI: "v.m3u8", audio: nil, audioURI: nil)
        XCTAssertEqual(text, """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS

        #EXT-X-STREAM-INF:CODECS="mp4a.40.2",BANDWIDTH=478500,AVERAGE-BANDWIDTH=319000
        v.m3u8

        """)
        XCTAssertTrue(HLSPlaylistBuilder.isAudioRepresentation(audio))
        XCTAssertFalse(HLSPlaylistBuilder.isAudioRepresentation(video(codecs: "avc1.640032")))
    }

    func testDolbyVision84() {
        let stream = video(id: 126, codecs: "dvh1.08.07", width: 3840, height: 2160, fps: 30, bandwidth: 16_000_000)
        let text = HLSPlaylistBuilder.masterPlaylist(video: stream, videoURI: "v.m3u8", audio: audio, audioURI: "a.m3u8")
        XCTAssertTrue(text.contains(
            "#EXT-X-STREAM-INF:AUDIO=\"audio\",CODECS=\"hvc1.2.4.L153.b0\",SUPPLEMENTAL-CODECS=\"dvh1.08.07/db4h\","
                + "RESOLUTION=3840x2160,FRAME-RATE=30.000,BANDWIDTH=24000000,AVERAGE-BANDWIDTH=16000000,VIDEO-RANGE=HLG\n"),
                      text)
        let a = HLSPlaylistBuilder.videoAttributes(for: video(id: 126, codecs: "dvh1.08.03"))
        XCTAssertEqual(a, .init(codecs: "hvc1.2.4.L153.b0", supplementalCodecs: "dvh1.08.03/db4h", videoRange: "HLG",
                                frameRate: "29.412"))
        // Without HDR permission only the HEVC base layer is announced.
        let base = HLSPlaylistBuilder.videoAttributes(for: stream, allowDolbyVision: false)
        XCTAssertEqual(base.codecs, "hvc1.2.4.L153.b0")
        XCTAssertNil(base.supplementalCodecs)
    }

    func testDolbyVision81And5() {
        XCTAssertEqual(HLSPlaylistBuilder.videoAttributes(for: video(id: 126, codecs: "dvh1.08.06", fps: 24)),
                       .init(codecs: "hvc1.2.4.L150", supplementalCodecs: "dvh1.08.06/db1p", videoRange: "PQ",
                             frameRate: "24.000"))
        XCTAssertEqual(HLSPlaylistBuilder.videoAttributes(for: video(id: 126, codecs: "dvh1.05.06", fps: 60)),
                       .init(codecs: "dvh1.05.06", supplementalCodecs: nil, videoRange: "PQ", frameRate: "60.000"))
        // Unknown codec on the Dolby quality: verbatim, HLG.
        XCTAssertEqual(HLSPlaylistBuilder.videoAttributes(for: video(id: 126, codecs: "hev1.2.4.L153.90")).videoRange, "HLG")
    }

    func testHDR10FrameRateCapAndPQ() {
        let capped = HLSPlaylistBuilder.videoAttributes(for: video(id: 125, codecs: "hev1.2.4.L156.90", fps: 59.94))
        XCTAssertEqual(capped, .init(codecs: "hev1.2.4.L156.90", supplementalCodecs: nil, videoRange: "PQ",
                                     frameRate: "30.000"))
        let kept = HLSPlaylistBuilder.videoAttributes(for: video(id: 125, codecs: "hev1.2.4.L156.90", fps: 25))
        XCTAssertEqual(kept.frameRate, "25.000")
        // Missing frame rate → 25; ≥ 60 → 60 (SDR).
        XCTAssertEqual(HLSPlaylistBuilder.videoAttributes(for: video(codecs: "avc1.640032", fps: 0)).frameRate, "25.000")
        XCTAssertEqual(HLSPlaylistBuilder.videoAttributes(for: video(codecs: "avc1.640032", fps: 120)).frameRate, "60.000")
        XCTAssertEqual(HLSPlaylistBuilder.videoAttributes(for: video(codecs: "avc1.640032", fps: 59.94)).frameRate, "59.940")
    }

    func testBandwidthIsOnePointFiveTimesAverage() {
        XCTAssertEqual(HLSPlaylistBuilder.peakBandwidth(forAverage: 785_000), 1_177_500)
        XCTAssertEqual(HLSPlaylistBuilder.peakBandwidth(forAverage: 3_170_001), 4_755_001)
        let text = HLSPlaylistBuilder.masterPlaylist(video: video(codecs: "avc1.640032", bandwidth: 785_000),
                                                     videoURI: "v.m3u8", audio: nil, audioURI: nil)
        XCTAssertTrue(text.contains("BANDWIDTH=1177500,AVERAGE-BANDWIDTH=785000,"), text)
        // An explicit average (playurl reported 0) is used instead.
        let estimated = HLSPlaylistBuilder.masterPlaylist(video: video(codecs: "avc1.640032", bandwidth: 0),
                                                          videoURI: "v.m3u8", audio: nil, audioURI: nil,
                                                          averageBandwidth: 1_000_000)
        XCTAssertTrue(estimated.contains("BANDWIDTH=1500000,AVERAGE-BANDWIDTH=1000000,"), estimated)
    }

    func testMediaPlaylistWorkedExample() throws {
        let box = EngineSyntheticMP4.sidxBox(timescale: 16000, references: [
            .init(size: 524_288, duration: 80080), .init(size: 498_001, duration: 80080), .init(size: 301_777, duration: 51200),
        ], boxSize: 664)
        let index = try SidxParser.parse(box, absoluteStart: 1005)
        let text = HLSPlaylistBuilder.mediaPlaylist(initRange: ByteRange(start: 0, end: 1004), segments: index.segments,
                                                    uri: "v.m4s")
        XCTAssertEqual(text, """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="v.m4s",BYTERANGE="1005@0"
        #EXTINF:5.005,
        #EXT-X-BYTERANGE:524288@1669
        v.m4s
        #EXTINF:5.005,
        #EXT-X-BYTERANGE:498001@525957
        v.m4s
        #EXTINF:3.200,
        #EXT-X-BYTERANGE:301777@1023958
        v.m4s
        #EXT-X-ENDLIST

        """)
        // Round trip: the byte ranges tile the file after the index.
        let total = index.segments.reduce(Int64(0)) { $0 + $1.byteRange.length }
        XCTAssertEqual(total, 1_023_958 + 301_777 - 1669)
    }

    func testTargetDurationIsFloorPlusOne() {
        let segments = [SidxSegment(index: 0, byteRange: ByteRange(start: 100, end: 199), startTime: 0, duration: 5.0),
                        SidxSegment(index: 1, byteRange: ByteRange(start: 200, end: 299), startTime: 5, duration: 4.2)]
        let text = HLSPlaylistBuilder.mediaPlaylist(initRange: ByteRange(start: 10, end: 99), segments: segments, uri: "a.m4s")
        XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:6\n"))
        XCTAssertTrue(text.contains("#EXT-X-MAP:URI=\"a.m4s\",BYTERANGE=\"90@10\"\n"))
        XCTAssertTrue(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    func testDecimal3() {
        XCTAssertEqual(HLSPlaylistBuilder.decimal3(5.005), "5.005")
        XCTAssertEqual(HLSPlaylistBuilder.decimal3(3.2), "3.200")
        XCTAssertEqual(HLSPlaylistBuilder.decimal3(0.0004), "0.000")
        XCTAssertEqual(HLSPlaylistBuilder.decimal3(59.94), "59.940")
        XCTAssertEqual(HLSPlaylistBuilder.decimal3(29.4116), "29.412")
        XCTAssertEqual(HLSPlaylistBuilder.decimal3(.infinity), "0.000")
        XCTAssertEqual(HLSPlaylistBuilder.estimatedBandwidth(segments: [
            SidxSegment(index: 0, byteRange: ByteRange(start: 0, end: 124_999), startTime: 0, duration: 1),
        ]), 1_000_000)
    }
}
