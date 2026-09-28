import Foundation
import DaisyCore

/// espeak reads "3.5" as "three. five", "$4.50" as "dollar four. fifty" and "e.g." as two
/// sentences, so numbers, times, dates, money and abbreviations reach it as words. These pin how.
final class SpeechNumbersTests {
    private func say(_ text: String) -> String { SpeechText.spoken(from: text) }

    func testDecimalsAndWholeNumbers() {
        expectEqual(say("It is 3.5 miles."), "It is three point five miles.")
        expectEqual(say("Pi is about 3.14159."), "Pi is about three point one four one five nine.")
        expectEqual(say("Use 0.5 or .5 cups."), "Use zero point five or point five cups.")
        expectEqual(say("Version 1.2.10 is out."), "Version one point two point ten is out.")
        expectEqual(say("It has 1,234,567 rows and 42 columns."),
                    "It has one million two hundred thirty-four thousand five hundred sixty-seven rows and forty-two columns.")
        expectEqual(say("Room 101, floor 3."), "Room one hundred one, floor three.")
        expectEqual(say("It's -5 out."), "It's minus five out.")
        expectEqual(say("Agent 007."), "Agent zero zero seven.")
        expectEqual(say("Try qwen3.5 today."), "Try qwen three point five today.")
        expectEqual(say("That's 1,000,000 or 10000 steps."), "That's one million or ten thousand steps.")
    }
    func testYearsDecadesAndOrdinals() {
        expectEqual(say("In 2026 we go, like in 1999, 2000, 2005 and 1905."),
                    "In twenty twenty-six we go, like in nineteen ninety-nine, two thousand, two thousand five and nineteen oh five.")
        expectEqual(say("About 1500 people, not 999 or 2100."), "About fifteen hundred people, not nine hundred ninety-nine or two thousand one hundred.")
        expectEqual(say("The 1990s, the 2000s, the '80s and their 30s."), "The nineteen nineties, the two thousands, the eighties and their thirties.")
        expectEqual(say("The 21st, 2nd, 3rd, 12th, 40th and 100th times."),
                    "The twenty-first, second, third, twelfth, fortieth and one hundredth times.")
    }
    func testMoney() {
        expectEqual(say("It costs $4.50."), "It costs four dollars and fifty cents.")
        expectEqual(say("$1, $1.01, $0.99 and $20.00."), "One dollar, one dollar and one cent, ninety-nine cents and twenty dollars.")
        expectEqual(say("Only $1,299.99 today."), "Only one thousand two hundred ninety-nine dollars and ninety-nine cents today.")
        expectEqual(say("Raised $3.5 million, then $2B, then $5k."),
                    "Raised three point five million dollars, then two billion dollars, then five thousand dollars.")
        expectEqual(say("It's $5-10, or €5, or £4.50, or $4.5."),
                    "It's five to ten dollars, or five euros, or four pounds and fifty pence, or four point five dollars.")
        expectEqual(say("It costs $5, not $10."), "It costs five dollars, not ten dollars.")
    }
    func testPercentagesRangesAndMultipliers() {
        expectEqual(say("It rose 50%, then 12.5%, then fell -3% or 10-20%."),
                    "It rose fifty percent, then twelve point five percent, then fell minus three percent or ten to twenty percent.")
        expectEqual(say("Wait 5-10 minutes, from 2020–2026, score 3-2."),
                    "Wait five to ten minutes, from twenty twenty to twenty twenty-six, score three to two.")
        expectEqual(say("It's 2x faster, even 1.5x."), "It's two times faster, even one point five times.")
    }
    func testTimes() {
        expectEqual(say("Meet at 3:30 pm, or 10:05am, or 3 p.m. on Friday."), "Meet at three thirty PM, or ten oh five AM, or three PM on Friday.")
        expectEqual(say("Meet at 3:30 p.m. Then we eat."), "Meet at three thirty PM. Then we eat.")
        expectEqual(say("It's 10:00, not 15:30 or 00:15."), "It's ten o'clock, not three thirty PM or twelve fifteen AM.")
        expectEqual(say("Read John 3:16 by 12:00 pm."), "Read John three sixteen by twelve PM.")
        expectEqual(say("The call is at 9 AM."), "The call is at nine AM.")
    }
    func testDates() {
        expectEqual(say("Due 2026-10-15, or 10/15/2026, or 15/10/26."),
                    "Due October fifteenth, twenty twenty-six, or October fifteenth, twenty twenty-six, or October fifteenth, twenty twenty-six.")
        expectEqual(say("Due Oct 15, then Oct. 15, 2026, then October 15th."),
                    "Due October fifteenth, then October fifteenth, twenty twenty-six, then October fifteenth.")
        expectEqual(say("Since March 2026 and May 5."), "Since March twenty twenty-six and May fifth.")
        expectEqual(say("Before Oct. 15: finish it."), "Before October fifteenth: finish it.")
    }
    func testUnitsFractionsAndSymbols() {
        expectEqual(say("Drive 5 km, then 1 km, with 16GB of RAM in 200 ms."),
                    "Drive five kilometers, then one kilometer, with sixteen gigabytes of RAM in two hundred milliseconds.")
        expectEqual(say("It's 70°F, or 21 °C, at 90° up."), "It's seventy degrees Fahrenheit, or twenty-one degrees Celsius, at ninety degrees up.")
        expectEqual(say("Add 1/2 cup and 3/4 cup, open 24/7, a 50/50 split, 1½ hours."),
                    "Add one half cup and three quarters cup, open twenty-four seven, a fifty-fifty split, one and a half hours.")
        expectEqual(say("We're #1 with ~5 left, ≈10 total, ±2, ≥ 3 and 3 × 4."),
                    "We're number one with about five left, about ten total, plus or minus two, at least three and three times four.")
        expectEqual(say("Pick No. 5 - the good one."), "Pick number five — the good one.")
        expectEqual(say("Done in 2h, at 20 tokens/s, for $5/mo, at 100 km/h."),
                    "Done in two hours, at twenty tokens per second, for five dollars per month, at one hundred kilometers per hour.")
    }
    func testAbbreviations() {
        expectEqual(say("Try a city, e.g. Paris, or e.g., Rome (i.e. somewhere warm)."),
                    "Try a city, for example, Paris, or for example, Rome (that is, somewhere warm).")
        expectEqual(say("Dr. Smith vs. Mr. Jones, with Mrs. Lee, Ms. Park and Prof. Xavier."),
                    "Doctor Smith versus Mister Jones, with Missus Lee, Miz Park and Professor Xavier.")
        expectEqual(say("Plan B, a.k.a. the backup: coffee w/ milk, tea w/o. Approx. 5 people."),
                    "Plan B, also known as the backup: coffee with milk, tea without. Approximately five people.")
        expectEqual(say("Go to St. Louis, then Main St."), "Go to Saint Louis, then Main Street.")
        expectEqual(say("She has a Ph.D. in math, like Martin Luther King Jr. did."), "She has a PhD in math, like Martin Luther King Junior did.")
    }
    func testAbbreviationsThatEndASentenceKeepTheirPeriod() {
        expectEqual(say("Apples, pears, etc. are fruit."), "Apples, pears, et cetera are fruit.")
        expectEqual(say("I like apples, pears, etc. Then I left."), "I like apples, pears, et cetera. Then I left.")
        expectEqual(say("He moved to the U.S. last year."), "He moved to the US last year.")
        expectEqual(say("He moved to the U.S. Then he left the U.K."), "He moved to the US. Then he left the UK.")
        expectEqual(say("I like apples, etc."), "I like apples, et cetera.")
        // A day, a month or a time zone after one doesn't start a new sentence.
        expectEqual(say("Email her by 5 p.m. Friday, or 9 a.m. EST."), "Email her by five PM Friday, or nine AM EST.")
    }
    func testHostsFilesEmailsAndPhoneNumbers() {
        expectEqual(say("Open config.json or README.md from github.com."), "Open config dot json or README dot md from github dot com.")
        expectEqual(say("Email josh@example.com or call (555) 123-4567 or 555-123-4567."),
                    "Email josh at example dot com or call five five five, one two three, four five six seven or five five five, one two three, four five six seven.")
    }
    func testLeavesModelNamesAndCodesAlone() {
        expectEqual(say("The M3 Air, a 4K screen at 1080p, x86 and GPT-4o on COVID-19 data."),
                    "The M3 Air, a 4K screen at 1080p, x86 and GPT-4o on COVID-nineteen data.")
    }
}
