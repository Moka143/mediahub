import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/settings.dart';
import 'package:mediahub/utils/constants.dart';

void main() {
  group('VideoDecoding.mpvHwdec', () {
    test('Automatic copies frames back on Windows only', () {
      // Windows draws through ANGLE, which cannot take every format the GPU
      // decodes to: a 10-bit HEVC file played sound over a black picture.
      expect(VideoDecoding.automatic.mpvHwdec(windows: true), 'auto-copy');
      expect(VideoDecoding.automatic.mpvHwdec(windows: false), 'auto');
    });

    test('the explicit choices mean the same on every platform', () {
      for (final windows in [true, false]) {
        expect(VideoDecoding.hardware.mpvHwdec(windows: windows), 'auto');
        expect(
          VideoDecoding.compatible.mpvHwdec(windows: windows),
          'auto-copy',
        );
        expect(VideoDecoding.software.mpvHwdec(windows: windows), 'no');
      }
    });
  });

  group('AppSettings.videoDecoding', () {
    test('defaults to Automatic', () {
      expect(AppSettings().videoDecoding, VideoDecoding.automatic);
      expect(
        AppSettings.fromJson(const {}).videoDecoding,
        VideoDecoding.automatic,
      );
    });

    test('survives a save and load', () {
      final saved = AppSettings(videoDecoding: VideoDecoding.software).toJson();
      expect(AppSettings.fromJson(saved).videoDecoding, VideoDecoding.software);
    });

    test('an unknown stored value falls back instead of failing', () {
      expect(
        AppSettings.fromJson(const {'video_decoding': 99}).videoDecoding,
        VideoDecoding.automatic,
      );
    });
  });
}
