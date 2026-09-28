// Written by scripts/gen-tests.py. Don't edit by hand; add tests to a *Tests.swift file and rerun it.
import Foundation

@main struct TestRunner {
    static func main() async {
        // Keep every test away from the real ~/Library/Application Support/Daisy.
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        setenv("DAISY_DATA_DIR", sandbox.path, 1)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let started = Date()
        var count = 0
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try await suite.testIndependentAdaptersComposeWithoutEngineChanges()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testIndependentAdaptersComposeWithoutEngineChanges")
        } catch { fail("testIndependentAdaptersComposeWithoutEngineChanges: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try await suite.testPolicyAndSchemaCannotBeOverriddenByArguments()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testPolicyAndSchemaCannotBeOverriddenByArguments")
        } catch { fail("testPolicyAndSchemaCannotBeOverriddenByArguments: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try await suite.testDuplicateCallsReuseReceiptAndStopLoop()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDuplicateCallsReuseReceiptAndStopLoop")
        } catch { fail("testDuplicateCallsReuseReceiptAndStopLoop: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try await suite.testCancellationDoesNotReportSuccess()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testCancellationDoesNotReportSuccess")
        } catch { fail("testCancellationDoesNotReportSuccess: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try await suite.testReadFileRequiresGrantAndReference()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testReadFileRequiresGrantAndReference")
        } catch { fail("testReadFileRequiresGrantAndReference: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try suite.testArithmeticAndNestedJSONValidation()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testArithmeticAndNestedJSONValidation")
        } catch { fail("testArithmeticAndNestedJSONValidation: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try suite.testDuplicateRegistrationRejected()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDuplicateRegistrationRejected")
        } catch { fail("testDuplicateRegistrationRejected: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try await suite.testReadFileHandlesPDF()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testReadFileHandlesPDF")
        } catch { fail("testReadFileHandlesPDF: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try await suite.testLocalProcessCaptureReturnsStdout()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testLocalProcessCaptureReturnsStdout")
        } catch { fail("testLocalProcessCaptureReturnsStdout: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try await suite.testLocalProcessCaptureThrowsOnNonzeroExit()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testLocalProcessCaptureThrowsOnNonzeroExit")
        } catch { fail("testLocalProcessCaptureThrowsOnNonzeroExit: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CapabilityTests()
            defer { suite.tearDown() }
            try await suite.testLexicalMissKeepsSavedPreferenceAvailable()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testLexicalMissKeepsSavedPreferenceAvailable")
        } catch { fail("testLexicalMissKeepsSavedPreferenceAvailable: \(error)") }
        do {
            let before = TestLog.failures
            let suite = ChromePhraseTests()
            suite.testChromeToolsReadAsPlainWords()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testChromeToolsReadAsPlainWords")
        }
        do {
            let before = TestLog.failures
            let suite = ChromePhraseTests()
            suite.testChromePhrasesWithoutAnAddressStayGeneric()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testChromePhrasesWithoutAnAddressStayGeneric")
        }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testMemoryPersistsAndCorrectionReplacesFact()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMemoryPersistsAndCorrectionReplacesFact")
        } catch { fail("testMemoryPersistsAndCorrectionReplacesFact: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testDuplicateMemoryIsIdempotent()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDuplicateMemoryIsIdempotent")
        } catch { fail("testDuplicateMemoryIsIdempotent: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testMemoryDeletionRemovesRetrieval()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMemoryDeletionRemovesRetrieval")
        } catch { fail("testMemoryDeletionRemovesRetrieval: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testFTSQueryIsEscaped()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFTSQueryIsEscaped")
        } catch { fail("testFTSQueryIsEscaped: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try suite.testExplicitCommandsOnlyAndStableKeys()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testExplicitCommandsOnlyAndStableKeys")
        } catch { fail("testExplicitCommandsOnlyAndStableKeys: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try suite.testSearchExcludesSymlinksHiddenAndPackages()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSearchExcludesSymlinksHiddenAndPackages")
        } catch { fail("testSearchExcludesSymlinksHiddenAndPackages: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try suite.testSearchNewestFirstAndLimitReported()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSearchNewestFirstAndLimitReported")
        } catch { fail("testSearchNewestFirstAndLimitReported: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testToolsRejectDisabledUnknownAndExtraArguments()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testToolsRejectDisabledUnknownAndExtraArguments")
        } catch { fail("testToolsRejectDisabledUnknownAndExtraArguments: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testCancelledSearchNeverRuns()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testCancelledSearchNeverRuns")
        } catch { fail("testCancelledSearchNeverRuns: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testCancelledMemoryDoesNotWrite()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testCancelledMemoryDoesNotWrite")
        } catch { fail("testCancelledMemoryDoesNotWrite: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testProcessCancellationAndTimeout()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testProcessCancellationAndTimeout")
        } catch { fail("testProcessCancellationAndTimeout: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testMissingAudioDependencyFailsClearly()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMissingAudioDependencyFailsClearly")
        } catch { fail("testMissingAudioDependencyFailsClearly: \(error)") }
        do {
            let before = TestLog.failures
            let suite = CoreTests()
            try suite.setUpWithError(); defer { try? suite.tearDownWithError() }
            try await suite.testCapabilityGateAndContextBudget()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testCapabilityGateAndContextBudget")
        } catch { fail("testCapabilityGateAndContextBudget: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testBasicReasoningStreamsThroughHermes()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBasicReasoningStreamsThroughHermes")
        } catch { fail("testBasicReasoningStreamsThroughHermes: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testFileSearchShowsAsPlainActivity()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFileSearchShowsAsPlainActivity")
        } catch { fail("testFileSearchShowsAsPlainActivity: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testSendingAMessageWaitsForApproval()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSendingAMessageWaitsForApproval")
        } catch { fail("testSendingAMessageWaitsForApproval: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testCancelStopsTheTurnAndTheNextOneStillWorks()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testCancelStopsTheTurnAndTheNextOneStillWorks")
        } catch { fail("testCancelStopsTheTurnAndTheNextOneStillWorks: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testMessagesUpTo100KBGoThroughAndLargerOnesDont()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMessagesUpTo100KBGoThroughAndLargerOnesDont")
        } catch { fail("testMessagesUpTo100KBGoThroughAndLargerOnesDont: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testChatListAndReopeningAnEarlierChat()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testChatListAndReopeningAnEarlierChat")
        } catch { fail("testChatListAndReopeningAnEarlierChat: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testAttachmentsReachHermesAsContentBlocks()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testAttachmentsReachHermesAsContentBlocks")
        } catch { fail("testAttachmentsReachHermesAsContentBlocks: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testMissingSignInAndProviderBecomeSetupSteps()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMissingSignInAndProviderBecomeSetupSteps")
        } catch { fail("testMissingSignInAndProviderBecomeSetupSteps: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testOtherSessionsUpdatesStayOutAndTheirApprovalsAreDeclined()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testOtherSessionsUpdatesStayOutAndTheirApprovalsAreDeclined")
        } catch { fail("testOtherSessionsUpdatesStayOutAndTheirApprovalsAreDeclined: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testUnansweredApprovalCountsAsNo()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testUnansweredApprovalCountsAsNo")
        } catch { fail("testUnansweredApprovalCountsAsNo: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            suite.testDelegateAndTodoTitlesReadAsPlainWords()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDelegateAndTodoTitlesReadAsPlainWords")
        } catch { fail("testDelegateAndTodoTitlesReadAsPlainWords: \(error)") }
        do {
            let before = TestLog.failures
            let suite = HermesTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testResumedSessionReplaysHistoryAndUnknownOnesStartFresh()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testResumedSessionReplaysHistoryAndUnknownOnesStartFresh")
        } catch { fail("testResumedSessionReplaysHistoryAndUnknownOnesStartFresh: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testTwoSessionsInterleaveAndEachGetsItsOwnUpdates()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testTwoSessionsInterleaveAndEachGetsItsOwnUpdates")
        } catch { fail("testTwoSessionsInterleaveAndEachGetsItsOwnUpdates: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testWorkerSessionIsMarkedBeforeItsFirstPromptAndUnmarkedAfter()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testWorkerSessionIsMarkedBeforeItsFirstPromptAndUnmarkedAfter")
        } catch { fail("testWorkerSessionIsMarkedBeforeItsFirstPromptAndUnmarkedAfter: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testJobSessionsStopAtTwoAndStayOutOfTheChatList()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testJobSessionsStopAtTwoAndStayOutOfTheChatList")
        } catch { fail("testJobSessionsStopAtTwoAndStayOutOfTheChatList: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testAlwaysAllowIsAnsweredAsAllowOnce()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testAlwaysAllowIsAnsweredAsAllowOnce")
        } catch { fail("testAlwaysAllowIsAnsweredAsAllowOnce: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testPlanUpdatesReachTheConversation()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testPlanUpdatesReachTheConversation")
        } catch { fail("testPlanUpdatesReachTheConversation: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testFinishedJobIsAnnouncedAndKept()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFinishedJobIsAnnouncedAndKept")
        } catch { fail("testFinishedJobIsAnnouncedAndKept: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testThirdJobWaitsForAFreeSlot()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testThirdJobWaitsForAFreeSlot")
        } catch { fail("testThirdJobWaitsForAFreeSlot: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testWorkerApprovalBecomesACardTaggedWithItsJob()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testWorkerApprovalBecomesACardTaggedWithItsJob")
        } catch { fail("testWorkerApprovalBecomesACardTaggedWithItsJob: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testUnansweredCardIsDeclinedAndTakenDownInTime()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testUnansweredCardIsDeclinedAndTakenDownInTime")
        } catch { fail("testUnansweredCardIsDeclinedAndTakenDownInTime: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testBackendDeclinesAnApprovalNobodyAnswers()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBackendDeclinesAnApprovalNobodyAnswers")
        } catch { fail("testBackendDeclinesAnApprovalNobodyAnswers: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testCardsComeDownWhenTheirJobEnds()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testCardsComeDownWhenTheirJobEnds")
        } catch { fail("testCardsComeDownWhenTheirJobEnds: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testJobPlanAndFailureShowUp()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testJobPlanAndFailureShowUp")
        } catch { fail("testJobPlanAndFailureShowUp: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testVoiceTurnCardFreesTheVoiceOnce()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testVoiceTurnCardFreesTheVoiceOnce")
        } catch { fail("testVoiceTurnCardFreesTheVoiceOnce: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try suite.testLedgerKeepsRecentHistoryAndStopsInterruptedJobs()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testLedgerKeepsRecentHistoryAndStopsInterruptedJobs")
        } catch { fail("testLedgerKeepsRecentHistoryAndStopsInterruptedJobs: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            suite.testRolesFileLocationFollowsHermesHome()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testRolesFileLocationFollowsHermesHome")
        } catch { fail("testRolesFileLocationFollowsHermesHome: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            try await suite.testDelegationCheckReportsEachOutcome()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDelegationCheckReportsEachOutcome")
        } catch { fail("testDelegationCheckReportsEachOutcome: \(error)") }
        do {
            let before = TestLog.failures
            let suite = JobsTests()
            try suite.setUp(); defer { suite.tearDown() }
            suite.testDelegationPromptCarriesTheWordButNotItsAnswer()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDelegationPromptCarriesTheWordButNotItsAnswer")
        } catch { fail("testDelegationPromptCarriesTheWordButNotItsAnswer: \(error)") }
        do {
            let before = TestLog.failures
            let suite = MarkdownTests()
            suite.testBlocksCoverTheCommonShapes()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBlocksCoverTheCommonShapes")
        }
        do {
            let before = TestLog.failures
            let suite = MarkdownTests()
            suite.testUnclosedFenceStreamsAsCode()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testUnclosedFenceStreamsAsCode")
        }
        do {
            let before = TestLog.failures
            let suite = MarkdownTests()
            suite.testListContinuationsAndYearsInProse()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testListContinuationsAndYearsInProse")
        }
        do {
            let before = TestLog.failures
            let suite = OllamaTests()
            defer { suite.tearDown() }
            try await suite.testCloudTagRejectedBeforeNetwork()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testCloudTagRejectedBeforeNetwork")
        } catch { fail("testCloudTagRejectedBeforeNetwork: \(error)") }
        do {
            let before = TestLog.failures
            let suite = OllamaTests()
            defer { suite.tearDown() }
            try await suite.testRemoteAliasRejected()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testRemoteAliasRejected")
        } catch { fail("testRemoteAliasRejected: \(error)") }
        do {
            let before = TestLog.failures
            let suite = OllamaTests()
            defer { suite.tearDown() }
            try await suite.testErrorsNeverEchoServerContent()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testErrorsNeverEchoServerContent")
        } catch { fail("testErrorsNeverEchoServerContent: \(error)") }
        do {
            let before = TestLog.failures
            let suite = OllamaTests()
            defer { suite.tearDown() }
            try await suite.testMalformedAndIncompleteResponsesFail()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMalformedAndIncompleteResponsesFail")
        } catch { fail("testMalformedAndIncompleteResponsesFail: \(error)") }
        do {
            let before = TestLog.failures
            let suite = OllamaTests()
            defer { suite.tearDown() }
            try await suite.testSpokenHintReachesSystemPromptOnlyWhenSpeaking()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenHintReachesSystemPromptOnlyWhenSpeaking")
        } catch { fail("testSpokenHintReachesSystemPromptOnlyWhenSpeaking: \(error)") }
        do {
            let before = TestLog.failures
            let suite = OllamaTests()
            defer { suite.tearDown() }
            try await suite.testUnsupportedModelToolCannotExecute()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testUnsupportedModelToolCannotExecute")
        } catch { fail("testUnsupportedModelToolCannotExecute: \(error)") }
        do {
            let before = TestLog.failures
            let suite = RenameTests()
            try suite.testLegacyFolderMovesOnceAndSavedPathsFollow()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testLegacyFolderMovesOnceAndSavedPathsFollow")
        } catch { fail("testLegacyFolderMovesOnceAndSavedPathsFollow: \(error)") }
        do {
            let before = TestLog.failures
            let suite = RenameTests()
            try suite.testFailedMoveKeepsUsingTheOldFolder()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFailedMoveKeepsUsingTheOldFolder")
        } catch { fail("testFailedMoveKeepsUsingTheOldFolder: \(error)") }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testDecimalsAndWholeNumbers()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDecimalsAndWholeNumbers")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testYearsDecadesAndOrdinals()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testYearsDecadesAndOrdinals")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testMoney()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMoney")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testPercentagesRangesAndMultipliers()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testPercentagesRangesAndMultipliers")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testTimes()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testTimes")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testDates()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDates")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testUnitsFractionsAndSymbols()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testUnitsFractionsAndSymbols")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testAbbreviations()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testAbbreviations")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testAbbreviationsThatEndASentenceKeepTheirPeriod()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testAbbreviationsThatEndASentenceKeepTheirPeriod")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testHostsFilesEmailsAndPhoneNumbers()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testHostsFilesEmailsAndPhoneNumbers")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechNumbersTests()
            suite.testLeavesModelNamesAndCodesAlone()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testLeavesModelNamesAndCodesAlone")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testSpokenStripsInlineMarkdown()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenStripsInlineMarkdown")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testSpokenTurnsListsAndHeadingsIntoSentences()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenTurnsListsAndHeadingsIntoSentences")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testSpokenReplacesCodeBlocksAndLinks()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenReplacesCodeBlocksAndLinks")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testSpokenDropsLengthMarkerEmojiArrowsAndTables()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenDropsLengthMarkerEmojiArrowsAndTables")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testSpokenCutsAtSentenceBoundaryWithinLimit()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenCutsAtSentenceBoundaryWithinLimit")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testSpokenDoesntDoubleThePeriodInsideQuotesOrBrackets()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenDoesntDoubleThePeriodInsideQuotesOrBrackets")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testSentencesDontSplitInsideNumbersOrAbbreviations()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSentencesDontSplitInsideNumbersOrAbbreviations")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testSentencesMergeShortFragments()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSentencesMergeShortFragments")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testFeedStartsEarlyAndMatchesOneShot()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedStartsEarlyAndMatchesOneShot")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testFeedHoldsListMarkersAndShortFragments()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedHoldsListMarkersAndShortFragments")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testFeedWaitsOutAbbreviationsAndDecimals()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedWaitsOutAbbreviationsAndDecimals")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testFeedHoldsShortFollowUpsUntilFlushed()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedHoldsShortFollowUpsUntilFlushed")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testFeedRestartsForANewTurnAndKeepsCodeOffTheVoice()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedRestartsForANewTurnAndKeepsCodeOffTheVoice")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testFeedRespectsTheSpokenLimit()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedRespectsTheSpokenLimit")
        }
        do {
            let before = TestLog.failures
            let suite = SpeechTests()
            suite.testStreamedAnswersSayTheSameAsOneShot()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testStreamedAnswersSayTheSameAsOneShot")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceBlendTests()
            suite.testDefaultVoiceAndTheCatalog()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDefaultVoiceAndTheCatalog")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceBlendTests()
            try suite.testBlendsReadLikeSynthesizePy()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBlendsReadLikeSynthesizePy")
        } catch { fail("testBlendsReadLikeSynthesizePy: \(error)") }
        do {
            let before = TestLog.failures
            let suite = VoiceBlendTests()
            suite.testBadBlendsSayWhatIsWrong()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBadBlendsSayWhatIsWrong")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceBlendTests()
            suite.testShortNames()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testShortNames")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceBlendTests()
            await suite.testSynthesisChecksTheVoiceBeforeAnythingRuns()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSynthesisChecksTheVoiceBeforeAnythingRuns")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceBlendTests()
            try await suite.testWorkerPassesTheVoiceSettingAndArgumentsThrough()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testWorkerPassesTheVoiceSettingAndArgumentsThrough")
        } catch { fail("testWorkerPassesTheVoiceSettingAndArgumentsThrough: \(error)") }
        do {
            let before = TestLog.failures
            let suite = VoiceSyncTests()
            suite.testEachStreamedChunkRevealsItsOwnSentence()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testEachStreamedChunkRevealsItsOwnSentence")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceSyncTests()
            suite.testChunksFromOneBatchRevealAtSentenceEnds()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testChunksFromOneBatchRevealAtSentenceEnds")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceSyncTests()
            suite.testHeldBackTextIsRevealedWithTheChunkThatSaysIt()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testHeldBackTextIsRevealedWithTheChunkThatSaysIt")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceSyncTests()
            suite.testTextTheVoiceSkipsShowsWithTheNextSentence()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testTextTheVoiceSkipsShowsWithTheNextSentence")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceSyncTests()
            suite.testWhereTheVoiceStopsEverythingShows()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testWhereTheVoiceStopsEverythingShows")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceSyncTests()
            suite.testANewReplyStartsCountingFromItsOwnText()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testANewReplyStartsCountingFromItsOwnText")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            suite.testEndpointerStartsOnSpeechAndFinishesAfterTrailingSilence()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testEndpointerStartsOnSpeechAndFinishesAfterTrailingSilence")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            suite.testEndpointerTimesOutWithoutSpeechAndCapsDuration()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testEndpointerTimesOutWithoutSpeechAndCapsDuration")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            suite.testEndpointerHandlesPreRollThatAlreadyContainsSpeechAndNoisyRooms()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testEndpointerHandlesPreRollThatAlreadyContainsSpeechAndNoisyRooms")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            suite.testBargeInIgnoresEchoResidueButHearsAVoice()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBargeInIgnoresEchoResidueButHearsAVoice")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            suite.testWakePhraseMatchingAndStripping()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testWakePhraseMatchingAndStripping")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            try await suite.testWAVFileWritesReadableSixteenKilohertzMono()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testWAVFileWritesReadableSixteenKilohertzMono")
        } catch { fail("testWAVFileWritesReadableSixteenKilohertzMono: \(error)") }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            suite.testSentencesChunkForEarlyFirstAudio()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSentencesChunkForEarlyFirstAudio")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            try await suite.testSpeechWorkerSpeaksTheLineProtocolAndSurvivesErrors()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpeechWorkerSpeaksTheLineProtocolAndSurvivesErrors")
        } catch { fail("testSpeechWorkerSpeaksTheLineProtocolAndSurvivesErrors: \(error)") }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            suite.testStandbyPresetWaitsIndefinitelyAndClosesUtterances()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testStandbyPresetWaitsIndefinitelyAndClosesUtterances")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            suite.testDownsamplerKeepsChannelZeroOfMultichannelInput()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDownsamplerKeepsChannelZeroOfMultichannelInput")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            suite.testBargeInCalibratesToEchoAndIgnoresSentenceGaps()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBargeInCalibratesToEchoAndIgnoresSentenceGaps")
        }
        do {
            let before = TestLog.failures
            let suite = VoiceTests()
            try suite.testConfigurationDecodesFilesWrittenBeforeNewFields()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testConfigurationDecodesFilesWrittenBeforeNewFields")
        } catch { fail("testConfigurationDecodesFilesWrittenBeforeNewFields: \(error)") }
        do {
            let before = TestLog.failures
            let suite = WorkspaceTests()
            try await suite.testReviewDoesNotWriteAndStaleTaskCannotOverwrite()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testReviewDoesNotWriteAndStaleTaskCannotOverwrite")
        } catch { fail("testReviewDoesNotWriteAndStaleTaskCannotOverwrite: \(error)") }
        do {
            let before = TestLog.failures
            let suite = WorkspaceTests()
            try await suite.testDraftReviewCannotOverwriteOrEscapeFolder()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDraftReviewCannotOverwriteOrEscapeFolder")
        } catch { fail("testDraftReviewCannotOverwriteOrEscapeFolder: \(error)") }
        do {
            let before = TestLog.failures
            let suite = WorkspaceTests()
            try await suite.testBrowserTabsParseTextPageListWithoutStructuredContent()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBrowserTabsParseTextPageListWithoutStructuredContent")
        } catch { fail("testBrowserTabsParseTextPageListWithoutStructuredContent: \(error)") }
        do {
            let before = TestLog.failures
            let suite = WorkspaceTests()
            try await suite.testBrowserPaginationNewTabAndIDValidation()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBrowserPaginationNewTabAndIDValidation")
        } catch { fail("testBrowserPaginationNewTabAndIDValidation: \(error)") }
        do {
            let before = TestLog.failures
            let suite = WorkspaceTests()
            try await suite.testProjectSnapshotReadsGitStatusBranchAndNotes()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testProjectSnapshotReadsGitStatusBranchAndNotes")
        } catch { fail("testProjectSnapshotReadsGitStatusBranchAndNotes: \(error)") }
        do {
            let before = TestLog.failures
            let suite = WorkspaceTests()
            try await suite.testProjectSnapshotBlockedWithoutActiveProjectsMemory()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testProjectSnapshotBlockedWithoutActiveProjectsMemory")
        } catch { fail("testProjectSnapshotBlockedWithoutActiveProjectsMemory: \(error)") }
        do {
            let before = TestLog.failures
            let suite = WorkspaceTests()
            try await suite.testChromeHealthKeepsSlowAdapterAndDropsDeadAdapter()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testChromeHealthKeepsSlowAdapterAndDropsDeadAdapter")
        } catch { fail("testChromeHealthKeepsSlowAdapterAndDropsDeadAdapter: \(error)") }
        do {
            let before = TestLog.failures
            let suite = WorkspaceTests()
            try await suite.testMCPCapturesAdapterStderr()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMCPCapturesAdapterStderr")
        } catch { fail("testMCPCapturesAdapterStderr: \(error)") }
        do {
            let before = TestLog.failures
            let suite = WorkspaceTests()
            try await suite.testMCPProtocolTimeoutCancellationAndRestart()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMCPProtocolTimeoutCancellationAndRestart")
        } catch { fail("testMCPProtocolTimeoutCancellationAndRestart: \(error)") }
        print("\(count) tests completed in \(String(format: "%.2f", Date().timeIntervalSince(started)))s; \(TestLog.failures) failures")
        if TestLog.failures > 0 { exit(1) }
    }
}
