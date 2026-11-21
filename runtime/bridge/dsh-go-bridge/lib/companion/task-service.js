// The existing bridge owns the fixed task service, not an HTTP connection.
export function mountCompanionTasks(ctx) {
  return ctx.inject(['storageDomain', 'fs', 'agents', 'sessions', 'sessionPersistence'], async taskCtx => {
    let store;
    try {
      const [{openCompanionTaskStore},{createNotesExecutionOwner},{createNotesToTodosRunner}] = await Promise.all([
        import('./task-store.js'), import('./task-execution.js'), import('./notes-to-todos.js')]);
      taskCtx.fiber.assertActive();
      store = await openCompanionTaskStore({facility:taskCtx.get('storageDomain'),fs:taskCtx.get('fs')});
      taskCtx.fiber.assertActive();
      const execution = createNotesExecutionOwner(taskCtx,store);
      const runner = createNotesToTodosRunner({ctx:taskCtx,store,execution});
      store.attachRunner({wake:id=>runner.wake(id),stop:async()=>{await runner.stop();await execution.close();}});
      taskCtx.effect(()=>()=>store.close(),'dsh-go-bridge: durable companion tasks');
      taskCtx.provide('dshGoCompanionTasks',store);
      for (const id of store.runnable()) store.wake(id);
    } catch(error) {
      await store?.close();
      taskCtx.logger?.warn?.(`Companion tasks unavailable: ${error?.code ?? 'task_service_unavailable'}`);
    }
  });
}
