import Foundation

/// Registry of anxiety-relevant lab tests identified by LOINC codes.
/// Maps clinical lab results from FHIR records to tests we track.
enum LabTestRegistry {

    enum TestCategory: String, CaseIterable, Identifiable, Codable {
        case thyroid = "Thyroid"
        case stressHormones = "Stress Hormones"
        case nutritional = "Nutritional"
        case metabolic = "Metabolic"
        case inflammatory = "Inflammatory"

        var id: String { rawValue }
    }

    struct TestDefinition: Sendable {
        let loincCode: String
        let displayName: String
        let shortName: String
        let unit: String
        let normalRangeLow: Double
        let normalRangeHigh: Double
        let category: TestCategory
        /// Why this test matters for anxiety tracking
        let rationale: String
    }

    // MARK: - Tracked Tests

    static let trackedTests: [String: TestDefinition] = {
        var map = [String: TestDefinition]()
        for def in allDefinitions {
            map[def.loincCode] = def
        }
        return map
    }()

    private static let allDefinitions: [TestDefinition] = [
        // Thyroid
        TestDefinition(
            loincCode: "3016-3", displayName: "Thyroid Stimulating Hormone", shortName: "TSH",
            unit: "mIU/L", normalRangeLow: 0.4, normalRangeHigh: 4.0,
            category: .thyroid,
            rationale: "Thyroid dysfunction mimics anxiety — hyperthyroidism causes palpitations, tremor, and panic-like symptoms"
        ),
        TestDefinition(
            loincCode: "3024-7", displayName: "Free Thyroxine", shortName: "Free T4",
            unit: "ng/dL", normalRangeLow: 0.8, normalRangeHigh: 1.8,
            category: .thyroid,
            rationale: "Active thyroid hormone level; elevated Free T4 directly drives anxiety symptoms"
        ),
        TestDefinition(
            loincCode: "5765-2", displayName: "TPO Antibodies", shortName: "TPO Ab",
            unit: "IU/mL", normalRangeLow: 0, normalRangeHigh: 35,
            category: .thyroid,
            rationale: "Autoimmune thyroiditis (Hashimoto's) causes thyroid fluctuations that cycle through anxiety-producing hyperthyroid phases"
        ),

        // Stress Hormones
        TestDefinition(
            loincCode: "2143-6", displayName: "Cortisol (AM)", shortName: "Cortisol",
            unit: "mcg/dL", normalRangeLow: 5, normalRangeHigh: 25,
            category: .stressHormones,
            rationale: "Primary stress hormone — chronically elevated cortisol sustains the fight-or-flight state underlying anxiety"
        ),

        // Nutritional
        TestDefinition(
            loincCode: "14979-9", displayName: "Vitamin D, 25-Hydroxy", shortName: "Vitamin D",
            unit: "ng/mL", normalRangeLow: 30, normalRangeHigh: 100,
            category: .nutritional,
            rationale: "Vitamin D deficiency is associated with increased anxiety; receptors exist throughout the brain"
        ),
        TestDefinition(
            loincCode: "2132-9", displayName: "Vitamin B12", shortName: "B12",
            unit: "pg/mL", normalRangeLow: 200, normalRangeHigh: 900,
            category: .nutritional,
            rationale: "B12 is essential for neurological function; deficiency causes anxiety, fatigue, and neuropathy"
        ),
        TestDefinition(
            loincCode: "2601-3", displayName: "Magnesium", shortName: "Mg",
            unit: "mg/dL", normalRangeLow: 1.7, normalRangeHigh: 2.2,
            category: .nutritional,
            rationale: "Magnesium is a cofactor for GABA and serotonin — low levels increase neuronal excitability and anxiety"
        ),
        TestDefinition(
            loincCode: "2276-4", displayName: "Ferritin", shortName: "Ferritin",
            unit: "ng/mL", normalRangeLow: 30, normalRangeHigh: 300,
            category: .nutritional,
            rationale: "Iron stores affect dopamine synthesis; low ferritin is linked to restlessness and anxiety"
        ),

        // Metabolic
        TestDefinition(
            loincCode: "2345-7", displayName: "Fasting Glucose", shortName: "Glucose",
            unit: "mg/dL", normalRangeLow: 70, normalRangeHigh: 100,
            category: .metabolic,
            rationale: "Hypoglycemia triggers adrenaline release, causing panic-like symptoms; hyperglycemia causes fatigue and brain fog"
        ),
        TestDefinition(
            loincCode: "4548-4", displayName: "Hemoglobin A1c", shortName: "HbA1c",
            unit: "%", normalRangeLow: 0, normalRangeHigh: 5.7,
            category: .metabolic,
            rationale: "Long-term glucose control; poor glycemic control correlates with higher anxiety prevalence"
        ),

        // Inflammatory
        TestDefinition(
            loincCode: "30522-7", displayName: "High-Sensitivity CRP", shortName: "hs-CRP",
            unit: "mg/L", normalRangeLow: 0, normalRangeHigh: 3.0,
            category: .inflammatory,
            rationale: "Systemic inflammation marker; neuroinflammation is increasingly linked to anxiety disorders"
        ),
        TestDefinition(
            loincCode: "6690-2", displayName: "White Blood Cell Count", shortName: "WBC",
            unit: "K/uL", normalRangeLow: 4.5, normalRangeHigh: 11.0,
            category: .inflammatory,
            rationale: "Elevated WBC suggests infection or inflammation, both of which can exacerbate anxiety"
        ),
    ]

    // MARK: - Lookup Helpers

    static func isTracked(_ loincCode: String) -> Bool {
        trackedTests[loincCode] != nil
    }

    static func definition(for loincCode: String) -> TestDefinition? {
        trackedTests[loincCode]
    }

    static func definitions(in category: TestCategory) -> [TestDefinition] {
        allDefinitions.filter { $0.category == category }
    }

    // MARK: - Reference-range resolution (F-008)

    /// The reference range that can be trusted for `result`, or nil when
    /// none can.
    ///
    /// Precedence:
    /// 1. The lab's own FHIR reference range — always correct in the lab's
    ///    reported unit, whatever that unit is.
    /// 2. The registry's fixed-unit range — ONLY when the result's reported
    ///    unit matches the registry unit. Cross-institution labs report the
    ///    same LOINC in different units (mmol/L vs mg/dL, pmol/L vs ng/dL);
    ///    silently applying the registry's mg/dL bounds to a mmol/L value
    ///    flags a clinically normal result as LOW/HIGH on screen and in the
    ///    clinician PDF (F-008). No trusted range → no flag; callers must
    ///    render a neutral status rather than a wrong one.
    ///
    /// A partially-supplied FHIR range (one bound) is completed from the
    /// registry only when the units match; otherwise only the lab-supplied
    /// bound is honored, with the missing side left unbounded.
    static func applicableRange(for result: ClinicalLabResult) -> (low: Double?, high: Double?)? {
        let fhirLow = result.referenceRangeLow
        let fhirHigh = result.referenceRangeHigh
        if fhirLow != nil || fhirHigh != nil {
            guard let def = definition(for: result.loincCode),
                  unitsAreCompatible(result.unit, def.unit) else {
                // Honor whatever the lab supplied; don't backfill the
                // missing bound from a registry range in a different unit.
                return (fhirLow, fhirHigh)
            }
            return (fhirLow ?? def.normalRangeLow, fhirHigh ?? def.normalRangeHigh)
        }
        guard let def = definition(for: result.loincCode),
              unitsAreCompatible(result.unit, def.unit) else {
            return nil
        }
        return (def.normalRangeLow, def.normalRangeHigh)
    }

    /// Case-insensitive unit comparison over a small normalization that
    /// collapses the common synonym spellings labs actually emit:
    /// µ ↔ u ↔ mc (micro), UCUM powers (10*3, 10^3) ↔ K, stray whitespace.
    /// Deliberately does NOT attempt conversions (mmol/L → mg/dL is
    /// analyte-specific) — incompatible units mean "no trusted range",
    /// never "convert and hope".
    static func unitsAreCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let l = normalizedUnit(lhs)
        let r = normalizedUnit(rhs)
        guard !l.isEmpty, !r.isEmpty else { return false }
        return l == r
    }

    private static func normalizedUnit(_ unit: String) -> String {
        unit.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "mc", with: "u")   // mcg → ug
            .replacingOccurrences(of: "10*3", with: "k") // UCUM thousands
            .replacingOccurrences(of: "10^3", with: "k")
    }
}
