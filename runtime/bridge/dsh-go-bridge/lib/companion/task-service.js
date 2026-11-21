// The existing bridge owns the fixed task service, not an HTTP connection.
export function mountCompanionTasks(ctx) {
  return ctx.inject(['storageDomain', 'fs', 'agents', 'sessions', 'sessionPersistence'], async taskCtx => {
    let store;
    try {
      const [{openCompanionTaskStore},{createNotesExecutionOwner},{createNotesToTodosRunner},
        {createFindDraftRunner,findDraftSupported}] = await Promise.all([
        import('./task-store.js'), import('./task-execution.js'), import('./notes-to-todos.js'), import('./find-draft.js')]);
      taskCtx.fiber.assertActive();
      store = await openCompanionTaskStore({facility:taskCtx.get('storageDomain'),fs:taskCtx.get('fs')});
      taskCtx.fiber.assertActive();
      const execution = createNotesExecutionOwner(taskCtx,store);
      const runner = createNotesToTodosRunner({ctx:taskCtx,store,execution});
      const find = findDraftSupported(taskCtx.get('fs')) ? createFindDraftRunner({ctx:taskCtx,store}) : null;
      store.attachRunner({kinds:['host.notes_to_todo',...(find?['host.find_draft']:[])],
        wake:id=>store.read(id).kind==='host.find_draft'?find?.wake(id):runner.wake(id),
        stop:async()=>{await Promise.all([runner.stop(),find?.stop()]);await execution.close();}});
      taskCtx.effect(()=>()=>store.close(),'dsh-go-bridge: durable companion tasks');
      taskCtx.provide('dshGoCompanionTasks',store);
      for (const id of store.runnable()) store.wake(id);
    } catch(error) {
      await store?.close();
      taskCtx.logger?.warn?.(`Companion tasks unavailable: ${error?.code ?? 'task_service_unavailable'}`);
    }
  });
}
