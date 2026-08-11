/* Checks the panel's relative-time labels.
 *
 * This is the only real logic in panel.js, and it had three off-by-one-unit
 * bugs at the boundaries — rounding could push a count up to exactly the next
 * unit, producing "60 minutes ago", "24 hours ago" and "12 months ago".
 *
 * The function is lifted out of panel.js rather than duplicated, so this
 * cannot drift from what ships. Run with `rake js`, or:
 *
 *   node test/time_labels.js
 */
'use strict';

var fs = require('fs');
var path = require('path');

var source = fs.readFileSync(
  path.join(__dirname, '..', 'src', 'snapshot_vcs', 'html', 'panel.js'), 'utf8'
);

var start = source.indexOf('  function relativeTime(iso)');
var end = source.indexOf('  function absoluteTime(iso)');

if (start === -1 || end === -1) {
  console.error('could not find relativeTime in panel.js');
  process.exit(1);
}

/* eslint-disable no-new-func */
var relativeTime = new Function(
  source.slice(start, end) + '\nreturn relativeTime;'
)();

var MINUTE = 60;
var HOUR = 3600;
var DAY = 86400;
var WEEK = 604800;
var YEAR = 86400 * 365;

var cases = [
  [10, 'just now'],
  [44, 'just now'],
  [45, '1 minute ago'],
  [90, '2 minutes ago'],
  [59 * MINUTE, '59 minutes ago'],
  [59.6 * MINUTE, '1 hour ago'],      // rounded to 60 minutes
  [HOUR, '1 hour ago'],
  [1.5 * HOUR, '2 hours ago'],
  [23 * HOUR, '23 hours ago'],
  [23.6 * HOUR, '1 day ago'],         // rounded to 24 hours
  [DAY, '1 day ago'],
  [2 * DAY, '2 days ago'],
  [6.6 * DAY, '1 week ago'],          // rounded to 7 days
  [WEEK, '1 week ago'],
  [29.5 * DAY, '4 weeks ago'],
  [31 * DAY, '1 month ago'],
  [364 * DAY, '1 year ago'],          // rounded to 12 months
  [YEAR, '1 year ago'],
  [-30, 'just now']                   // a clock that ran backwards
];

var failures = 0;

cases.forEach(function (pair) {
  var seconds = pair[0];
  var expected = pair[1];
  var iso = new Date(Date.now() - seconds * 1000).toISOString();
  var actual = relativeTime(iso);

  if (actual !== expected) {
    console.error('FAIL  ' + seconds + 's: expected "' + expected + '", got "' + actual + '"');
    failures += 1;
  }
});

if (relativeTime('not a date') !== '') {
  console.error('FAIL  an unparseable date should produce no label');
  failures += 1;
}

if (failures) {
  console.error('\n' + failures + ' failure(s)');
  process.exit(1);
}

console.log(cases.length + 1 + ' time labels correct');
