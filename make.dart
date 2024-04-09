#!/usr/bin/env dart
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const appName = 'ServerBox';
final appNameLower = appName.toLowerCase();

const buildDataFilePath = 'lib/data/res/build_data.dart';
const apkPath = 'build/app/outputs/flutter-apk/app-release.apk';
const appleXCConfigPath = 'Runner.xcodeproj/project.pbxproj';
const macOSArchievePath = 'build/macos/Build/Products/Release/server_box.app';
const releaseDir = '/Volumes/pm981/release/serverbox';
const shellScriptPath = 'lib/data/model/app/shell_func.dart';
const uploadPathPrefix = 'cda:/var/www/res/';

var regAppleProjectVer = RegExp(r'CURRENT_PROJECT_VERSION = .+;');
var regAppleMarketVer = RegExp(r'MARKETING_VERSION = .+');

const buildFuncs = {
  'ios': flutterBuildIOS,
  'android': flutterBuildAndroid,
  'apk': flutterBuildAndroid,
  'mac': flutterBuildMacOS,
  'linux': flutterBuildLinux,
  'win': flutterBuildWin,
};

int? build;

Future<void> getGitCommitCount() async {
  final result = await Process.run('git', ['log', '--format=format:%h']);
  build = (result.stdout as String)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .length;
}

Future<int> getScriptCommitCount() async {
  if (!await File(shellScriptPath).exists()) {
    print('File not found: $shellScriptPath');
    exit(1);
  }
  final result =
      await Process.run('git', ['log', '--format=format:%h', shellScriptPath]);
  return (result.stdout as String)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .length;
}

Future<void> writeStaicConfigFile(
    Map<String, dynamic> data, String className, String path) async {
  final buffer = StringBuffer();
  buffer.writeln('// This file is generated by ./make.dart');
  buffer.writeln('');
  buffer.writeln('class $className {');
  for (var entry in data.entries) {
    final type = entry.value.runtimeType;
    final value = json.encode(entry.value);
    buffer.writeln('  static const $type ${entry.key} = $value;');
  }
  buffer.writeln('}');
  await File(path).writeAsString(buffer.toString());
}

Future<int> getGitModificationCount() async {
  final result =
      await Process.run('git', ['ls-files', '-mo', '--exclude-standard']);
  return (result.stdout as String)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .length;
}

Future<String> getFlutterVersion() async {
  final result = await Process.run('flutter', ['--version'], runInShell: true);
  final stdout = result.stdout as String;
  return stdout.split('\n')[0].split('•')[0].split(' ')[1].trim();
}

Future<Map<String, dynamic>> getBuildData() async {
  final data = {
    'name': appName,
    'build': build,
    'engine': await getFlutterVersion(),
    'buildAt': DateTime.now().toString().split('.').firstOrNull,
    'modifications': await getGitModificationCount(),
    'script': await getScriptCommitCount(),
  };
  return data;
}

String jsonEncodeWithIndent(Map<String, dynamic> json) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(json);
}

Future<void> updateBuildData() async {
  print('Updating BuildData...');
  final data = await getBuildData();
  print(jsonEncodeWithIndent(data));
  await writeStaicConfigFile(data, 'BuildData', buildDataFilePath);
}

Future<void> dartFormat() async {
  final result = await Process.run('dart', ['format', '.'], runInShell: true);
  print(result.stdout);
  if (result.exitCode != 0) {
    print(result.stderr);
    exit(1);
  }
}

Future<String> getFileSha256(String path) async {
  final result = await Process.run('shasum', ['-a', '256', path]);
  final stdout = result.stdout as String;
  return stdout.split(' ')[0];
}

Future<void> flutterBuild(String buildType) async {
  final args = [
    'build',
    buildType,
    '--build-number=$build',
    '--build-name=1.0.$build',
  ];
  final skslPath = '$buildType.sksl.json';
  if (await File(skslPath).exists()) {
    args.add('--bundle-sksl-path=$skslPath');
  }
  final isAndroid = 'apk' == buildType;
  if (isAndroid) {
    // Only arm64
    args.add('--target-platform=android-arm64');
  }
  print('\n[$buildType]\nBuilding with args: ${args.join(' ')}');
  final buildResult = await Process.run('flutter', args, runInShell: true);
  final exitCode = buildResult.exitCode;

  if (exitCode != 0) {
    print(buildResult.stdout);
    print(buildResult.stderr);
    exit(exitCode);
  }
}

Future<void> flutterBuildIOS() async {
  await flutterBuild('ipa');
}

Future<void> flutterBuildMacOS() async {
  await flutterBuild('macos');
}

Future<void> flutterBuildAndroid() async {
  await flutterBuild('apk');
  await killJava();
  await scpApk2CDN();
}

Future<void> flutterBuildLinux() async {
  await flutterBuild('linux');
  const appDirName = 'linux.AppDir';
  // cp -r build/linux/x64/release/bundle/* appName.AppDir
  await Process.run('cp', [
    '-r',
    'build/linux/x64/release/bundle',
    appDirName,
  ]);
  // cp -r assets/app_icon.png ServerBox.AppDir
  await Process.run('cp', [
    '-r',
    './assets/app_icon.png',
    appDirName,
  ]);
  // Create AppRun
  const appRun = '''
#!/bin/sh
cd "\$(dirname "\$0")"
exec ./$appName
''';
  const appRunName = '$appDirName/AppRun';
  await File(appRunName).writeAsString(appRun);
  // chmod +x AppRun
  await Process.run('chmod', ['+x', appRunName]);
  // Create .desktop
  const desktop = '''
[Desktop Entry]
Name=$appName
Exec=$appName
Icon=app_icon
Type=Application
Categories=Utility;
''';
  await File('$appDirName/default.desktop').writeAsString(desktop);
  // Run appimagetool
  await Process.run('sh', ['-c', 'ARCH=x86_64 appimagetool $appDirName']);

  await scpLinux2CDN();
}

Future<void> flutterBuildWin() async {
  await flutterBuild('windows');
  //await scpWindows2CDN();
}

Future<void> scpApk2CDN() async {
  final result = await Process.run(
    'scp',
    [apkPath, '$uploadPathPrefix$appNameLower/$appName-$build.apk'],
    runInShell: true,
  );
  if (result.exitCode != 0) {
    print(result.stderr);
    exit(1);
  }
  print('Upload $build.apk finished.');
}

Future<void> scpLinux2CDN() async {
  final result = await Process.run(
    'scp',
    [
      '$appName-x86_64.AppImage',
      '$uploadPathPrefix$appNameLower/$appName-$build.AppImage',
    ],
    runInShell: true,
  );
  if (result.exitCode != 0) {
    print(result.stderr);
    exit(1);
  }
  print('Upload $build.AppImage finished.');
}

Future<void> scpWindows2CDN() async {
  final result = await Process.run(
    'scp',
    [
      './build/windows/runner/Release/$appName.zip',
      '$uploadPathPrefix$appNameLower/$appName-$build.zip',
    ],
    runInShell: true,
  );
  if (result.exitCode != 0) {
    print(result.stderr);
    exit(1);
  }
  print('Upload $build.zip finished.');
}

Future<void> changeAppleVersion() async {
  for (final path in ['ios', 'macos']) {
    final file = File('$path/$appleXCConfigPath');
    final contents = await file.readAsString();
    final newContents = contents
        .replaceAll(regAppleMarketVer, 'MARKETING_VERSION = 1.0.$build;')
        .replaceAll(regAppleProjectVer, 'CURRENT_PROJECT_VERSION = $build;');
    await file.writeAsString(newContents);
  }
}

Future<void> killJava() async {
  /// Due to the high cost of Mac memory,
  /// terminate Java processes to free up memory.
  /// :)
  if (!Platform.isMacOS) return;
  final result = await Process.run('ps', ['-A']);
  final lines = (result.stdout as String).split('\n');
  for (final line in lines) {
    if (line.contains('java')) {
      final pid = line.split(' ')[0];
      print('Killing java process: $pid');
      await Process.run('kill', [pid]);
    }
  }
}

void main(List<String> args) async {
  if (args.isEmpty) {
    print('No action. Exit.');
    return;
  }

  final command = args[0];
  switch (command) {
    case 'build':
      await dartFormat();
      await getGitCommitCount();
      // always change version to avoid dismatch version between different
      // platforms
      await changeAppleVersion();
      await updateBuildData();

      final funcs = <Future<void> Function()>[];

      if (args.length > 1) {
        final platforms = args[1];
        for (final platform in platforms.split(',')) {
          if (buildFuncs.keys.contains(platform)) {
            funcs.add(buildFuncs[platform]!);
          } else {
            print('Unknown platform: $platform');
          }
        }
      } else {
        funcs.addAll(buildFuncs.values);
      }

      final stopwatch = Stopwatch();
      for (final func in funcs) {
        stopwatch.start();
        await func();
        print('Build finished in ${stopwatch.elapsed}');
        stopwatch.reset();
      }
      break;
    default:
      print('Unsupported command: $command');
      break;
  }
}
