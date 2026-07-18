import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import AnxietyWatchKitMacros

final class SyncableMacroTests: XCTestCase {
    private let testMacros: [String: Macro.Type] = [
        "Syncable": SyncableMacro.self
    ]

    private static let regressionGuardMessage =
        "Bidirectional @Syncable type must implement encodeForSync() and init(fromSync:)"

    /// Expected DDL body, with continuation lines indented to match the
    /// 4-space member indentation of the expanded source.
    private func expectedDDL(table: String, pk: String = "id") -> String {
        func trigger(_ suffix: String, event: String, ref: String, operation: String) -> String {
            """
            CREATE TRIGGER trg_\(table)_syncable_\(suffix) AFTER \(event) ON \(table) BEGIN
              INSERT INTO _sync_log (table_name, row_pk, hlc_physical, hlc_logical, node_id, operation)
              SELECT '\(table)', CAST(\(ref).\(pk) AS TEXT),
                     json_extract(h, '$.pt'),
                     json_extract(h, '$.lc'),
                     unhex(json_extract(h, '$.n')),
                     '\(operation)'
                FROM (SELECT hlc_now_json() AS h)
                WHERE true
              ON CONFLICT(table_name, row_pk) DO UPDATE SET
                hlc_physical = excluded.hlc_physical,
                hlc_logical  = excluded.hlc_logical,
                node_id      = excluded.node_id,
                operation    = excluded.operation
              WHERE (excluded.hlc_physical, excluded.hlc_logical)
                  > (_sync_log.hlc_physical, _sync_log.hlc_logical);
            END;
            """
        }
        let raw = [
            trigger("ins", event: "INSERT", ref: "NEW", operation: "upsert"),
            trigger("upd", event: "UPDATE", ref: "NEW", operation: "upsert"),
            trigger("del", event: "DELETE", ref: "OLD", operation: "delete"),
        ].joined(separator: "\n")
        return raw.replacingOccurrences(of: "\n", with: "\n    ")
    }

    func testExpandsBidirectionalByDefault() {
        assertMacroExpansion(
            """
            @Syncable(tableName: "widgets")
            struct Widget {
                let id: Int
                func encodeForSync() -> [String: Int] { [:] }
                init(fromSync: [String: Int]) { self.id = 0 }
            }
            """,
            expandedSource: """
            struct Widget {
                let id: Int
                func encodeForSync() -> [String: Int] { [:] }
                init(fromSync: [String: Int]) { self.id = 0 }

                public static let syncDirection: SyncDirection = .bidirectional

                public static let syncTableName: String = "widgets"

                public static let syncTriggerDDL: String = \"\"\"
                \(expectedDDL(table: "widgets"))
                \"\"\"

                public static func registerForSync(_ registry: SyncRegistry) async {
                    await registry.register(Self.self)
                }
            }
            """,
            macros: testMacros
        )
    }

    func testMissingEncodeThrowsDiagnostic() {
        // EMAY-loss regression guard: bidirectional with only init(fromSync:).
        assertMacroExpansion(
            """
            @Syncable
            struct Widget {
                let id: Int
                init(fromSync: [String: Int]) { self.id = 0 }
            }
            """,
            expandedSource: """
            struct Widget {
                let id: Int
                init(fromSync: [String: Int]) { self.id = 0 }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: Self.regressionGuardMessage, line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    func testMissingInitThrowsDiagnostic() {
        // Symmetric: bidirectional with only encodeForSync().
        assertMacroExpansion(
            """
            @Syncable
            struct Widget {
                let id: Int
                func encodeForSync() -> [String: Int] { [:] }
            }
            """,
            expandedSource: """
            struct Widget {
                let id: Int
                func encodeForSync() -> [String: Int] { [:] }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: Self.regressionGuardMessage, line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    func testUpOnlyMissingEncodeThrowsDiagnostic() {
        // upOnly still uploads — encodeForSync() is mandatory.
        assertMacroExpansion(
            """
            @Syncable(direction: .upOnly)
            struct Widget {
                let id: Int
                init(fromSync: [String: Int]) { self.id = 0 }
            }
            """,
            expandedSource: """
            struct Widget {
                let id: Int
                init(fromSync: [String: Int]) { self.id = 0 }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "upOnly @Syncable type must implement encodeForSync()", line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    func testDownOnlyMissingInitThrowsDiagnostic() {
        // downOnly still materializes server rows — init(fromSync:) is mandatory.
        assertMacroExpansion(
            """
            @Syncable(direction: .downOnly)
            struct Widget {
                let id: Int
                func encodeForSync() -> [String: Int] { [:] }
            }
            """,
            expandedSource: """
            struct Widget {
                let id: Int
                func encodeForSync() -> [String: Int] { [:] }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "downOnly @Syncable type must implement init(fromSync:)", line: 1, column: 1)
            ],
            macros: testMacros
        )
    }

    func testCompositePrimaryKeyExpressionEmittedVerbatim() throws {
        let source: SourceFileSyntax = """
        @Syncable(tableName: "samples", primaryKeyExpression: "NEW.source || '-' || NEW.type || '-' || CAST(NEW.timestamp AS TEXT)")
        struct Sample {
            let source: Int
            func encodeForSync() -> [String: Int] { [:] }
            init(fromSync: [String: Int]) { self.source = 0 }
        }
        """

        guard let structDecl = source.statements.first?.item.as(StructDeclSyntax.self),
              let attribute = structDecl.attributes.first?.as(AttributeSyntax.self) else {
            return XCTFail("fixture parse failure")
        }

        let members: [DeclSyntax] = try SyncableMacro.expansion(
            of: attribute,
            providingMembersOf: structDecl,
            in: BasicMacroExpansionContext()
        )
        let ddl = try XCTUnwrap(members.map { $0.description }.first { $0.contains("syncTriggerDDL") })

        // INSERT + UPDATE triggers carry the caller's expression verbatim.
        XCTAssertTrue(ddl.contains("SELECT 'samples', NEW.source || '-' || NEW.type || '-' || CAST(NEW.timestamp AS TEXT),"))
        // DELETE trigger gets the NEW. → OLD. rewrite.
        XCTAssertTrue(ddl.contains("SELECT 'samples', OLD.source || '-' || OLD.type || '-' || CAST(OLD.timestamp AS TEXT),"))
        // The single-column CAST default must NOT appear.
        XCTAssertFalse(ddl.contains("CAST(NEW.id AS TEXT)"))
    }

    func testDirectionUpOnlyRelaxesRequirement() {
        // upOnly: no init(fromSync:) required — no diagnostic.
        assertMacroExpansion(
            """
            @Syncable(direction: .upOnly)
            struct LegacyTelemetry {
                let id: Int
                func encodeForSync() -> [String: Int] { [:] }
            }
            """,
            expandedSource: """
            struct LegacyTelemetry {
                let id: Int
                func encodeForSync() -> [String: Int] { [:] }

                public static let syncDirection: SyncDirection = .upOnly

                public static let syncTableName: String = "legacy_telemetry"

                public static let syncTriggerDDL: String = \"\"\"
                \(expectedDDL(table: "legacy_telemetry"))
                \"\"\"

                public static func registerForSync(_ registry: SyncRegistry) async {
                    await registry.register(Self.self)
                }
            }
            """,
            macros: testMacros
        )
    }

    func testTriggerDDLUsesSubqueryPattern() throws {
        // Expand directly and assert the load-bearing subquery pattern is
        // present in the emitted DDL — the T13/Opus contract that guarantees
        // one HLC mint per row regardless of SQLite expression evaluation order.
        let source: SourceFileSyntax = """
        @Syncable(tableName: "samples_x", primaryKey: "sample_id")
        struct SampleX {
            let sample_id: Int
            func encodeForSync() -> [String: Int] { [:] }
            init(fromSync: [String: Int]) { self.sample_id = 0 }
        }
        """

        guard let structDecl = source.statements.first?.item.as(StructDeclSyntax.self),
              let attribute = structDecl.attributes.first?.as(AttributeSyntax.self) else {
            return XCTFail("fixture parse failure")
        }

        let context = BasicMacroExpansionContext()
        let members: [DeclSyntax] = try SyncableMacro.expansion(
            of: attribute,
            providingMembersOf: structDecl,
            in: context
        )

        let ddlMember = members.map { $0.description }.first { $0.contains("syncTriggerDDL") }
        let ddl = try XCTUnwrap(ddlMember)

        // The mandatory pattern, once per trigger (ins/upd/del).
        let occurrences = ddl.components(separatedBy: "FROM (SELECT hlc_now_json() AS h)").count - 1
        XCTAssertEqual(occurrences, 3, "every trigger must evaluate hlc_now_json() via the scalar subquery")

        // Never the corrupting direct multi-call form.
        XCTAssertFalse(ddl.contains("json_extract(hlc_now_json()"),
                       "direct hlc_now_json() multi-calls mint mismatched stamps — forbidden")

        // Custom primary key respected.
        XCTAssertTrue(ddl.contains("CAST(NEW.sample_id AS TEXT)"))
        XCTAssertTrue(ddl.contains("CAST(OLD.sample_id AS TEXT)"))
    }

    func testLowercasedSnake() {
        XCTAssertEqual(SyncableMacro.lowercasedSnake("Widget"), "widget")
        XCTAssertEqual(SyncableMacro.lowercasedSnake("SampleTombstone"), "sample_tombstone")
        XCTAssertEqual(SyncableMacro.lowercasedSnake("HRVReading"), "h_r_v_reading")
    }
}
