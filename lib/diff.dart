/// A run of corrected text; [changed] marks words Claude altered.
class Seg {
  const Seg(this.text, this.changed);
  final String text;
  final bool changed;
}

final _tokenRe = RegExp(
  r"\s+|[\p{L}\p{N}'’]+|[^\s\p{L}\p{N}'’]",
  unicode: true,
);

List<String> _tokens(String s) =>
    _tokenRe.allMatches(s).map((m) => m.group(0)!).toList();

bool _isSpace(String t) => t.trim().isEmpty;

/// Word-level diff: splits [after] into segments, flagging the parts that are
/// not in [before] (case-sensitive, so capitalisation fixes count).
List<Seg> diffSegments(String before, String after) {
  final a = _tokens(before.trim());
  final b = _tokens(after);
  final n = a.length, m = b.length;
  if (m == 0) return const [];
  if (n * m > 4000000) return [Seg(after, false)]; // too long to diff cheaply

  String norm(String t) => _isSpace(t) ? ' ' : t;

  // Longest common subsequence table.
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = norm(a[i]) == norm(b[j])
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }

  final changed = List<bool>.filled(m, true);
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (norm(a[i]) == norm(b[j])) {
      changed[j] = false;
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }

  // Whitespace is only "changed" when it joins two changed words.
  final word = List<bool>.generate(m, (k) => changed[k]);
  for (var k = 0; k < m; k++) {
    if (_isSpace(b[k])) {
      changed[k] = k > 0 && k < m - 1 && word[k - 1] && word[k + 1];
    }
  }

  final segs = <Seg>[];
  final buf = StringBuffer();
  var cur = changed[0];
  for (var k = 0; k < m; k++) {
    if (changed[k] != cur) {
      segs.add(Seg(buf.toString(), cur));
      buf.clear();
      cur = changed[k];
    }
    buf.write(b[k]);
  }
  segs.add(Seg(buf.toString(), cur));
  return segs;
}
