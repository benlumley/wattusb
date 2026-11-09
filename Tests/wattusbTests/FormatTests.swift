import Testing
@testable import wattusb

struct FormatTests {
    @Test func timeShowsHoursOnlyWhenThereAreAny() {
        #expect(formatTime(45) == "45m")
        #expect(formatTime(125) == "2h 5m")
    }

    @Test func agoShowsMinutesOnlyWhenThereAreAny() {
        #expect(formatAgo(40.4) == "40s")
        #expect(formatAgo(130) == "2m 10s")
    }
}
