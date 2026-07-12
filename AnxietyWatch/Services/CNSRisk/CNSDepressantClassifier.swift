import Foundation

/// Pure category/name → `CNSDepressantClass` default classifier. This is a
/// DEFAULT ONLY — `MedicationDefinition.cnsDepressantClass` (set from a
/// user-editable picker) is the source of truth that arms overnight
/// respiratory-depression monitoring. A false negative here (missing a CNS
/// depressant) is worse than a false positive, so every rule below is
/// deliberately generous: category is checked first (the most reliable
/// signal, since it's an explicit picker value), then name-based word lists
/// run as a backstop REGARDLESS of category — a benzodiazepine mis-filed
/// under "Other" must still be caught.
enum CNSDepressantClassifier {

    /// Benzodiazepines and Z-drugs share respiratory-depression risk and are
    /// deliberately mapped to the SAME class (and its 12 h window): treating
    /// an unfamiliar Z-drug as anything other than benzodiazepine-class would
    /// violate the "unknown = long-acting/fail-safe" spirit of spec §14.1.
    private static let benzodiazepineOrZDrugNames: Set<String> = [
        "clonazepam", "alprazolam", "lorazepam", "diazepam",
        "temazepam", "midazolam", "chlordiazepoxide",
        "zolpidem", "zaleplon", "eszopiclone",
    ]

    private static let opioidNames: Set<String> = [
        "hydrocodone", "oxycodone", "morphine", "codeine", "tramadol",
        "fentanyl", "hydromorphone", "oxymorphone", "buprenorphine", "tapentadol",
    ]

    /// Substring markers for extended/sustained-release formulations. Markers
    /// are pre-padded with the boundary whitespace they need to avoid
    /// matching mid-word (e.g. "la " must not fire on "Sertraline").
    /// "contin" is special-cased below: unlike the other markers (which are
    /// generic release-mechanism suffixes shared with non-opioid drugs, e.g.
    /// "Effexor XR", "Wellbutrin SR"), Purdue's "Contin" line names ONLY
    /// opioid extended-release products (OxyContin, MS Contin) — so its
    /// presence alone is treated as sufficient evidence of an opioid, even
    /// when the specific molecule name isn't in `opioidNames` (e.g. "MS
    /// Contin" never spells out "morphine").
    private static let extendedReleaseMarkers = [" er", " xr", " sr", "extended", "contin", "la "]
    private static let opioidOnlyMarker = "contin"

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

        if paddedName.contains("methadone") {
            return .methadoneOrUnknownLongActing
        }

        let hasExtendedReleaseMarker = extendedReleaseMarkers.contains { paddedName.contains($0) }
        let hasOpioidName = opioidNames.contains { paddedName.contains($0) }
        if hasOpioidName || paddedName.contains(opioidOnlyMarker) {
            return hasExtendedReleaseMarker ? .opioidER : .opioidIR
        }

        if benzodiazepineOrZDrugNames.contains(where: { paddedName.contains($0) }) {
            return .benzodiazepine
        }

        return nil
    }
}
