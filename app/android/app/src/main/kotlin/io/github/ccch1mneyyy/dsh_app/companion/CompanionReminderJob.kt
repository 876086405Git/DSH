package io.github.ccch1mneyyy.dsh_app.companion

import android.app.AlarmManager
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabaseLockedException
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors

internal object CompanionReminderWork {
    // Both Android components live in :companion_reminder. Only one physical
    // register/cancel/notify can run, even when a Job and an alarm arrive together.
    val executor = Executors.newSingleThreadExecutor { work ->
        Thread(work, "dsh-companion-reminder").apply { isDaemon = true }
    }
}

/** One lifecycle recovery opportunity; no periodic timer, Flutter, network, or model. */
class CompanionReminderJob : JobService() {
    private class Run(val parameters: JobParameters) {
        @Volatile var stopped = false
        var cursor = ""
        var pendingTask: String? = null
    }
    @Volatile private var active: Run? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onStartJob(params: JobParameters): Boolean {
        active?.stopped = true
        val run = Run(params)
        active = run
        next(run)
        return true
    }

    private fun next(run: Run) {
        CompanionReminderWork.executor.execute {
            if (run.stopped) return@execute
            try {
                val executorId = CompanionReminderPlatform.executorId(applicationContext)
                var exhausted = false
                CompanionReminderLedger.open(applicationContext).use { ledger ->
                    val task = run.pendingTask ?: ledger.recoveryBatch(
                        executorId, System.currentTimeMillis(), run.cursor, 1,
                    ).firstOrNull()
                    if (task == null) exhausted = true
                    else {
                        val runner = CompanionReminderRunner(ledger, CompanionReminderAndroid(applicationContext), executorId)
                        if (runner.resume(task)) { run.cursor = task; run.pendingTask = null }
                        else run.pendingTask = task
                    }
                }
                if (run.stopped) return@execute
                if (exhausted) finish(run, false)
                else next(run) // Yield between bounded chunks so alarms can run.
            } catch (_: SQLiteDatabaseLockedException) {
                finish(run, true)
            } catch (_: Exception) {
                // Missing/old/corrupt databases do not create a perpetual retry job.
                // A committed effect claim remains; a foreground opportunity can retry.
                finish(run, false)
            }
        }
    }

    private fun finish(run: Run, retry: Boolean) {
        main.post {
            if (!run.stopped && active === run) {
                run.stopped = true
                active = null
                jobFinished(run.parameters, retry)
            }
        }
    }

    override fun onStopJob(params: JobParameters): Boolean {
        active?.stopped = true
        active = null
        return true
    }

    class Receiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                    Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED,
                    AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED)) {
                try { schedule(context) } catch (_: Exception) { /* A later foreground opportunity can retry. */ }
            }
        }
    }

    companion object {
        private const val JOB_ID = 0x434d5001
        fun schedule(context: Context): Boolean {
            // Replacing this one Job restarts its cursor, including a task inserted
            // behind an in-progress scan. The old callback cannot finish the new Job.
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, CompanionReminderJob::class.java))
                .setMinimumLatency(1).build()
            return context.getSystemService(JobScheduler::class.java).schedule(job) == JobScheduler.RESULT_SUCCESS
        }
    }
}
