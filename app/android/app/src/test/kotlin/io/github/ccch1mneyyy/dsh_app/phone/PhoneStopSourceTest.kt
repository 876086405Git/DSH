package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.*
import org.junit.Test

class PhoneStopSourceTest {
    @Test fun bothScreenReceiversKeepTheScreenSourceAndOriginalHold() {
        var time = 1_000L
        val tasks = PhoneTasks(clock = { time }, stopHoldMs = 30)
        tasks.begin()
        tasks.publish(tasks.stopActiveDeferred("screen off", PhoneTasks.StopSource.SCREEN_OFF))
        val epoch = tasks.admissionEpoch()
        time += 15
        tasks.publish(tasks.stopActiveDeferred("second receiver", PhoneTasks.StopSource.SCREEN_OFF))
        assertEquals("SCREEN_OFF", tasks.snapshot().toMap()["stopSource"])
        assertTrue(tasks.snapshot().interrupted)
        assertTrue(tasks.admissionEpoch() > epoch)
        time += 15
        assertFalse(tasks.snapshot().stopped)
        assertNull(tasks.snapshot().stopSource)
    }

    @Test fun validUserStopUpgradesAScreenHoldAndScreenCannotDowngradeIt() {
        val tasks = PhoneTasks(clock = { 1_000L })
        tasks.begin()
        tasks.publish(tasks.stopActiveDeferred("screen off", PhoneTasks.StopSource.SCREEN_OFF))
        val change = checkNotNull(tasks.stopForSnapshot(tasks.snapshot(), "user stop"))
        tasks.publish(change)
        assertEquals("USER", tasks.snapshot().toMap()["stopSource"])
        assertTrue(tasks.snapshot().interrupted)
        tasks.publish(tasks.stopActiveDeferred("screen off again", PhoneTasks.StopSource.SCREEN_OFF))
        assertEquals(PhoneTasks.StopSource.USER, tasks.snapshot().stopSource)
        tasks.publish(tasks.stopActiveDeferred("service left", PhoneTasks.StopSource.ENVIRONMENT))
        tasks.publish(tasks.stopActiveDeferred("second receiver", PhoneTasks.StopSource.SCREEN_OFF))
        assertEquals(PhoneTasks.StopSource.ENVIRONMENT, tasks.snapshot().stopSource)
    }

    @Test fun ambientAndUserStopsKeepTheirOwnRefusalCopy() {
        val ambient = PhoneTasks(clock = { 1_000L })
        ambient.begin()
        ambient.publish(ambient.stopActiveDeferred("screen off", PhoneTasks.StopSource.SCREEN_OFF))
        val environment = ambient.begin() as PhoneTasks.Begin.Refused
        assertEquals(PhoneTasks.ENV_STOPPED_MESSAGE, environment.message)

        val user = PhoneTasks(clock = { 1_000L })
        user.begin()
        user.stop("user stop")
        val refused = user.begin() as PhoneTasks.Begin.Refused
        assertEquals(PhoneTasks.STOPPED_MESSAGE, refused.message)
        assertNotEquals(environment.message, refused.message)
    }
}
