import 'dart:io';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';
import 'package:code_assets/code_assets.dart';
import 'package:path/path.dart' as path;

void main(List<String> args) async {
  await build(args, (input, output) async {
    int? iosDeploymentTargetVersion;

    final codeConfig = input.config.code;
    final CodeConfig(:targetOS, :targetTriple, :linkMode) = codeConfig;

    try {
      iosDeploymentTargetVersion = codeConfig.iOS.targetVersion;
    } catch (_) {}

    await _withOutputDirectoryBuildLock(input.outputDirectory, () async {
      await RustBuilder(
        assetName: 'src/rust/frb_generated.io.dart',
        cratePath: 'rust',
        extraCargoEnvironmentVariables: {
          if ((iosDeploymentTargetVersion ?? 0) > 0) 'IPHONEOS_DEPLOYMENT_TARGET': '$iosDeploymentTargetVersion.0',
        },
      ).run(
        input: await buildInputForHost(input: input),
        output: output,
      );
    });

    // TODO
    // once rust compiled build NSE (this is great but it works on next build than expected to manually update is better.)
    // if (targetOS == OS.android || targetOS == OS.iOS) {
    //   stdout.write('Bundling bindings for Notifications');
    //   final outputDir = path.fromUri(input.outputDirectory);
    //   final binaryFilePath = path.join(
    //     path.join(outputDir, 'target'),
    //     targetTriple,
    //     'release',
    //     targetOS.libraryFileName('manna_core', linkMode).replaceAll('-', '_'),
    //   );
    //
    //   final rustCrateDirPath = path.join(path.fromUri(input.packageRoot), 'rust');
    //   final bindingDirPath = path.join(outputDir, 'bindings');
    //   // generate bindings
    //   await invoke('cargo', [
    //     'run',
    //     '--bin',
    //     'uniffi-bindgen',
    //     'generate',
    //     '--library',
    //     binaryFilePath,
    //     '--language',
    //     targetOS == OS.iOS ? 'swift' : 'kotlin',
    //     '--out-dir',
    //     bindingDirPath,
    //   ], workingDirectory: rustCrateDirPath);
    //
    //   final i = outputDir.indexOf('.dart_tool');
    //   if (i <= 0) throw Exception('Invalid dart runner configuration!');
    //   final flutterRootDir = outputDir.substring(0, i); // root of the host flutter project
    //
    //   if (targetOS == OS.iOS) {
    //     // build xcframework to link it in NSE
    //     final iosDir = path.join(flutterRootDir, 'ios');
    //     if (!Directory(iosDir).existsSync()) throw Exception('Missing ios directory, $iosDir');
    //
    //     // rename the modulemap file so xcode don't yell
    //     await invoke('mv', [
    //       path.join(bindingDirPath, 'manna_coreFFI.modulemap'),
    //       path.join(bindingDirPath, 'module.modulemap'),
    //     ]);
    //     final xcFrameworkOutputDir = path.join(iosDir, 'NotificationExtension', 'NSE_Rust', 'MannaCore.xcframework');
    //     await invoke('rm', ['-rf', xcFrameworkOutputDir]);
    // TODO to build, xcframework we need static lib `.a` not `.dylib`
    //     await invoke('xcodebuild', [
    //       '-create-xcframework',
    //       '-library',
    //       binaryFilePath,
    //       '-headers',
    //       bindingDirPath,
    //       '-output',
    //       xcFrameworkOutputDir,
    //     ]);
    //     await invoke('cp', [
    //       path.join(bindingDirPath, 'manna_core.swift'),
    //       path.join(iosDir, 'NotificationExtension', 'manna_core.swift'),
    //     ]);
    //   } else if (targetOS == OS.android) {
    //     final androidBindingDir = path.join(flutterRootDir, 'android', 'app', 'src', 'main', 'kotlin');
    //     if (!Directory(androidBindingDir).existsSync()) {
    //       throw Exception('Missing android bindings directory, $androidBindingDir');
    //     }
    //     await invoke('cp', [bindingDirPath, androidBindingDir]);
    //   }
    //
    //   // final result = await Process.run('sh', [
    //   //   'build_nse_ios.sh',
    //   // ], workingDirectory: path.join(path.fromUri(input.packageRoot), 'rust'));
    //   //
    //   // if (result.exitCode != 0) {
    //   //   stderr.writeln('Rust Compilation Error:\n${result.stderr}');
    //   //   exit(result.exitCode);
    //   // } else {
    //   //   print('NSE xcframework updated!');
    //   // }
    // }
  });
}

// lock to eliminate race conditions
Future<T> _withOutputDirectoryBuildLock<T>(Uri outputDirectory, Future<T> Function() action) async {
  final lockFile = File(
    '${Directory.fromUri(outputDirectory).path}'
    '${Platform.pathSeparator}.flutter_rust_bridge_native_assets_build.lock',
  );
  await lockFile.create(recursive: true);
  final lock = await lockFile.open(mode: FileMode.write);

  try {
    await lock.lock(FileLock.exclusive);
    return await action();
  } finally {
    await lock.unlock();
    await lock.close();
  }
}

Future<BuildInput> buildInputForHost({required BuildInput input}) async {
  if (Platform.isWindows) {
    // Keep Windows Native Assets output paths short. native_toolchain_rust places
    // Cargo artifacts under input.outputDirectory/target, and Flutter hook output
    // roots can otherwise make those paths exceed Windows toolchain limits.
    final shortOutputDirectoryShared = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'frb_native_assets_${_stablePathHash(input.outputDirectoryShared.toString())}',
    );
    await shortOutputDirectoryShared.create(recursive: true);

    return BuildInput({...input.json, 'out_dir_shared': Directory.fromUri(shortOutputDirectoryShared.uri).path});
  }
  return input;
}

String _stablePathHash(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

extension CodeConfigMapping on CodeConfig {
  String get targetTriple {
    return switch ((targetOS, targetArchitecture)) {
      // Android
      (OS.android, Architecture.arm64) => 'aarch64-linux-android',
      (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
      (OS.android, Architecture.x64) => 'x86_64-linux-android',

      // iOS
      (OS.iOS, Architecture.arm64) when iOS.targetSdk == IOSSdk.iPhoneSimulator => 'aarch64-apple-ios-sim',
      (OS.iOS, Architecture.arm64) when iOS.targetSdk == IOSSdk.iPhoneOS => 'aarch64-apple-ios',
      (OS.iOS, Architecture.arm64) => throw UnsupportedError('Unknown IOSSdk: ${iOS.targetSdk}'),
      (OS.iOS, Architecture.x64) => 'x86_64-apple-ios',

      // Windows
      (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
      (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',

      // Linux
      (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
      (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',

      // macOS
      (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
      (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',

      (_, _) => throw UnsupportedError('Unsupported target: $targetOS on $targetArchitecture'),
    };
  }

  LinkMode get linkMode {
    return switch (linkModePreference) {
      LinkModePreference.dynamic || LinkModePreference.preferDynamic => DynamicLoadingBundled(),
      LinkModePreference.static || LinkModePreference.preferStatic => StaticLinking(),
      _ => throw UnsupportedError('Unsupported LinkModePreference: $linkModePreference'),
    };
  }
}

Future<String> invoke(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  try {
    stdout.writeAll([
      'Invoking "$executable $arguments" '
          '${workingDirectory != null ? 'in directory $workingDirectory ' : ''}'
          'with environment: ${environment ?? {}}',
    ]);
    final result = await Process.run(
      executable,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) {
      throw Exception(
        'Process finished with non-zero exit code: "$executable $arguments" '
        'with stdout: "${result.stdout}" and stderr: "${result.stderr}"',
      );
    }
    return result.stdout as String;
  } on ProcessException catch (exception, stackTrace) {
    stderr.writeAll(['Failed to invoke "$executable $arguments"', exception, stackTrace]);
    rethrow;
  }
}
