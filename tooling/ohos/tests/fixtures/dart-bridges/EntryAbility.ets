export class EntryAbility {
  configureFlutterEngine(engine: FlutterEngine): void {
    engine.getPlugins()?.add(new FixturePlugin());
  }
}
