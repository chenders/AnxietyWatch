import Testing
@testable import AnxietyWatch

struct CNSDepressantClassifierTests {
    @Test("Benzodiazepine category classifies regardless of name")
    func benzoCategory() {
        #expect(CNSDepressantClassifier.classify(name: "Test Med", category: "Benzodiazepine")
            == .benzodiazepine)
    }
    @Test("Z-Drug category maps to benzodiazepine-class window (fail-safe)")
    func zDrug() {
        #expect(CNSDepressantClassifier.classify(name: "Zolpidem Tartrate", category: "Z-Drug")
            == .benzodiazepine)
    }
    @Test("Known IR opioid by name, category Other")
    func opioidByName() {
        #expect(CNSDepressantClassifier.classify(name: "hydrocodone", category: "Other") == .opioidIR)
    }
    @Test("ER markers upgrade an opioid to opioidER")
    func erOpioid() {
        #expect(CNSDepressantClassifier.classify(name: "Oxycodone ER 10mg", category: "Other") == .opioidER)
        #expect(CNSDepressantClassifier.classify(name: "MS Contin", category: "Other") == .opioidER)
    }
    @Test("Methadone maps to the 72h unknown-long-acting class")
    func methadone() {
        #expect(CNSDepressantClassifier.classify(name: "Methadone 5mg", category: "Other")
            == .methadoneOrUnknownLongActing)
    }
    @Test("Non-CNS-depressants return nil")
    func nonDepressant() {
        #expect(CNSDepressantClassifier.classify(name: "Sertraline 50mg", category: "SSRI") == nil)
        #expect(CNSDepressantClassifier.classify(name: "Allopurinol", category: "Other") == nil)
    }
    @Test("Case-insensitive matching")
    func caseInsensitive() {
        #expect(CNSDepressantClassifier.classify(name: "CLONAZEPAM", category: "other") == .benzodiazepine)
    }
    @Test("Dose windows match spec §14.1")
    func windows() {
        #expect(CNSDepressantClass.benzodiazepine.doseWindow == 12 * 3600)
        #expect(CNSDepressantClass.opioidIR.doseWindow == 8 * 3600)
        #expect(CNSDepressantClass.opioidER.doseWindow == 24 * 3600)
        #expect(CNSDepressantClass.methadoneOrUnknownLongActing.doseWindow == 72 * 3600)
    }
}
