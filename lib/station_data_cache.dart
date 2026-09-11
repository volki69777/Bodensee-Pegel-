class StationDataCache<T> {
  StationDataCache({this.ttl = const Duration(seconds: 75)});

  final Duration ttl;
  final Map<String, _CacheEntry<T>> _entries = {};

  Future<T> get(String stationUuid, Future<T> Function() loader) {
    final now = DateTime.now();
    final existing = _entries[stationUuid];
    if (existing != null && now.isBefore(existing.expiresAt)) {
      return existing.value;
    }

    final value = loader();
    _entries[stationUuid] = _CacheEntry(
      value: value,
      expiresAt: now.add(ttl),
    );
    value.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_entries[stationUuid]?.value, value)) {
          _entries.remove(stationUuid);
        }
      },
    );
    return value;
  }

  void invalidate(String stationUuid) => _entries.remove(stationUuid);
}

class _CacheEntry<T> {
  const _CacheEntry({required this.value, required this.expiresAt});

  final Future<T> value;
  final DateTime expiresAt;
}
