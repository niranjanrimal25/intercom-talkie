/// Small helpers for tuning the Opus audio codec through SDP munging.
///
/// The WebRTC stack negotiates Opus by default; we adjust the `a=fmtp` line
/// to lower the bitrate (voice does not need 64 kbps), disable stereo and
/// optionally enable discontinuous transmission (DTX) to save battery and
/// airtime during silence.
class SdpTools {
  /// Rewrites the Opus `a=fmtp` parameters inside an SDP description.
  ///
  /// [maxAverageBitrateBps] clamps Opus's average bitrate (1000..510000).
  /// [enableDtx] adds `usedtx=1` (comfort noise during silence).
  /// [stereo] forces `stereo=0` (mono) which slightly reduces bitrate and
  /// guarantees interop with HFP/SCO links that are mono anyway.
  static String tuneOpus(
    String sdp, {
    int maxAverageBitrateBps = 30000,
    bool enableDtx = true,
    bool stereo = false,
  }) {
    final lines = sdp.split('\r\n');
    if (lines.length == 1 && sdp.contains('\n')) {
      // Tolerate LF-only SDP.
      return _tune(
        sdp.split('\n'),
        maxAverageBitrateBps,
        enableDtx,
        stereo,
      ).join('\n');
    }
    return _tune(lines, maxAverageBitrateBps, enableDtx, stereo).join('\r\n');
  }

  static List<String> _tune(
    List<String> lines,
    int maxAverageBitrateBps,
    bool enableDtx,
    bool stereo,
  ) {
    // Find the Opus payload type: a=rtpmap:<pt> opus/48000/2
    final opusPayloadTypes = <String>[];
    final rtpmap = RegExp(r'^a=rtpmap:(\d+)\s+opus/48000/2\s*$');
    for (final line in lines) {
      final match = rtpmap.firstMatch(line.trim());
      if (match != null) {
        opusPayloadTypes.add(match.group(1)!);
      }
    }
    if (opusPayloadTypes.isEmpty) {
      return lines;
    }

    final payloadType = opusPayloadTypes.first;
    final fmtpPrefix = 'a=fmtp:$payloadType ';

    final params = <String, String>{};
    var fmtpIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith(fmtpPrefix)) {
        fmtpIndex = i;
        final existing = line.substring(fmtpPrefix.length);
        for (final pair in existing.split(';')) {
          final trimmed = pair.trim();
          if (trimmed.isEmpty) {
            continue;
          }
          final eq = trimmed.indexOf('=');
          if (eq > 0) {
            params[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
          } else {
            params[trimmed] = '';
          }
        }
        break;
      }
    }

    final clampedBitrate = maxAverageBitrateBps.clamp(1000, 510000);
    params['maxaveragebitrate'] = clampedBitrate.toString();
    params['stereo'] = stereo ? '1' : '0';
    if (enableDtx) {
      params['usedtx'] = '1';
    } else {
      params.remove('usedtx');
    }

    final orderedKeys = <String>[];
    // Preserve original key order, then append new ones.
    final written = <String>{};
    for (final entry in params.entries) {
      if (entry.key == 'maxaveragebitrate' ||
          entry.key == 'stereo' ||
          entry.key == 'usedtx') {
        continue;
      }
      orderedKeys.add(entry.key);
      written.add(entry.key);
    }
    for (final key in const ['maxaveragebitrate', 'stereo', 'usedtx']) {
      if (params.containsKey(key)) {
        orderedKeys.add(key);
        written.add(key);
      }
    }

    final paramText = orderedKeys
        .map((key) =>
            params[key]!.isEmpty ? key : '$key=${params[key]}')
        .join(';');
    final fmtpLine = '$fmtpPrefix$paramText';

    if (fmtpIndex >= 0) {
      lines[fmtpIndex] = fmtpLine;
    } else {
      // Insert right after the matching rtpmap line.
      var insertAt = lines.length - 1;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trim().startsWith('a=rtpmap:$payloadType ')) {
          insertAt = i + 1;
          break;
        }
      }
      lines.insert(insertAt, fmtpLine);
    }
    return lines;
  }

  /// Extracts the Opus payload types (used by tests and diagnostics).
  static List<String> opusPayloadTypes(String sdp) {
    final types = <String>[];
    final rtpmap = RegExp(r'^a=rtpmap:(\d+)\s+opus/48000/2\s*$');
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      final match = rtpmap.firstMatch(line.trim());
      if (match != null) {
        types.add(match.group(1)!);
      }
    }
    return types;
  }
}
