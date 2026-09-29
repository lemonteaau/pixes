/// Identifies a build published by this fork's release workflow, which passes
/// both values with `--dart-define`. Local and debug builds leave them empty.
abstract final class ForkBuild {
  static const commit = String.fromEnvironment('FORK_COMMIT');
  static const version = String.fromEnvironment('FORK_VERSION');

  static bool get isRelease => commit.isNotEmpty;

  static const repository = 'lemonteaau/pixes';
}
