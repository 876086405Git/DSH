// Explicit host-only provider injection, not the Riverpod implementation.
class Provider<T> {
  Provider(this.create);
  final T Function(Ref) create;
}

class Ref {
  Ref([Map<Object, Object?>? values]) : values = values ?? {};
  final Map<Object, Object?> values;
  final disposers = <void Function()>[];
  T read<T>(Provider<T> provider) =>
      values.containsKey(provider) ? values[provider] as T : provider.create(this);
  T watch<T>(Provider<T> provider) => read(provider);
  bool get mounted => true;
  void onDispose(void Function() dispose) => disposers.add(dispose);
}

abstract class Notifier<T> {
  late Ref ref;
  late T state;
  T build();
}
class NotifierProvider<N extends Notifier<T>, T> extends Provider<T> {
  NotifierProvider(N Function() create) : super((ref) {
    final notifier = create()..ref = ref;
    return notifier.state = notifier.build();
  });
}
