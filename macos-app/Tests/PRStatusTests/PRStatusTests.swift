import Foundation
import Testing
@testable import PRReviews

private func snapshot(
    state: String = "OPEN",
    isDraft: Bool = false,
    review: String? = "REVIEW_REQUIRED",
    checks: String? = "SUCCESS",
    mergeState: String? = "BLOCKED",
    mergeable: String? = "MERGEABLE",
    inQueue: Bool = false,
    position: Int? = nil,
    autoMerge: Bool = false
) -> PRSnapshot {
    PRSnapshot(
        state: state, isDraft: isDraft, reviewDecision: review, checks: checks,
        mergeState: mergeState, mergeable: mergeable, inQueue: inQueue,
        queuePosition: position, autoMerge: autoMerge
    )
}

private func pr(
    _ s: PRSnapshot,
    approvers: [String] = [],
    pending: Int = 0,
    checks: [CheckItem] = [],
    hasMergeQueue: Bool = false
) -> MyPullRequest {
    MyPullRequest(
        nodeID: "PR_1", url: URL(string: "https://github.com/o/r/pull/1")!, number: 1, title: "t", repo: "o/r",
        createdAt: Date(), closedAt: nil,
        reviewers: approvers.map { Reviewer(login: $0, name: nil, avatarURL: nil, isTeam: false, profileURL: nil, state: .approved) }
            + (0..<pending).map { Reviewer(login: "p\($0)", name: nil, avatarURL: nil, isTeam: false, profileURL: nil, state: .pending) },
        linear: nil, checks: checks, hasMergeQueue: hasMergeQueue, snapshot: s
    )
}

private func check(_ name: String, _ state: CheckItem.State) -> CheckItem {
    CheckItem(name: name, state: state, url: nil)
}

@Suite struct Headlines {
    @Test func mergedBeatsEverything() {
        #expect(PRStatus.headline(snapshot(state: "MERGED", checks: "FAILURE")) == .merged)
    }

    @Test func draftBeatsFailingChecks() {
        #expect(PRStatus.headline(snapshot(isDraft: true, checks: "FAILURE")) == .draft)
    }

    @Test func queueShowsPosition() {
        let headline = PRStatus.headline(snapshot(inQueue: true, position: 3))
        #expect(headline == .inQueue(position: 3))
        #expect(headline.text == "In merge queue #3")
    }

    @Test func conflictsBeatFailingChecks() {
        #expect(PRStatus.headline(snapshot(checks: "FAILURE", mergeable: "CONFLICTING")) == .conflicts)
    }

    @Test func approvedWithFailingChecksIsFailing() {
        #expect(PRStatus.headline(snapshot(review: "APPROVED", checks: "FAILURE", mergeState: "UNSTABLE")) == .checksFailing)
    }

    @Test func cleanIsReady() {
        #expect(PRStatus.headline(snapshot(review: "APPROVED", mergeState: "CLEAN")) == .readyToMerge)
    }

    @Test func approvedGreenMergeableIsReadyEvenWithoutMergeState() {
        #expect(PRStatus.headline(snapshot(review: "APPROVED", mergeState: nil)) == .readyToMerge)
    }

    @Test func behindBase() {
        #expect(PRStatus.headline(snapshot(review: "APPROVED", mergeState: "BEHIND")) == .behind)
    }

    @Test func runningChecksBeforeWaitingForReview() {
        #expect(PRStatus.headline(snapshot(checks: "PENDING")) == .checksRunning)
        #expect(PRStatus.headline(snapshot()) == .waitingForReview)
    }
}

@Suite struct NeedsAction {
    @Test func failingChecksNeedAction() {
        #expect(PRStatus.needsAction(snapshot(checks: "FAILURE")))
    }

    @Test func readyNeedsActionUnlessAutoMerge() {
        #expect(PRStatus.needsAction(snapshot(review: "APPROVED", mergeState: "CLEAN")))
        #expect(!PRStatus.needsAction(snapshot(review: "APPROVED", mergeState: "CLEAN", autoMerge: true)))
    }

    @Test func draftsAndWaitingDont() {
        #expect(!PRStatus.needsAction(snapshot(isDraft: true, checks: "FAILURE")))
        #expect(!PRStatus.needsAction(snapshot()))
        #expect(!PRStatus.needsAction(snapshot(inQueue: true)))
    }
}

@Suite struct Transitions {
    @Test func approval() {
        #expect(PRStatus.transition(old: snapshot(), new: snapshot(review: "APPROVED")) == .approved)
    }

    @Test func approvalThatMakesItReadyReportsReady() {
        let new = snapshot(review: "APPROVED", mergeState: "CLEAN")
        #expect(PRStatus.transition(old: snapshot(), new: new) == .readyToMerge)
    }

    @Test func checksFailing() {
        #expect(PRStatus.transition(old: snapshot(checks: "PENDING"), new: snapshot(checks: "FAILURE")) == .checksFailed)
        #expect(PRStatus.transition(old: snapshot(checks: "FAILURE"), new: snapshot(checks: "ERROR")) == nil)
    }

    @Test func queueInAndOut() {
        #expect(PRStatus.transition(old: snapshot(), new: snapshot(inQueue: true)) == .enteredQueue)
        #expect(PRStatus.transition(old: snapshot(inQueue: true), new: snapshot()) == .leftQueue)
    }

    @Test func mergedFromQueueIsMergedNotLeftQueue() {
        #expect(PRStatus.transition(old: snapshot(inQueue: true), new: snapshot(state: "MERGED")) == .merged)
    }

    @Test func noChangeNoBanner() {
        #expect(PRStatus.transition(old: snapshot(), new: snapshot()) == nil)
    }

    @Test func draftsStayQuiet() {
        #expect(PRStatus.transition(old: snapshot(isDraft: true), new: snapshot(isDraft: true, review: "APPROVED")) == nil)
    }

    @Test func unknownMergeStateKeepsPreviousSoReadyDoesNotRefire() {
        let ready = snapshot(review: "APPROVED", mergeState: "CLEAN")
        let flapped = snapshot(review: "APPROVED", checks: "PENDING", mergeState: "UNKNOWN", mergeable: "UNKNOWN")
            .resolvingUnknowns(from: ready)
        #expect(flapped.mergeState == "CLEAN")
        #expect(flapped.mergeable == "MERGEABLE")
    }
}

@Suite struct Cells {
    @Test func reviewShowsApprovalCountAndPending() {
        let cell = PRStatus.reviewCell(pr(snapshot(review: "APPROVED"), approvers: ["ab"], pending: 1))
        #expect(cell == StatusCell(label: "Review", value: "1 ✓ · 1 pending", tone: .green))
    }

    @Test func changesRequestedWinsOverApprovals() {
        let cell = PRStatus.reviewCell(pr(snapshot(review: "CHANGES_REQUESTED"), approvers: ["ab"]))
        #expect(cell.value == "Changes requested")
        #expect(cell.tone == .red)
    }

    @Test func checksShowPassedOutOfTotal() {
        let cell = PRStatus.checksCell(pr(snapshot(), checks: [check("a", .failing), check("b", .running), check("c", .passing)]))
        #expect(cell == StatusCell(label: "Checks", value: "1/3", tone: .red))
    }

    @Test func allPassingIsGreen() {
        #expect(PRStatus.checksCell(pr(snapshot(), checks: [check("a", .passing)])).tone == .green)
    }

    @Test func mergeCellQueuePosition() {
        #expect(PRStatus.mergeCell(pr(snapshot(inQueue: true, position: 2))).value == "#2 in queue")
    }

    @Test func unstableIsMergeable() {
        #expect(PRStatus.mergeCell(pr(snapshot(mergeState: "UNSTABLE"))).value == "Mergeable")
    }
}

@Suite struct Groups {
    @Test func grouping() {
        #expect(PRStatus.group(snapshot(checks: "FAILURE")) == .attention)
        #expect(PRStatus.group(snapshot(inQueue: true)) == .queue)
        #expect(PRStatus.group(snapshot()) == .waiting)
        #expect(PRStatus.group(snapshot(isDraft: true, checks: "FAILURE")) == .drafts)
        #expect(PRStatus.group(snapshot(state: "MERGED")) == .closed)
    }

    @Test func titleDropsTrailingLinearKey() {
        let base = pr(snapshot())
        let withKey = MyPullRequest(
            nodeID: base.nodeID, url: base.url, number: 1, title: "Studio: Survey Prompt #GRO-692", repo: "o/r",
            createdAt: Date(), closedAt: nil, reviewers: [],
            linear: LinearIssue(key: "GRO-692", url: nil), checks: [], hasMergeQueue: false, snapshot: base.snapshot
        )
        #expect(PRStatus.displayTitle(withKey) == "Studio: Survey Prompt")
    }
}

@Suite struct Checks {
    @Test func checkRunClassification() {
        #expect(CheckItem.State.from(checkRunStatus: "IN_PROGRESS", conclusion: nil) == .running)
        #expect(CheckItem.State.from(checkRunStatus: "COMPLETED", conclusion: "FAILURE") == .failing)
        #expect(CheckItem.State.from(checkRunStatus: "COMPLETED", conclusion: "SKIPPED") == .passing)
        #expect(CheckItem.State.from(statusState: "ERROR") == .failing)
    }

    @Test func duplicatesKeepWorstState() {
        let deduped = CheckItem.deduplicated([check("gate", .passing), check("gate", .failing), check("a", .passing)])
        #expect(deduped == [check("a", .passing), check("gate", .failing)])
    }
}

@Suite struct Linear {
    @Test func prefersBodyURL() {
        let body = "Fixes [GRO-692](https://linear.app/synthesia-io/issue/GRO-692/launch-sessions) for real"
        let issue = LinearIssue.find(body: body, title: "Something #GRO-1")
        #expect(issue?.key == "GRO-692")
        #expect(issue?.url?.absoluteString == "https://linear.app/synthesia-io/issue/GRO-692/launch-sessions")
    }

    @Test func fallsBackToTitleKeyWithoutLink() {
        let issue = LinearIssue.find(body: "", title: "Studio: Gate cards #GRO-558")
        #expect(issue == LinearIssue(key: "GRO-558", url: nil))
    }

    @Test func noneFound() {
        #expect(LinearIssue.find(body: "nothing", title: "plain title") == nil)
    }
}

@Suite struct Queue {
    @Test func enqueueOnlyWhenRepoHasQueueAndPRIsMergeable() {
        #expect(PRStatus.canEnqueue(pr(snapshot(mergeState: "CLEAN"), hasMergeQueue: true)))
        #expect(PRStatus.canEnqueue(pr(snapshot(mergeState: "UNSTABLE"), hasMergeQueue: true)))
        #expect(!PRStatus.canEnqueue(pr(snapshot(mergeState: "CLEAN"), hasMergeQueue: false)))
        #expect(!PRStatus.canEnqueue(pr(snapshot(mergeState: "BLOCKED"), hasMergeQueue: true)))
        #expect(!PRStatus.canEnqueue(pr(snapshot(isDraft: true, mergeState: "CLEAN"), hasMergeQueue: true)))
    }

    @Test func dequeueOnlyWhileQueued() {
        #expect(PRStatus.canDequeue(pr(snapshot(inQueue: true))))
        #expect(!PRStatus.canDequeue(pr(snapshot())))
    }
}

@Suite struct Away {
    @Test func pausesOnFirstReasonAndResumesWhenAllClear() {
        var reasons = AwayReasons()
        let sleepFlips = reasons.set(.systemAsleep, true)
        let lockFlips = reasons.set(.screenLocked, true)
        let wakeFlips = reasons.set(.systemAsleep, false)
        let stillAway = reasons.isAway
        let unlockFlips = reasons.set(.screenLocked, false)
        #expect(sleepFlips && !lockFlips && !wakeFlips && stillAway && unlockFlips)
        #expect(!reasons.isAway)
    }

    @Test func repeatedEventsDontFlip() {
        var reasons = AwayReasons()
        let unlockWhileHere = reasons.set(.screenLocked, false)
        let lock = reasons.set(.screenLocked, true)
        let lockAgain = reasons.set(.screenLocked, true)
        #expect(!unlockWhileHere && lock && !lockAgain)
    }
}
