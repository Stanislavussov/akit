import Foundation
import Testing
import AKitFlows
@testable import AKitRender

/// The review pack quotes the runner (FlowRender.reviewExcerpts) and repeats its fixed sentences
/// (FlowReviewExport): both must follow the runner's source.
struct FlowReviewExcerptTests {
    @Test func everyExcerptIsFound() {
        #expect(FlowRender.reviewExcerpts.count == 6)
        for excerpt in FlowRender.reviewExcerpts {
            #expect(!excerpt.code.isEmpty, "\(excerpt.title) is gone from \(excerpt.file)")
        }
        let context = FlowRender.reviewExcerpts.first { $0.title == "A handoff in the next prompt" }?.code ?? ""
        for name in ["handoffForPrompt", "NOTES_IN_PROMPT", "PRECEDENCE", "earlierSteps", "planHandoff"] {
            #expect(context.contains(name), "\(name)")
        }
        // A declaration comes with its doc comment and ends at its closing brace.
        let schema = FlowRender.reviewExcerpts[0].code
        #expect(schema.hasPrefix("/** Plain JSON Schema") && schema.contains("export const HANDOFF_PARAMETERS") && schema.hasSuffix("} as const;"), "\(schema.prefix(200)) … \(schema.suffix(100))")
        #expect(FlowRender.declaration("function prompt(", in: FlowTemplateSources.akit_flow_ts)?.hasSuffix("\n}") == true)
    }

    @Test func theExportsSentencesAreTheRunners() {
        for phrase in FlowReviewExport.runnerPhrases {
            #expect(FlowTemplateSources.akit_flow_ts.contains(phrase), "akit-flow.ts no longer says: \(phrase)")
        }
    }
}
