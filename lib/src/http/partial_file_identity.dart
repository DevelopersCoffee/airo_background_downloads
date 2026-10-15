/// Stable identity of an on-disk partial file (device + inode).
class PartialFileIdentity {
  const PartialFileIdentity({
    required this.deviceId,
    required this.inode,
    required this.linkCount,
    required this.ownerUid,
  });

  final int deviceId;
  final int inode;
  final int linkCount;
  final int ownerUid;

  Map<String, Object?> toJson() => {
    'dev': deviceId,
    'ino': inode,
  };

  static PartialFileIdentity? fromJson(Map<String, dynamic>? map) {
    if (map == null) return null;
    final dev = map['dev'];
    final ino = map['ino'];
    if (dev is! num || ino is! num) return null;
    return PartialFileIdentity(
      deviceId: dev.toInt(),
      inode: ino.toInt(),
      linkCount: 1,
      ownerUid: 0,
    );
  }

  bool matches(PartialFileIdentity other) =>
      deviceId == other.deviceId && inode == other.inode;
}
