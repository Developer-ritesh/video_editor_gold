import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:video_editor_gold/src/controller.dart';
import 'package:video_editor_gold/src/models/file_format.dart';

class FFmpegVideoEditorExecute {
  const FFmpegVideoEditorExecute({
    required this.command,
    required this.outputPath,
  });

  final String command;
  final String outputPath;
}

abstract class FFmpegVideoEditorConfig {
  final VideoEditorController controller;

  /// If the [name] is `null`, then it uses this video filename.
  final String? name;

  /// If the [outputDirectory] is `null`, then it uses `TemporaryDirectory`.
  final String? outputDirectory;

  /// The [scale] is `scale=width*scale:height*scale` and reduces or increases the file dimensions.
  /// Defaults to `1.0`.
  final double scale;

  /// Set [isFiltersEnabled] to `false` if you do not want to apply any changes.
  /// Defaults to `true`.
  final bool isFiltersEnabled;

  const FFmpegVideoEditorConfig(
    this.controller, {
    this.name,
    @protected this.outputDirectory,
    this.scale = 1.0,
    this.isFiltersEnabled = true,
  });

  /// Convert the controller's [minCrop] and [maxCrop] params into a [String]
  /// used to provide crop values to FFmpeg.
  ///
  /// The result is in the format `crop=w:h:x:y`
  String get cropCmd {
    if (controller.minCrop <= minOffset && controller.maxCrop >= maxOffset) {
      return "";
    }

    final enddx = controller.videoWidth * controller.maxCrop.dx;
    final enddy = controller.videoHeight * controller.maxCrop.dy;
    final startdx = controller.videoWidth * controller.minCrop.dx;
    final startdy = controller.videoHeight * controller.minCrop.dy;

    return "crop=${enddx - startdx}:${enddy - startdy}:$startdx:$startdy";
  }

  /// Convert the controller's [rotation] value into a [String]
  ///
  /// The result is in the format `transpose=2` (repeated for every 90 degrees rotations)
  String get rotationCmd {
    final count = controller.rotation / 90;
    if (count <= 0 || count >= 4) return "";

    final List<String> transpose = [];
    for (int i = 0; i < controller.rotation / 90; i++) {
      transpose.add("transpose=2");
    }
    return transpose.isNotEmpty ? transpose.join(',') : "";
  }

  /// [see FFmpeg doc](https://ffmpeg.org/ffmpeg-filters.html#scale)
  ///
  /// The result is in format `scale=width*scale:height*scale`
  String get scaleCmd => scale == 1.0 ? "" : "scale=iw*$scale:ih*$scale";

  /// Returns the list of all the active filters
  List<String> getExportFilters() {
    if (!isFiltersEnabled) return [];
    final List<String> filters = [cropCmd, scaleCmd, rotationCmd];
    filters.removeWhere((item) => item.isEmpty);
    return filters;
  }

  /// Returns the `-filter:v` (-vf alias) command to use in FFmpeg execution
  String filtersCmd(List<String> filters) {
    filters.removeWhere((item) => item.isEmpty);
    return filters.isNotEmpty ? "-vf '${filters.join(",")}'" : "";
  }

  /// Returns the output path of the exported file
  Future<String> getOutputPath({
    required String filePath,
    required FileFormat format,
  }) async {
    final String tempPath =
        outputDirectory ?? (await getTemporaryDirectory()).path;
    final String n = name ?? path.basenameWithoutExtension(filePath);
    final int epoch = DateTime.now().millisecondsSinceEpoch;
    return "$tempPath/${n}_$epoch.${format.extension}";
  }

  /// Can be used from FFmpeg session callback, for example:
  /// ```dart
  /// FFmpegKitConfig.enableStatisticsCallback((stats) {
  ///   final progress = getFFmpegSessionProgress(stats.getTime());
  /// });
  /// ```
  /// Returns the [double] progress value between 0.0 and 1.0.
  double getFFmpegProgress(int time) {
    final double progressValue =
        time / controller.trimmedDuration.inMilliseconds;
    return progressValue.clamp(0.0, 1.0);
  }

  /// Returns the [FFmpegVideoEditorExecute] that contains the param to provide to FFmpeg.
  Future<FFmpegVideoEditorExecute?> getExecuteConfig();
}

class VideoFFmpegVideoEditorConfig extends FFmpegVideoEditorConfig {
  const VideoFFmpegVideoEditorConfig(
    super.controller, {
    super.name,
    super.outputDirectory,
    super.scale,
    super.isFiltersEnabled,
    this.format = VideoExportFormat.mp4,
    this.commandBuilder,
  });

  /// The [format] of the video to be exported.
  final VideoExportFormat format;

  final String Function(
    FFmpegVideoEditorConfig config,
    String videoPath,
    String outputPath,
  )? commandBuilder;

  String get startTrimCmd => "-ss ${controller.startTrim}";
  String get toTrimCmd => "-t ${controller.trimmedDuration}";
  String get gifCmd =>
      format.extension == VideoExportFormat.gif.extension ? "-loop 0" : "";

  @override
  List<String> getExportFilters() {
    final List<String> filters = super.getExportFilters();
    final bool isGif = format.extension == VideoExportFormat.gif.extension;
    if (isGif) {
      filters.add(
          'fps=${format is GifExportFormat ? (format as GifExportFormat).fps : VideoExportFormat.gif.fps}');
    }
    return filters;
  }

  @override
  Future<FFmpegVideoEditorExecute> getExecuteConfig() async {
    final String videoPath = controller.file.path;
    final String outputPath =
        await getOutputPath(filePath: videoPath, format: format);
    final List<String> filters = getExportFilters();

    return FFmpegVideoEditorExecute(
      command: commandBuilder != null
          ? commandBuilder!(this, "\'$videoPath\'", "\'$outputPath\'")
          : "$startTrimCmd -i \'$videoPath\' $toTrimCmd ${filtersCmd(filters)} $gifCmd ${filters.isEmpty ? '-c copy' : ''} -y \'$outputPath\'",
      outputPath: outputPath,
    );
  }
}

class CoverFFmpegVideoEditorConfig extends FFmpegVideoEditorConfig {
  const CoverFFmpegVideoEditorConfig(
    super.controller, {
    super.name,
    super.outputDirectory,
    super.scale,
    super.isFiltersEnabled,
    this.format = CoverExportFormat.jpg,
    this.quality = 100,
    this.commandBuilder,
  });

  final CoverExportFormat format;
  final int quality;

  final String Function(
    CoverFFmpegVideoEditorConfig config,
    String videoPath,
    String outputPath,
  )? commandBuilder;

  /// Generate a command for FFmpeg to extract the cover from the video
  Future<String?> _generateCoverFile() async {
    final String coverFilePath = await getOutputPath(
      filePath: controller.file.path,
      format: format,
    );
    final String command =
        "-i '${controller.file.path}' -vf 'scale=iw*$scale:ih*$scale' -q:v $quality -vframes 1 '$coverFilePath'";
    return coverFilePath;
  }

  @override
  Future<FFmpegVideoEditorExecute?> getExecuteConfig() async {
    final String? coverPath = await _generateCoverFile();
    if (coverPath == null) {
      debugPrint('Error while generating cover using FFmpeg.');
      return null;
    }
    final String outputPath =
        await getOutputPath(filePath: coverPath, format: format);
    final List<String> filters = getExportFilters();

    return FFmpegVideoEditorExecute(
      command: commandBuilder != null
          ? commandBuilder!(this, "\'$coverPath\'", "\'$outputPath\'")
          : "-i \'$coverPath\' ${filtersCmd(filters)} -y \'$outputPath\'",
      outputPath: outputPath,
    );
  }
}
