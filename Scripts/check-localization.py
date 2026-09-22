#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Localizable.xcstrings と Swift 側の文言のずれを見張る。

    Scripts/check-localization.py          ずれていたら 1 で落ちる
    Scripts/check-localization.py --quiet  問題があるときだけ出す

なぜ要るか。SwiftUI の `Text("…")` のようなリテラルは Xcode がビルド時に拾って
カタログへ足してくれるが、`L("…")` のように自前の関数でくるんだものは拾われない。
つまり文言を足しても誰も気づかないままカタログから落ちる。ここで機械的に見る。

見るもの:
  1. `L("…")` のリテラルがカタログにあるか（無ければ英語のまま日本語が出る）
  2. どのキーにも英語の訳が付いていて、state が translated になっているか
  3. 訳の書式指定子がキーと食い違っていないか（%@ の数や順番の取り違え）
  4. カタログにあるのに Swift 側のどこにも見当たらないキー（警告どまり。
     `LName` で実行時に引くものはここに出るので、落とす材料にはしない）
  5. その言語に無い複数形の区分を書いていないか（日本語に `one` を足しても
     選ばれず、書いた側は直したつもりで直っていない）
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, 'Nanovid', 'Localizable.xcstrings')
SOURCE_DIRS = [os.path.join(ROOT, 'Nanovid')]

# 補間も書式指定子も同じ印に潰して突き合わせる。`L("\(n) 個")` が `%lld 個` に
# なるのか `%@ 個` になるのかは呼ぶ側の型で決まり、ここからは見えないため。
HOLE = '\x00'
SPECIFIER = re.compile(r'%(?:\d+\$)?(?:#@\w+@|lld|[@dioux]|\.?\d*l?[fgeEs])')
INTERPOLATION = re.compile(r'(?<!\\)\\\((?:[^()]|\([^()]*\))*\)')
STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')
L_CALL = re.compile(r'\bL\(\s*("(?:[^"\\\n]|\\.)*")\s*\)')


# CLDR の複数形の区分。書いても選ばれない区分を弾くためだけに使うので、
# 迷ったら黙っておく（表に無い言語は見ない）。日本語・中国語・韓国語などは
# 単複の区別そのものが無く、どんな数でも other になる。
PLURAL_CATEGORIES = {
    'ja': {'other'}, 'zh': {'other'}, 'ko': {'other'}, 'th': {'other'},
    'vi': {'other'}, 'id': {'other'}, 'ms': {'other'},
    'en': {'one', 'other'}, 'de': {'one', 'other'}, 'nl': {'one', 'other'},
    'es': {'one', 'other'}, 'it': {'one', 'other'}, 'pt': {'one', 'other'},
    'sv': {'one', 'other'}, 'da': {'one', 'other'}, 'nb': {'one', 'other'},
    'tr': {'one', 'other'}, 'fi': {'one', 'other'},
}


def plural_categories(language):
    return PLURAL_CATEGORIES.get(language.split('-')[0].split('_')[0])


def used_plural_categories(node, found=None):
    """localizations の下で使われている複数形の区分を集める。"""
    found = set() if found is None else found
    if not isinstance(node, dict):
        return found
    for kind, child in (node.get('variations') or {}).items():
        if kind == 'plural':
            found.update((child or {}).keys())
        for grandchild in (child or {}).values():
            used_plural_categories(grandchild, found)
    for child in (node.get('substitutions') or {}).values():
        used_plural_categories(child, found)
    return found


def punch(text):
    return INTERPOLATION.sub(HOLE, SPECIFIER.sub(HOLE, text))


def swift_files():
    for base in SOURCE_DIRS:
        for dirpath, _, names in os.walk(base):
            for name in sorted(names):
                if name.endswith('.swift'):
                    yield os.path.join(dirpath, name)


def unescape(literal):
    """Swift のリテラル表記を、カタログに入っている素の文字列へ戻す。"""
    body = literal[1:-1]
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == '\\' and i + 1 < len(body):
            nxt = body[i + 1]
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'", '0': '\0'}.get(nxt, '\\' + nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def translation_values(localization):
    """stringUnit / variations / substitutions のどこにあっても訳文を集める。

    (訳文, state, 変種かどうか) を返す。複数形の変種は単数形で数を落とすことが
    あるので（"Clip"）、書式指定子の数がキーと揃わなくてよい。
    """
    found = []

    def walk(node, variant):
        if not isinstance(node, dict):
            return
        unit = node.get('stringUnit')
        if isinstance(unit, dict):
            found.append((unit.get('value', ''), unit.get('state'), variant))
        for child in (node.get('variations') or {}).values():
            for grandchild in (child or {}).values():
                walk(grandchild, True)
        for child in (node.get('substitutions') or {}).values():
            walk(child, True)

    walk(localization, False)
    return found


def main():
    quiet = '--quiet' in sys.argv
    catalog = json.load(open(CATALOG, encoding='utf-8'))
    strings = catalog['strings']
    source_language = catalog.get('sourceLanguage', 'ja')

    by_shape = {}
    for key in strings:
        by_shape.setdefault(punch(key), []).append(key)

    errors, warnings = [], []

    # 1. L("…") がカタログにあるか
    seen_literals = set()
    for path in swift_files():
        rel = os.path.relpath(path, ROOT)
        for number, line in enumerate(open(path, encoding='utf-8'), 1):
            if line.lstrip().startswith('//'):
                continue
            for match in STRING_LITERAL.finditer(line):
                seen_literals.add(punch(unescape(match.group())))
            for match in L_CALL.finditer(line):
                shape = punch(unescape(match.group(1)))
                if shape not in by_shape:
                    errors.append('%s:%d  L(%s) がカタログにありません'
                                  % (rel, number, match.group(1)))

    # 2 と 3. 訳の抜けと、書式指定子の食い違い
    languages = sorted({lang for entry in strings.values()
                        for lang in (entry.get('localizations') or {})} - {source_language})
    for key in sorted(strings):
        entry = strings[key]
        localizations = entry.get('localizations') or {}
        expected = SPECIFIER.findall(key)
        for language in languages:
            localization = localizations.get(language)
            if not localization:
                errors.append('%s に %s の訳がありません: %r' % (language, language, key))
                continue
            found = translation_values(localization)
            if not found:
                errors.append('%s の訳が空です: %r' % (language, key))
            for value, state, variant in found:
                if state != 'translated':
                    errors.append('%s の訳が未確定 (%s) です: %r' % (language, state, key))
                # 置換トークン (%#@name@ と、その中の %arg) は実行時に展開される。
                if '#@' in value or '%arg' in value:
                    continue
                actual = SPECIFIER.findall(value)
                if variant:
                    # 変種は数を落としてよいが、キーに無いものを足すのは駄目。
                    extra = [s for s in actual if s not in expected]
                    if extra:
                        errors.append('%s の変種にキーに無い書式指定子があります: %r -> %r (%s)'
                                      % (language, key, value, extra))
                elif sorted(actual) != sorted(expected):
                    errors.append('%s の書式指定子がキーと違います: %r -> %r (%s / %s)'
                                  % (language, key, value, expected, actual))

    # 5. その言語に無い複数形の区分
    for key in sorted(strings):
        for language, localization in (strings[key].get('localizations') or {}).items():
            categories = plural_categories(language)
            if categories is None:
                continue
            for category in sorted(used_plural_categories(localization)):
                if category not in categories:
                    errors.append('%s に %r の複数形はありません（書いても選ばれない）: %r'
                                  % (language, category, key))

    # 4. 使われていないかもしれないキー
    for key in sorted(strings):
        if punch(key) not in seen_literals:
            warnings.append('Swift 側に見当たりません（LName で引くものなら問題なし）: %r' % key)

    for warning in warnings:
        if not quiet:
            print('警告: ' + warning)
    for error in errors:
        print('エラー: ' + error, file=sys.stderr)

    if errors:
        print('\nカタログと合っていない箇所が %d 件あります。' % len(errors), file=sys.stderr)
        return 1
    if not quiet:
        print('カタログ: %d キー / 訳 %s / 未確認 %d 件'
              % (len(strings), ','.join(languages) or '(なし)', len(warnings)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
