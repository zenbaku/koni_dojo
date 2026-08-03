import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:koni_dojo/src/extended_selectors.dart';
import 'package:test/test.dart';

List<String> _texts(List<Element> els) =>
    els.map((e) => e.text.trim()).toList();

void main() {
  // A pretty-printed (i.e. whitespace-padded) fixture shaped like a real
  // scrape target, so indices are exercised against the same messy
  // whitespace-between-tags reality koni_dojo scrapes against, not a
  // minified string.
  final chapterList = html_parser.parse('''
    <html lang="en">
      <body>
        <ul class="chapter-list" id="chapters">
          <li class="chapter free">Chapter 1</li>
          <li class="chapter free">Chapter 2 special</li>
          <li class="chapter premium">Chapter 3 (locked)</li>
          <li class="chapter free">Chapter 4</li>
          <li class="chapter free">Chapter 5</li>
        </ul>
        <div class="reader" data-pages="3">
          <img src="p1.jpg" class="page">
          <span class="caption">note</span>
          <img src="p2.jpg" class="page">
          <img src="p3.jpg" class="page">
        </div>
      </body>
    </html>
  ''');

  group('parity with the built-in evaluator on selectors both support', () {
    final selectors = [
      '.chapter',
      'li.chapter.free',
      '#chapters',
      'ul.chapter-list > li',
      'div.reader img',
      'img[src\$=".jpg"]',
      'img[src^="p"]',
      'li:not(.premium)',
      'li:first-child',
      'li:last-child',
      '*[data-pages]',
      ':root',
    ];

    for (final selector in selectors) {
      test('"$selector" matches the same elements as querySelectorAll', () {
        expect(
          chapterList.querySelectorAllExt(selector),
          orderedEquals(chapterList.querySelectorAll(selector)),
        );
      });
    }

    test(':lang() still resolves through inherited lang attribute', () {
      expect(
        chapterList.querySelectorAllExt('li:lang(en)'),
        orderedEquals(chapterList.querySelectorAll('li:lang(en)')),
      );
    });
  });

  group(':contains()', () {
    test('matches an element whose text contains the substring', () {
      final results = chapterList.querySelectorAllExt('li:contains(special)');
      expect(_texts(results), ['Chapter 2 special']);
    });

    test('a multi-word unquoted argument matches the whole phrase', () {
      // Consecutive identifier tokens accumulate into one argument span, so
      // this works despite having no quoting.
      final results = chapterList.querySelectorAllExt('li:contains(2 special)');
      expect(_texts(results), ['Chapter 2 special']);
    });

    test('a quoted argument is a parse error, not a runtime one', () {
      // csslib's pseudo-function argument parser only assembles a proper
      // SelectorExpression out of numbers/operators/bare identifiers (the
      // grammar An+B needs); a quoted string comes back as a bare
      // LiteralTerm instead, which csslib itself rejects before our
      // evaluator ever runs. :contains() arguments must stay unquoted.
      expect(
        () => chapterList.querySelectorAllExt("li:contains('locked')"),
        throwsFormatException,
      );
    });

    test('is case-sensitive and substring, not whole-word', () {
      expect(chapterList.querySelectorAllExt('li:contains(Locked)'), isEmpty);
      expect(
        _texts(chapterList.querySelectorAllExt('li:contains(hapter)')),
        hasLength(5),
      );
    });

    test('returns nothing when no element contains the text', () {
      expect(chapterList.querySelectorAllExt('li:contains(nope)'), isEmpty);
    });

    test('composes with a preceding combinator', () {
      final results = chapterList.querySelectorAllExt(
        '#chapters > li:contains(4)',
      );
      expect(_texts(results), ['Chapter 4']);
    });
  });

  group(':nth-of-type() / :nth-last-of-type()', () {
    test('counts only same-tag siblings, skipping interleaved tags', () {
      // The reader div interleaves img/span/img/img; nth-of-type must count
      // position among <img> siblings only, not among all children.
      final results = chapterList.querySelectorAllExt(
        'div.reader img:nth-of-type(2)',
      );
      expect(results.map((e) => e.attributes['src']), ['p2.jpg']);
    });

    test('first-of-type / last-of-type ignore other tag types', () {
      expect(
        chapterList
            .querySelectorAllExt('div.reader img:first-of-type')
            .single
            .attributes['src'],
        'p1.jpg',
      );
      expect(
        chapterList
            .querySelectorAllExt('div.reader img:last-of-type')
            .single
            .attributes['src'],
        'p3.jpg',
      );
      expect(
        chapterList.querySelectorAllExt('div.reader span:only-of-type'),
        hasLength(1),
      );
    });

    test('nth-last-of-type counts from the end among same-tag siblings', () {
      final results = chapterList.querySelectorAllExt(
        'div.reader img:nth-last-of-type(1)',
      );
      expect(results.map((e) => e.attributes['src']), ['p3.jpg']);
    });

    test('out-of-range index matches nothing', () {
      expect(
        chapterList.querySelectorAllExt('div.reader img:nth-of-type(99)'),
        isEmpty,
      );
    });
  });

  group(':nth-child() / :nth-last-child()', () {
    test('a bare integer is 1-indexed among element siblings', () {
      expect(_texts(chapterList.querySelectorAllExt('li:nth-child(3)')), [
        'Chapter 3 (locked)',
      ]);
    });

    test('"odd" and "even" match alternating positions', () {
      expect(_texts(chapterList.querySelectorAllExt('li:nth-child(odd)')), [
        'Chapter 1',
        'Chapter 3 (locked)',
        'Chapter 5',
      ]);
      expect(_texts(chapterList.querySelectorAllExt('li:nth-child(even)')), [
        'Chapter 2 special',
        'Chapter 4',
      ]);
    });

    test('An+B forms are equivalent to their odd/even shorthand', () {
      expect(
        chapterList.querySelectorAllExt('li:nth-child(2n+1)'),
        equals(chapterList.querySelectorAllExt('li:nth-child(odd)')),
      );
      expect(
        chapterList.querySelectorAllExt('li:nth-child(2n)'),
        equals(chapterList.querySelectorAllExt('li:nth-child(even)')),
      );
    });

    test('negative-offset An+B selects a leading run', () {
      // -n+3 selects positions 1..3 (every position where (pos-3)/-1 >= 0).
      expect(_texts(chapterList.querySelectorAllExt('li:nth-child(-n+3)')), [
        'Chapter 1',
        'Chapter 2 special',
        'Chapter 3 (locked)',
      ]);
    });

    test('nth-last-child(1) is the last element sibling, not last node', () {
      expect(_texts(chapterList.querySelectorAllExt('li:nth-last-child(1)')), [
        'Chapter 5',
      ]);
    });

    test('an unparseable argument matches nothing rather than throwing', () {
      expect(chapterList.querySelectorAllExt('li:nth-child(garbage)'), isEmpty);
    });

    test(
      'whitespace text nodes between tags do not shift the element index',
      () {
        // package:html's own nth-child indexes parent.nodes (including
        // whitespace text nodes from pretty-printing), so on this
        // pretty-printed fixture it resolves nth-child(3) to the *2nd* <li>
        // instead of the 3rd. We index element children only and get it
        // right. Both assertions are pinned so a future change to either
        // implementation is caught here rather than discovered in a scrape.
        expect(
          chapterList.querySelector('li:nth-child(3)')?.text.trim(),
          'Chapter 2 special', // built-in: known-wrong, pinned as documentation
        );
        expect(
          chapterList.querySelectorExt('li:nth-child(3)')?.text.trim(),
          'Chapter 3 (locked)', // ours: correct
        );
      },
    );
  });

  group('malformed input and unsupported selectors', () {
    test('an invalid selector string throws FormatException', () {
      // An unclosed attribute-selector bracket; csslib rejects this outright
      // rather than recovering leniently (unlike e.g. '###' or '>>>', which
      // it parses without error despite being nonsensical selectors).
      expect(
        () => chapterList.querySelectorAllExt('div['),
        throwsFormatException,
      );
    });

    test('a genuinely unimplemented pseudo-class still throws', () {
      expect(
        () => chapterList.querySelectorAllExt('li:has(span)'),
        throwsUnimplementedError,
      );
    });

    test('a genuinely unimplemented pseudo-element still throws', () {
      expect(
        () => chapterList.querySelectorAllExt('li::marker'),
        throwsUnimplementedError,
      );
    });

    test('legacy pseudo-elements never match, matching browser semantics', () {
      expect(chapterList.querySelectorAllExt('li::before'), isEmpty);
    });
  });

  group('querySelectorExt (single result)', () {
    test('returns the first match in document (preorder) order', () {
      expect(
        chapterList.querySelectorExt('li:contains(Chapter)')?.text.trim(),
        'Chapter 1',
      );
    });

    test('returns null when nothing matches', () {
      expect(chapterList.querySelectorExt('li:contains(missing)'), isNull);
    });
  });

  group('supportedPseudoClasses / supportedPseudoClassFunctions', () {
    // These constants are the contract a selector lint would check a
    // config's selector strings against instead of duplicating the switch
    // statements in extended_selectors.dart. Pin them here against the
    // evaluator's *actual* behavior so the two can't silently drift apart
    // (e.g. a case added to a switch but never added to the constant, or
    // vice versa).
    final doc = html_parser.parse('<div><p class="x">a</p></div>');

    test('every name in supportedPseudoClasses matches without throwing', () {
      for (final name in supportedPseudoClasses) {
        expect(
          () => doc.querySelectorAllExt('*:$name'),
          returnsNormally,
          reason: ':$name',
        );
      }
    });

    test(
      'every name in supportedPseudoClassFunctions matches without throwing',
      () {
        const sampleArgs = {
          'lang': 'en',
          'contains': 'a',
          'nth-child': '1',
          'nth-last-child': '1',
          'nth-of-type': '1',
          'nth-last-of-type': '1',
        };
        expect(
          sampleArgs.keys.toSet(),
          supportedPseudoClassFunctions,
          reason:
              'add a sample argument above for every name in '
              'supportedPseudoClassFunctions',
        );
        for (final entry in sampleArgs.entries) {
          expect(
            () => doc.querySelectorAllExt('*:${entry.key}(${entry.value})'),
            returnsNormally,
            reason: ':${entry.key}(${entry.value})',
          );
        }
      },
    );

    test('a name outside both sets still throws, not silently matches', () {
      expect(
        () => doc.querySelectorAllExt('*:has(p)'),
        throwsUnimplementedError,
      );
      expect(
        () => doc.querySelectorAllExt('*:is(p)'),
        throwsUnimplementedError,
      );
      expect(
        () => doc.querySelectorAllExt('p::marker'),
        throwsUnimplementedError,
      );
    });
  });
}
