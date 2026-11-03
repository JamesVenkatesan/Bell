import Foundation

/// Sunrise, sunset and the moon's phase, for the sky behind "Done for today".
///
/// Computed, not fetched: the NOAA solar equations are accurate to about a
/// minute at mid latitudes, which is more than a background needs, and they
/// need no network, no permission and no WeatherKit entitlement (which a
/// free developer account doesn't get).
enum SkyClock {

    /// Where the sky is calculated for. Campus, because that's where the
    /// user is when a day of classes ends; a few kilometres either way
    /// moves sunset by seconds.
    static let campus = (latitude: 40.4259, longitude: -86.9149)

    struct SunTimes: Equatable {
        var sunrise: Date
        var sunset: Date
    }

    /// Sunrise and sunset on the local calendar day containing `date`.
    /// Nil only in polar day or night, which West Lafayette doesn't have.
    static func sun(on date: Date, latitude: Double = campus.latitude, longitude: Double = campus.longitude,
                    calendar: Calendar = .current) -> SunTimes? {
        let day = calendar.startOfDay(for: date)
        // Noon local time anchors the Julian day, so the answer belongs to
        // the calendar day asked about, whatever the time zone.
        guard let noon = calendar.date(byAdding: .hour, value: 12, to: day) else { return nil }
        let julianDay = noon.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36_525

        let degrees = Double.pi / 180
        let meanLongitude = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let meanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let centre = sin(meanAnomaly * degrees) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * meanAnomaly * degrees) * (0.019993 - 0.000101 * t)
            + sin(3 * meanAnomaly * degrees) * 0.000289
        let trueLongitude = meanLongitude + centre
        let omega = 125.04 - 1934.136 * t
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sin(omega * degrees)
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(omega * degrees)
        let declination = asin(sin(obliquity * degrees) * sin(apparentLongitude * degrees))

        let y = pow(tan(obliquity * degrees / 2), 2)
        let equationOfTime = 4 / degrees * (y * sin(2 * meanLongitude * degrees)
            - 2 * eccentricity * sin(meanAnomaly * degrees)
            + 4 * eccentricity * y * sin(meanAnomaly * degrees) * cos(2 * meanLongitude * degrees)
            - 0.5 * y * y * sin(4 * meanLongitude * degrees)
            - 1.25 * eccentricity * eccentricity * sin(2 * meanAnomaly * degrees))

        // 90.833°: the sun's centre a little below the horizon, allowing for
        // refraction and the sun's radius, which is when it looks set.
        let latitudeRadians = latitude * degrees
        let cosHourAngle = cos(90.833 * degrees) / (cos(latitudeRadians) * cos(declination))
            - tan(latitudeRadians) * tan(declination)
        guard abs(cosHourAngle) <= 1 else { return nil }
        let hourAngle = acos(cosHourAngle) / degrees

        // Minutes after midnight UTC on that day.
        let solarNoonUTC = 720 - 4 * longitude - equationOfTime
        guard let midnightUTC = utcMidnight(for: day, calendar: calendar) else { return nil }
        return SunTimes(sunrise: midnightUTC.addingTimeInterval((solarNoonUTC - 4 * hourAngle) * 60),
                        sunset: midnightUTC.addingTimeInterval((solarNoonUTC + 4 * hourAngle) * 60))
    }

    /// Midnight UTC on the same calendar date as `day` in the local calendar.
    private static func utcMidnight(for day: Date, calendar: Calendar) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return utc.date(from: parts)
    }

    /// Whether it's dark: after today's sunset or before today's sunrise.
    static func isNight(at date: Date, calendar: Calendar = .current) -> Bool {
        guard let sun = sun(on: date, calendar: calendar) else { return false }
        return date >= sun.sunset || date < sun.sunrise
    }

    /// 0 at new moon, 0.5 at full, back towards 1 at the next new moon.
    /// From the mean synodic month and a known new moon; within about a day
    /// of the true phase, which is invisible in a drawing this size.
    static func moonPhase(at date: Date) -> Double {
        let synodicMonth = 29.530588853 * 86_400
        // New moon, 6 January 2000 18:14 UTC.
        let reference = Date(timeIntervalSince1970: 947_182_440)
        let age = date.timeIntervalSince(reference).truncatingRemainder(dividingBy: synodicMonth)
        return (age < 0 ? age + synodicMonth : age) / synodicMonth
    }

    /// Fraction of the disc lit, 0 to 1, for a phase.
    static func illumination(phase: Double) -> Double {
        (1 - cos(2 * Double.pi * phase)) / 2
    }
}
