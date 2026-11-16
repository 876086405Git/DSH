# Automations

Let a conversation receive an instruction at a set time: once, daily, or on a recurring rule. Automations run on the host, and times follow the host's time zone.

<!-- nav: catalogAllFeatures,catalogSchedules -->
`All features › Automations`

[Open](dshgo://open/schedules)

Filter the list by **Active** or **Ended**, and search task names, instructions and rules. Each row shows its rule and the next run; ended tasks show when they last ran.

## Creating

Tap **New** and fill in the name, the instruction and the run time. The task is created by the open conversation's host, so open a conversation first; some conversations (such as a subagent's) can't receive automations.

## Details

Open a task to see its rule, instruction and run history; you can also **Edit**, **Run now** or delete it. Ended tasks can't be changed.

## Notes

- A due task is sent into the conversation that created it. If that conversation is deleted, or the host no longer supports it, the task doesn't run.
- Times are stored in the host's time zone; after switching hosts, tasks stay with their original host.
- On HarmonyOS, tasks on this phone only fire while the app is running: while the system has it suspended, they won't run on time, as the top of the list says. Put tasks that must run on time in a chat on a remote host.
