package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test

class RuntimeServiceRecoveryTest {
    private class Store {
        var encoded = -1
        private var diskEncoded = -1
        var acceptsUpdates = true
        val updates = mutableListOf<RuntimeServiceRecovery.Snapshot?>()

        fun flushToDisk() { diskEncoded = encoded }

        fun controller() = RuntimeServiceRecovery(RuntimeServiceRecovery.Snapshot.decode(diskEncoded)) { snapshot ->
            updates += snapshot
            if (acceptsUpdates) encoded = snapshot?.encode() ?: -1
            acceptsUpdates
        }
    }

    @Test fun systemRecreationRestoresBothNonDefaultOptions() {
        val store = Store()
        val original = store.controller()
        val options = RuntimeServiceRecovery.Snapshot(phoneStorage = true, visualReplies = false)
        original.request(options, hasTemporaryEnvironment = false)
        assertTrue(original.canRecreate)
        store.flushToDisk()
        val recreated = store.controller()
        assertEquals(options, recreated.optionsForStart(recreated = true))
        assertTrue(recreated.canRecreate)
        assertEquals(listOf(options), store.updates)
    }

    @Test fun submittedUpdateWithoutDiskSnapshotCannotRestoreAColdProcess() {
        val store = Store()
        val recovery = store.controller()
        recovery.request(RuntimeServiceRecovery.Snapshot(true, false), false)
        assertTrue(recovery.canRecreate)
        val cold = store.controller()
        assertFalse(cold.canRecreate)
        assertNull(cold.optionsForStart(recreated = true))
    }

    @Test fun allOptionCombinationsRoundTripWithoutDefaultingFalseToTrue() {
        for (phoneStorage in listOf(false, true)) for (visualReplies in listOf(false, true)) {
            val options = RuntimeServiceRecovery.Snapshot(phoneStorage, visualReplies)
            assertEquals(options, RuntimeServiceRecovery.Snapshot.decode(options.encode()))
        }
        assertNull(RuntimeServiceRecovery.Snapshot.decode(-1))
        assertNull(RuntimeServiceRecovery.Snapshot.decode(4))
    }

    @Test fun noPriorRunCannotBeInventedByANullIntent() {
        val recovery = Store().controller()
        assertNull(recovery.optionsForStart(recreated = true))
        assertNull(recovery.optionsForStart(recreated = false))
        assertFalse(recovery.canRecreate)
    }

    @Test fun temporaryEnvironmentAllowsOnlyTheLiveExplicitStart() {
        val store = Store()
        val recovery = store.controller()
        val options = RuntimeServiceRecovery.Snapshot(true, false)
        recovery.request(options, hasTemporaryEnvironment = true)
        assertEquals(options, recovery.optionsForStart(recreated = false))
        assertNull(recovery.optionsForStart(recreated = true))
        assertFalse(recovery.canRecreate)
        assertEquals(listOf<RuntimeServiceRecovery.Snapshot?>(null), store.updates)
        assertNull(store.controller().optionsForStart(recreated = true))
    }

    @Test fun temporaryEnvironmentPublishesRemovalOfAnEarlierRecoveryHint() {
        val store = Store()
        val recovery = store.controller()
        recovery.request(RuntimeServiceRecovery.Snapshot(false, true), false)
        store.flushToDisk()
        recovery.request(RuntimeServiceRecovery.Snapshot(true, false), true)
        assertEquals(-1, store.encoded)
        assertFalse(recovery.canRecreate)
        store.flushToDisk()
        assertNull(store.controller().optionsForStart(recreated = true))
    }

    @Test fun clearingRevokesLiveStartAndPublishesHintRemoval() {
        val store = Store()
        val recovery = store.controller()
        recovery.request(RuntimeServiceRecovery.Snapshot(true, false), false)
        store.flushToDisk()
        recovery.clear()
        assertFalse(recovery.canRecreate)
        assertNull(recovery.optionsForStart(recreated = false))
        assertNull(recovery.optionsForStart(recreated = true))
        store.flushToDisk()
        assertNull(store.controller().optionsForStart(recreated = true))
        assertEquals(-1, store.encoded)
    }

    @Test fun aLaterExplicitStartCanRecoverAgainAfterStop() {
        val store = Store()
        val recovery = store.controller()
        recovery.request(RuntimeServiceRecovery.Snapshot(false, true), false)
        recovery.clear()
        val options = RuntimeServiceRecovery.Snapshot(true, false)
        recovery.request(options, false)
        assertTrue(recovery.canRecreate)
        store.flushToDisk()
        assertEquals(options, store.controller().optionsForStart(recreated = true))
    }

    @Test fun rejectedSnapshotUpdateNeverAllowsSystemRecreation() {
        val store = Store().apply { acceptsUpdates = false }
        val recovery = store.controller()
        val options = RuntimeServiceRecovery.Snapshot(true, false)
        recovery.request(options, false)
        assertEquals(options, recovery.optionsForStart(recreated = false))
        assertFalse(recovery.canRecreate)
        assertNull(recovery.optionsForStart(recreated = true))
        assertEquals(-1, store.encoded)
    }

    @Test fun rejectedHintRemovalStillDisablesRecreationForTheCurrentService() {
        val store = Store()
        val recovery = store.controller()
        recovery.request(RuntimeServiceRecovery.Snapshot(true, false), false)
        store.acceptsUpdates = false
        recovery.clear()
        assertFalse(recovery.canRecreate)
        assertNull(recovery.optionsForStart(recreated = true))
        assertNull(recovery.optionsForStart(recreated = false))
    }

    @Test fun aRejectedOldStopDoesNotRevokeTheNewRun() {
        val store = Store()
        val recovery = store.controller()
        val options = RuntimeServiceRecovery.Snapshot(true, false)
        recovery.request(options, false)
        store.flushToDisk()
        if (RuntimeServiceRecovery.acceptsStop(1, 2, "owner", "owner")) recovery.clear()
        assertTrue(recovery.canRecreate)
        assertEquals(options, store.controller().optionsForStart(recreated = true))
        assertFalse(RuntimeServiceRecovery.acceptsStop(1, 2, "owner", "owner"))
    }

    @Test fun queuedOldStopCannotConsumeAcceptedStartAtTheSameGeneration() {
        for (hasTemporaryEnvironment in listOf(false, true)) {
            val recovery = Store().controller()
            recovery.request(RuntimeServiceRecovery.Snapshot(false, true), false)
            recovery.beginRun()
            val oldOwner = recovery.runStopOwner
            val unchangedGeneration = 7
            recovery.clear()
            val options = RuntimeServiceRecovery.Snapshot(true, false)
            recovery.request(options, hasTemporaryEnvironment)
            // START is accepted but not consumed, so runGen has not advanced.
            assertNotEquals(oldOwner, recovery.stopOwner)
            val accepted = RuntimeServiceRecovery.acceptsStop(
                unchangedGeneration, unchangedGeneration, oldOwner, recovery.stopOwner,
            )
            if (accepted) recovery.clear()
            assertFalse(accepted)
            assertEquals(options, recovery.optionsForStart(recreated = false))
            assertEquals(!hasTemporaryEnvironment, recovery.canRecreate)
        }
    }

    @Test fun anOldRunCannotBorrowAnAcceptedRequestsStopOwner() {
        val recovery = Store().controller()
        recovery.request(RuntimeServiceRecovery.Snapshot(false, true), false)
        recovery.beginRun()
        val oldOwner = recovery.runStopOwner
        recovery.clear()
        recovery.request(RuntimeServiceRecovery.Snapshot(true, false), false)
        // A stop emitted after request acceptance still captures the previous run's owner.
        assertEquals(oldOwner, recovery.runStopOwner)
        assertFalse(RuntimeServiceRecovery.acceptsStop(7, 7, recovery.runStopOwner, recovery.stopOwner))
        recovery.beginRun()
        assertEquals(recovery.stopOwner, recovery.runStopOwner)
        assertTrue(RuntimeServiceRecovery.acceptsStop(8, 8, recovery.runStopOwner, recovery.stopOwner))
    }

    @Test fun updatingActiveOptionsDoesNotInvalidateTheRunsAutomaticStop() {
        val recovery = Store().controller()
        recovery.request(RuntimeServiceRecovery.Snapshot(false, true), false)
        recovery.beginRun()
        val owner = recovery.runStopOwner
        val options = RuntimeServiceRecovery.Snapshot(true, false)
        recovery.request(options, false, newStart = false)
        assertEquals(owner, recovery.stopOwner)
        assertEquals(owner, recovery.runStopOwner)
        assertTrue(RuntimeServiceRecovery.acceptsStop(7, 7, owner, recovery.stopOwner))
        assertEquals(options, recovery.optionsForStart(recreated = false))
    }

    @Test fun oldProcessCannotStopRecreatedRunWithTheSameGeneration() {
        assertFalse(RuntimeServiceRecovery.acceptsStop(1, 1, "old-process", "new-process"))
        assertFalse(RuntimeServiceRecovery.acceptsStop(1, 1, null, "new-process"))
        assertTrue(RuntimeServiceRecovery.acceptsStop(1, 1, "new-process", "new-process"))
        // The notification's manual stop intentionally has no generation or owner.
        assertTrue(RuntimeServiceRecovery.acceptsStop(null, 1, null, "new-process"))
    }
}
