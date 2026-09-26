import Foundation

@main struct TestRunner {
    static func main() async {
        let started = Date()
        var count = 0
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
            try await suite.testUnsupportedModelToolCannotExecute()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testUnsupportedModelToolCannotExecute")
        } catch { fail("testUnsupportedModelToolCannotExecute: \(error)") }
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
            try await suite.testLexicalMissKeepsSavedPreferenceAvailable()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testLexicalMissKeepsSavedPreferenceAvailable")
        } catch { fail("testLexicalMissKeepsSavedPreferenceAvailable: \(error)") }
        do {
            let before = TestLog.failures
            try await WorkspaceTests().testReviewDoesNotWriteAndStaleTaskCannotOverwrite()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testReviewDoesNotWriteAndStaleTaskCannotOverwrite")
        } catch { fail("testReviewDoesNotWriteAndStaleTaskCannotOverwrite: \(error)") }
        do {
            let before = TestLog.failures
            try await WorkspaceTests().testDraftReviewCannotOverwriteOrEscapeFolder()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDraftReviewCannotOverwriteOrEscapeFolder")
        } catch { fail("testDraftReviewCannotOverwriteOrEscapeFolder: \(error)") }
        do {
            let before = TestLog.failures
            try await WorkspaceTests().testBrowserPaginationNewTabAndIDValidation()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBrowserPaginationNewTabAndIDValidation")
        } catch { fail("testBrowserPaginationNewTabAndIDValidation: \(error)") }
        do {
            let before = TestLog.failures
            try await WorkspaceTests().testMCPProtocolTimeoutCancellationAndRestart()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMCPProtocolTimeoutCancellationAndRestart")
        } catch { fail("testMCPProtocolTimeoutCancellationAndRestart: \(error)") }
        do {
            let before = TestLog.failures
            try await WorkspaceTests().testMCPCapturesAdapterStderr()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMCPCapturesAdapterStderr")
        } catch { fail("testMCPCapturesAdapterStderr: \(error)") }
        do {
            let before = TestLog.failures
            try await WorkspaceTests().testProjectSnapshotReadsGitStatusBranchAndNotes()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testProjectSnapshotReadsGitStatusBranchAndNotes")
        } catch { fail("testProjectSnapshotReadsGitStatusBranchAndNotes: \(error)") }
        do {
            let before = TestLog.failures
            try await WorkspaceTests().testProjectSnapshotBlockedWithoutActiveProjectsMemory()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testProjectSnapshotBlockedWithoutActiveProjectsMemory")
        } catch { fail("testProjectSnapshotBlockedWithoutActiveProjectsMemory: \(error)") }
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
            SpeechTests().testSpokenStripsInlineMarkdown()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenStripsInlineMarkdown")
        }
        do {
            let before = TestLog.failures
            SpeechTests().testSpokenTurnsListsAndHeadingsIntoSentences()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenTurnsListsAndHeadingsIntoSentences")
        }
        do {
            let before = TestLog.failures
            SpeechTests().testSpokenReplacesCodeBlocksAndLinks()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenReplacesCodeBlocksAndLinks")
        }
        do {
            let before = TestLog.failures
            SpeechTests().testSpokenDropsLengthMarkerEmojiArrowsAndTables()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenDropsLengthMarkerEmojiArrowsAndTables")
        }
        do {
            let before = TestLog.failures
            SpeechTests().testSpokenCutsAtSentenceBoundaryWithinLimit()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpokenCutsAtSentenceBoundaryWithinLimit")
        }
        do {
            let before = TestLog.failures
            SpeechTests().testFeedStartsEarlyAndMatchesOneShot()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedStartsEarlyAndMatchesOneShot")
        }
        do {
            let before = TestLog.failures
            SpeechTests().testFeedHoldsListMarkersAndShortFragments()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedHoldsListMarkersAndShortFragments")
        }
        do {
            let before = TestLog.failures
            SpeechTests().testFeedRestartsForANewTurnAndKeepsCodeOffTheVoice()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedRestartsForANewTurnAndKeepsCodeOffTheVoice")
        }
        do {
            let before = TestLog.failures
            SpeechTests().testFeedRespectsTheSpokenLimit()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testFeedRespectsTheSpokenLimit")
        }
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
            try await WorkspaceTests().testChromeHealthKeepsSlowAdapterAndDropsDeadAdapter()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testChromeHealthKeepsSlowAdapterAndDropsDeadAdapter")
        } catch { fail("testChromeHealthKeepsSlowAdapterAndDropsDeadAdapter: \(error)") }
        do {
            let before = TestLog.failures
            try await WorkspaceTests().testBrowserTabsParseTextPageListWithoutStructuredContent()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBrowserTabsParseTextPageListWithoutStructuredContent")
        } catch { fail("testBrowserTabsParseTextPageListWithoutStructuredContent: \(error)") }
        do {
            let before = TestLog.failures
            VoiceTests().testEndpointerStartsOnSpeechAndFinishesAfterTrailingSilence()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testEndpointerStartsOnSpeechAndFinishesAfterTrailingSilence")
        }
        do {
            let before = TestLog.failures
            VoiceTests().testEndpointerTimesOutWithoutSpeechAndCapsDuration()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testEndpointerTimesOutWithoutSpeechAndCapsDuration")
        }
        do {
            let before = TestLog.failures
            VoiceTests().testEndpointerHandlesPreRollThatAlreadyContainsSpeechAndNoisyRooms()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testEndpointerHandlesPreRollThatAlreadyContainsSpeechAndNoisyRooms")
        }
        do {
            let before = TestLog.failures
            VoiceTests().testBargeInIgnoresEchoResidueButHearsAVoice()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBargeInIgnoresEchoResidueButHearsAVoice")
        }
        do {
            let before = TestLog.failures
            VoiceTests().testWakePhraseMatchingAndStripping()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testWakePhraseMatchingAndStripping")
        }
        do {
            let before = TestLog.failures
            try await VoiceTests().testWAVFileWritesReadableSixteenKilohertzMono()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testWAVFileWritesReadableSixteenKilohertzMono")
        } catch { fail("testWAVFileWritesReadableSixteenKilohertzMono: \(error)") }
        do {
            let before = TestLog.failures
            try VoiceTests().testConfigurationDecodesFilesWrittenBeforeNewFields()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testConfigurationDecodesFilesWrittenBeforeNewFields")
        } catch { fail("testConfigurationDecodesFilesWrittenBeforeNewFields: \(error)") }
        do {
            let before = TestLog.failures
            VoiceTests().testSentencesChunkForEarlyFirstAudio()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSentencesChunkForEarlyFirstAudio")
        }
        do {
            let before = TestLog.failures
            try await VoiceTests().testSpeechWorkerSpeaksTheLineProtocolAndSurvivesErrors()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testSpeechWorkerSpeaksTheLineProtocolAndSurvivesErrors")
        } catch { fail("testSpeechWorkerSpeaksTheLineProtocolAndSurvivesErrors: \(error)") }
        do {
            let before = TestLog.failures
            VoiceTests().testStandbyPresetWaitsIndefinitelyAndClosesUtterances()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testStandbyPresetWaitsIndefinitelyAndClosesUtterances")
        }
        do {
            let before = TestLog.failures
            VoiceTests().testDownsamplerKeepsChannelZeroOfMultichannelInput()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testDownsamplerKeepsChannelZeroOfMultichannelInput")
        }
        do {
            let before = TestLog.failures
            VoiceTests().testBargeInCalibratesToEchoAndIgnoresSentenceGaps()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBargeInCalibratesToEchoAndIgnoresSentenceGaps")
        }
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
            try await suite.testMissingSignInAndProviderBecomeSetupSteps()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testMissingSignInAndProviderBecomeSetupSteps")
        } catch { fail("testMissingSignInAndProviderBecomeSetupSteps: \(error)") }
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
            MarkdownTests().testBlocksCoverTheCommonShapes()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testBlocksCoverTheCommonShapes")
        }
        do {
            let before = TestLog.failures
            MarkdownTests().testUnclosedFenceStreamsAsCode()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testUnclosedFenceStreamsAsCode")
        }
        do {
            let before = TestLog.failures
            MarkdownTests().testListContinuationsAndYearsInProse()
            count += 1
            print("\(TestLog.failures == before ? "PASS" : "FAIL") testListContinuationsAndYearsInProse")
        }
        print("\(count) tests completed in \(String(format: "%.2f", Date().timeIntervalSince(started)))s; \(TestLog.failures) failures")
        if TestLog.failures > 0 { exit(1) }
    }
}
