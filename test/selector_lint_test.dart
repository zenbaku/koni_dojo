import 'package:test/test.dart';

import '../tool/selector_lint.dart';

List<String> _reasons(List<SelectorLintIssue> issues) =>
    issues.map((i) => i.reason).toList();

void main() {
  test('a clean, ordinary config has no issues', () {
    final extension = {
      'name': 'Example',
      'sources': [
        {
          'popular': {'itemSelector': 'div.item', 'titleSelector': 'a.title'},
          'details': {
            'titleSelector': 'h1.entry-title',
            'cover': [
              {'selector': 'img', 'attr': 'src'},
              {'selector': 'meta[property="og:image"]', 'attr': 'content'},
            ],
          },
        },
      ],
    };
    expect(lintExtensionSelectors(extension, 'example.json'), isEmpty);
  });

  test('an unclosed attribute bracket is invalid syntax', () {
    final issues = lintExtensionSelectors({'selector': 'div['}, 'bad.json');
    expect(issues, hasLength(1));
    expect(issues.single.reason, contains('invalid selector syntax'));
  });

  test('a quoted :contains() argument is invalid syntax, not a false pass', () {
    final issues = lintExtensionSelectors({
      'selector': "li:contains('x')",
    }, 'bad.json');
    expect(issues, hasLength(1));
    expect(issues.single.reason, contains('invalid selector syntax'));
  });

  test('an unsupported pseudo-class is flagged', () {
    final issues = lintExtensionSelectors({
      'selector': 'li:has(span)',
    }, 'bad.json');
    expect(issues, hasLength(1));
    expect(issues.single.reason, contains('unsupported pseudo-class'));
  });

  test('an unsupported pseudo-element is flagged', () {
    final issues = lintExtensionSelectors({
      'selector': 'li::marker',
    }, 'bad.json');
    expect(issues, hasLength(1));
    expect(issues.single.reason, contains('unsupported pseudo-element'));
  });

  test('a legacy pseudo-element is not flagged', () {
    expect(
      lintExtensionSelectors({'selector': 'li::before'}, 'ok.json'),
      isEmpty,
    );
  });

  test('every supported nth-* argument form is accepted', () {
    for (final arg in ['1', 'odd', 'even', '2n+1', '-n+3', 'n']) {
      final issues = lintExtensionSelectors({
        'selector': 'li:nth-child($arg)',
      }, 'ok.json');
      expect(issues, isEmpty, reason: 'nth-child($arg)');
    }
  });

  test('a garbage nth-child argument is flagged as always-empty', () {
    final issues = lintExtensionSelectors({
      'selector': 'li:nth-child(garbage)',
    }, 'bad.json');
    expect(issues, hasLength(1));
    expect(issues.single.reason, contains('can never match anything'));
  });

  test(':contains() and :nth-of-type() are supported, not flagged', () {
    final issues = lintExtensionSelectors({
      'selector': 'div.reader img:nth-of-type(2)',
      'nameSelector': 'li:contains(Chapter)',
    }, 'ok.json');
    expect(issues, isEmpty);
  });

  test('walks every *Selector key shape, including nested arrays', () {
    final extension = {
      'sources': [
        {
          'chapters': {
            'itemSelector': '#chapterlist li',
            'nameSelector': '.lch a',
            'urlSelector': 'a',
          },
          'details': {
            'cover': [
              {'selector': 'div['}, // broken, buried two levels deep
            ],
          },
        },
      ],
    };
    final issues = lintExtensionSelectors(extension, 'deep.json');
    expect(issues, hasLength(1));
    expect(issues.single.selector, 'div[');
    expect(
      issues.single.locations.single,
      'deep.json:sources[0].details.cover[0].selector',
    );
  });

  test('the same broken selector used in two places is reported once, '
      'with both locations', () {
    final extension = {
      'popular': {'itemSelector': 'div['},
      'latest': {'itemSelector': 'div['},
    };
    final issues = lintExtensionSelectors(extension, 'dup.json');
    expect(issues, hasLength(1));
    expect(issues.single.locations, [
      'dup.json:popular.itemSelector',
      'dup.json:latest.itemSelector',
    ]);
  });

  test('non-selector keys are never mistaken for selectors', () {
    final extension = {
      'name': 'Not::a-selector, has(no meaning) here',
      'selectorNote': 'this key name does not end in Selector',
    };
    expect(lintExtensionSelectors(extension, 'ok.json'), isEmpty);
  });

  test('multiple distinct issues in one config are all reported', () {
    final extension = {
      'a': {'selector': 'div['},
      'b': {'selector': 'li:has(span)'},
    };
    final issues = lintExtensionSelectors(extension, 'multi.json');
    expect(_reasons(issues).length, 2);
  });
}
