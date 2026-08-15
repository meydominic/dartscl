/// Utilities for parsing mDNS TXT record entries and determining eSCL path / properties.
class MdnsTxtParser {
  /// Parses raw TXT record string key=value pairs into a map.
  static Map<String, String> parseTxtString(String txtData) {
    final result = <String, String>{};
    final lines = txtData.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final eqIndex = trimmed.indexOf('=');
      if (eqIndex != -1) {
        final key = trimmed.substring(0, eqIndex).toLowerCase();
        final value = trimmed.substring(eqIndex + 1);
        result[key] = value;
      } else {
        result[trimmed.toLowerCase()] = '';
      }
    }
    return result;
  }

  /// Extracts the eSCL path from TXT record attributes.
  /// Standard key is 'rs' (e.g. 'rs=eSCL' or 'rs=eSCL/').
  /// Fallbacks check 'adminurl', 'note', or default to '/eSCL'.
  static String extractPath(Map<String, String> txtMap) {
    if (txtMap.containsKey('rs')) {
      var rs = txtMap['rs']!;
      if (!rs.startsWith('/')) {
        rs = '/$rs';
      }
      if (rs.endsWith('/') && rs.length > 1) {
        rs = rs.substring(0, rs.length - 1);
      }
      return rs;
    }

    if (txtMap.containsKey('adminurl')) {
      final url = txtMap['adminurl']!;
      try {
        final uri = Uri.parse(url);
        if (uri.path.isNotEmpty && uri.path != '/') {
          var p = uri.path;
          if (p.endsWith('/') && p.length > 1) {
            p = p.substring(0, p.length - 1);
          }
          return p;
        }
      } catch (_) {}
    }

    return '/eSCL';
  }

  /// Extracts display name from TXT record ('ty' or 'note') or defaults to fallback.
  static String extractName(Map<String, String> txtMap, String fallbackName) {
    if (txtMap.containsKey('ty') && txtMap['ty']!.isNotEmpty) {
      return txtMap['ty']!;
    }
    if (txtMap.containsKey('note') && txtMap['note']!.isNotEmpty) {
      return txtMap['note']!;
    }
    return fallbackName;
  }
}
