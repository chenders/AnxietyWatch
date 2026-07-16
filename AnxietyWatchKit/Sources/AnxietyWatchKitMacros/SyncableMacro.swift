import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Diagnostic error surfaced at the `@Syncable` attribute site.
struct SyncableMacroError: Error, CustomStringConvertible {
    let description: String
}

/// `@Syncable` member macro (Spec §2.4).
///
/// Three purposes:
/// 1. COMPILE-TIME ENFORCEMENT (the EMAY-loss regression guard): a
///    `.bidirectional` type must implement BOTH `encodeForSync()` and
///    `init(fromSync:)` or expansion fails with a diagnostic.
/// 2. Emits `syncTriggerDDL` using the MANDATORY hlc_now_json() scalar-subquery
///    pattern (see HLC.registerUDFs T13/Opus review — direct multi-calls mint
///    mismatched stamps → silent causal corruption).
/// 3. Emits `registerForSync(_:)` so SyncCoordinator.bootstrap() can collect
///    all syncable types via SyncRegistry.
public struct SyncableMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Attachment target: struct or class only.
        let typeName: String
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            typeName = structDecl.name.text
        } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            typeName = classDecl.name.text
        } else {
            throw SyncableMacroError(description: "@Syncable can only be attached to a struct or class")
        }

        // Nested @Syncable types are not supported (flatten at schema layer).
        for member in declaration.memberBlock.members {
            let attrs: AttributeListSyntax?
            if let s = member.decl.as(StructDeclSyntax.self) {
                attrs = s.attributes
            } else if let c = member.decl.as(ClassDeclSyntax.self) {
                attrs = c.attributes
            } else {
                attrs = nil
            }
            if let attrs, attrs.contains(where: { attr in
                attr.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Syncable"
            }) {
                throw SyncableMacroError(description: "Nested @Syncable types are not supported — flatten at the schema layer")
            }
        }

        // Parse attribute arguments.
        var direction = "bidirectional"
        var tableName: String? = nil
        var primaryKey = "id"
        var primaryKeyExpression: String? = nil

        if let arguments = node.arguments?.as(LabeledExprListSyntax.self) {
            for argument in arguments {
                switch argument.label?.text {
                case "direction":
                    if let member = argument.expression.as(MemberAccessExprSyntax.self) {
                        direction = member.declName.baseName.text
                    }
                case "tableName":
                    if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
                        tableName = literal.segments.trimmedDescription
                    }
                    // `nil` literal → keep default
                case "primaryKey":
                    if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
                        primaryKey = literal.segments.trimmedDescription
                    }
                case "primaryKeyExpression":
                    if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
                        primaryKeyExpression = literal.segments.trimmedDescription
                    }
                    // `nil` literal → keep default (single-column CAST)
                default:
                    break
                }
            }
        }

        let resolvedTableName = tableName ?? Self.lowercasedSnake(typeName)

        // COMPILE-TIME ENFORCEMENT — the EMAY-loss regression guard.
        // Every direction has a hard requirement:
        //   .bidirectional → BOTH encodeForSync() (upload) and init(fromSync:) (restore)
        //   .upOnly        → encodeForSync() (it still uploads!)
        //   .downOnly      → init(fromSync:) (it still materializes server rows!)
        // Missing pieces mean data is silently dropped in one direction — the
        // exact silent-omission class this macro exists to close.
        var hasEncode = false
        var hasInit = false

        for member in declaration.memberBlock.members {
            if let fn = member.decl.as(FunctionDeclSyntax.self), fn.name.text == "encodeForSync" {
                hasEncode = true
            }
            if let initializer = member.decl.as(InitializerDeclSyntax.self),
               initializer.signature.parameterClause.parameters.first?.firstName.text == "fromSync" {
                hasInit = true
            }
        }

        switch direction {
        case "bidirectional":
            if !hasEncode || !hasInit {
                throw SyncableMacroError(
                    description: "Bidirectional @Syncable type must implement encodeForSync() and init(fromSync:)"
                )
            }
        case "upOnly":
            if !hasEncode {
                throw SyncableMacroError(
                    description: "upOnly @Syncable type must implement encodeForSync()"
                )
            }
        case "downOnly":
            if !hasInit {
                throw SyncableMacroError(
                    description: "downOnly @Syncable type must implement init(fromSync:)"
                )
            }
        default:
            throw SyncableMacroError(description: "Unknown @Syncable direction .\(direction)")
        }

        // Row-PK expressions. Default: single-column CAST. Composite keys:
        // caller supplies primaryKeyExpression verbatim (NEW.-based); the
        // DELETE trigger rewrites NEW. → OLD. since NEW is unavailable there.
        let pkNew: String
        let pkOld: String
        if let expr = primaryKeyExpression {
            pkNew = expr
            pkOld = expr.replacingOccurrences(of: "NEW.", with: "OLD.")
        } else {
            pkNew = "CAST(NEW.\(primaryKey) AS TEXT)"
            pkOld = "CAST(OLD.\(primaryKey) AS TEXT)"
        }

        // Trigger DDL. Two load-bearing patterns:
        // 1. MANDATORY scalar subquery: hlc_now_json() is evaluated exactly
        //    once per row inside `FROM (SELECT ... AS h)`; all three fields
        //    are extracted from the SAME stamp regardless of SQLite's
        //    expression evaluation order. NEVER emit direct multi-calls.
        // 2. HLC-guarded upsert (same semantic as SyncLogStore.upsert):
        //    _sync_log's PK is (table_name, row_pk), so the first UPDATE of
        //    any row would otherwise UNIQUE-collide and roll back the whole
        //    app write. ON CONFLICT coalesces to the latest operation, and
        //    the WHERE guard prevents out-of-order writes from clobbering
        //    newer HLCs. `WHERE true` is required by SQLite's grammar for
        //    INSERT..SELECT..ON CONFLICT.
        func trigger(_ suffix: String, event: String, pkExpr: String, operation: String) -> String {
            """
            CREATE TRIGGER trg_\(resolvedTableName)_syncable_\(suffix) AFTER \(event) ON \(resolvedTableName) BEGIN
              INSERT INTO _sync_log (table_name, row_pk, hlc_physical, hlc_logical, node_id, operation)
              SELECT '\(resolvedTableName)', \(pkExpr),
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

        let ddl = [
            trigger("ins", event: "INSERT", pkExpr: pkNew, operation: "upsert"),
            trigger("upd", event: "UPDATE", pkExpr: pkNew, operation: "upsert"),
            trigger("del", event: "DELETE", pkExpr: pkOld, operation: "delete"),
        ].joined(separator: "\n")

        let directionDecl: DeclSyntax = "public static let syncDirection: SyncDirection = .\(raw: direction)"
        let tableNameDecl: DeclSyntax = "public static let syncTableName: String = \(literal: resolvedTableName)"
        let ddlDecl: DeclSyntax = #"""
            public static let syncTriggerDDL: String = """
            \#(raw: ddl)
            """
            """#
        let registerDecl: DeclSyntax = """
            public static func registerForSync(_ registry: SyncRegistry) async {
                await registry.register(Self.self)
            }
            """

        return [directionDecl, tableNameDecl, ddlDecl, registerDecl]
    }

    /// "SampleTombstone" → "sample_tombstone".
    static func lowercasedSnake(_ name: String) -> String {
        var out = ""
        for (i, ch) in name.enumerated() {
            if ch.isUppercase {
                if i > 0 { out.append("_") }
                out.append(contentsOf: ch.lowercased())
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

@main
struct AnxietyWatchKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SyncableMacro.self
    ]
}
