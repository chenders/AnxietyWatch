import Foundation

/// Pure category/name → `CNSDepressantClass` default classifier. This is a
/// DEFAULT ONLY — `MedicationDefinition.cnsDepressantClass` (set from a
/// user-editable picker) is the source of truth that arms overnight
/// respiratory-depression monitoring. A false negative here (missing a CNS
/// depressant) is worse than a false positive, so every rule below is
/// deliberately generous: category is checked first (the most reliable
/// signal, since it's an explicit picker value), then name-based word lists
/// run as a backstop REGARDLESS of category — a benzodiazepine mis-filed
/// under "Other" must still be caught. Lists carry generics AND common US
/// brand names (clinical reference data, not personal info).
enum CNSDepressantClassifier {

    /// Benzodiazepines and Z-drugs share respiratory-depression risk and are
    /// deliberately mapped to the SAME class (and its 12 h window): treating
    /// an unfamiliar Z-drug as anything other than benzodiazepine-class would
    /// violate the "unknown = long-acting/fail-safe" spirit of spec §14.1.
    private static let benzodiazepineOrZDrugNames: Set<String> = [
        // Benzodiazepine generics
        "clonazepam", "alprazolam", "lorazepam", "diazepam",
        "temazepam", "midazolam", "chlordiazepoxide",
        // Benzodiazepine brands
        "xanax", "ativan", "klonopin", "valium", "restoril", "librium",
        // Z-drug generics
        "zolpidem", "zaleplon", "eszopiclone",
        // Z-drug brands
        "ambien", "lunesta", "sonata",
    ]

    private static let opioidNames: Set<String> = [
        // Generics
        "hydrocodone", "oxycodone", "morphine", "codeine", "tramadol",
        "fentanyl", "hydromorphone", "oxymorphone", "buprenorphine",
        "tapentadol", "meperidine",
        // Brands
        "vicodin", "norco", "lortab", "percocet", "percodan", "oxycontin",
        "ms contin", "dilaudid", "exalgo", "opana", "demerol", "suboxone",
    ]

    /// Substring markers for extended/sustained-release formulations,
    /// consulted ONLY after opioid name evidence already exists — a marker is
    /// never evidence that something is an opioid by itself ("discontinued"
    /// contains "contin"; "Wellbutrin SR" is not an opioid). Markers are
    /// pre-padded with the boundary whitespace they need to avoid matching
    /// mid-word (e.g. "la " must not fire on the "la" inside "Melatonin").
    private static let extendedReleaseMarkers = [" er", " xr", " sr", "extended", "contin", "la "]

    /// - Parameters:
    ///   - name: Medication name (free text, e.g. "Oxycodone ER 10mg").
    ///   - category: `MedicationDefinition.category` (free-form picker value).
    /// - Returns: The default CNS-depressant class, or nil if this medication
    ///   is not recognized as a CNS depressant.
    static func classify(name: String, category: String) -> CNSDepressantClass? {
        let lowercasedCategory = category.lowercased()
        if lowercasedCategory == "benzodiazepine" || lowercasedCategory == "z-drug" {
            return .benzodiazepine
        }

        // Padded so boundary markers (" er", "la ") also match names that
        // begin or end exactly at the marker, not just mid-string.
        let paddedName = " " + name.lowercased() + " "
        let byName = classifyByName(paddedName)

        if lowercasedCategory == "opioid" {
            // The user has told us this IS an opioid. Name evidence picks the
            // specific class when it can; otherwise default to `.opioidER`
            // (24 h window) rather than IR (8 h): spec §14.1 treats an
            // unknown formulation as long-acting — the fail-safe direction,
            // since an 8 h window on an actually-extended-release opioid
            // would drop monitoring during peak respiratory-depression risk.
            return byName ?? .opioidER
        }

        return byName
    }

    /// Word-boundary-tolerant substring classification over the lowercased,
    /// space-padded name. Order matters: methadone outranks the generic
    /// opioid list (72 h window), and opioids are checked before the benzo
    /// backstop.
    private static func classifyByName(_ paddedName: String) -> CNSDepressantClass? {
        if paddedName.contains("methadone") {
            return .methadoneOrUnknownLongActing
        }
        if opioidNames.contains(where: { paddedName.contains($0) }) {
            let isExtendedRelease = extendedReleaseMarkers.contains { paddedName.contains($0) }
            return isExtendedRelease ? .opioidER : .opioidIR
        }
        if benzodiazepineOrZDrugNames.contains(where: { paddedName.contains($0) }) {
            return .benzodiazepine
        }
        return nil
    }
}
