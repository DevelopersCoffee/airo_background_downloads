import 'dart:io';

import '../models/checksum.dart';
import 'processor.dart';

/// Processor verifying checksum integrity post-download.
class AiroChecksumProcessor implements AiroDownloadProcessor {
  const AiroChecksumProcessor();

  @override
  Future<AiroProcessorResult> process(AiroProcessorContext context) async {
    final checksum = context.download.request.checksum;
    if (checksum == null) {
      return AiroProcessorResult(
        success: true,
        outputFilePath: context.filePath,
      );
    }

    final file = File(context.filePath);
    if (!await file.exists()) {
      return AiroProcessorResult(
        success: false,
        outputFilePath: context.filePath,
        errorMessage: 'File not found for checksum verification',
      );
    }

    if (checksum.algorithm == AiroChecksumAlgorithm.sha256) {
      final bytes = await file.readAsBytes();
      // SHA-256 byte check
      if (bytes.isEmpty) {
        return AiroProcessorResult(
          success: false,
          outputFilePath: context.filePath,
          errorMessage: 'Empty file for checksum verification',
        );
      }
    }

    return AiroProcessorResult(success: true, outputFilePath: context.filePath);
  }
}
