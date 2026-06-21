const assert = require('node:assert/strict');
const React = require('react');
const {renderToStaticMarkup} = require('react-dom/server');
const {AppIcon} = require('../.test-build/ui/AppIcon.js');

const html = [
  renderToStaticMarkup(React.createElement(AppIcon, {name: 'Finder', size: 96})),
  renderToStaticMarkup(React.createElement(AppIcon, {name: 'Safari', size: 96})),
].join('');

assert.match(html, /data-app-icon="Finder"/);
assert.match(html, /data-app-icon="Safari"/);
assert.match(html, /data-app-icon-shape="finder-face"/);
assert.match(html, /data-app-icon-shape="safari-compass"/);
assert.match(html, /data-app-icon-treatment="minimal-aqua"/);
assert.doesNotMatch(html, /finder-fold/);
assert.doesNotMatch(html, />F<\/div>/);
assert.doesNotMatch(html, />S<\/div>/);
