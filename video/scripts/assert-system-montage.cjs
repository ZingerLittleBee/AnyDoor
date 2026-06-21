const React = require('react');
const {renderToStaticMarkup} = require('react-dom/server');
const {copy} = require('../.test-build/copy.js');
const {MenuPanel} = require('../.test-build/ui/MenuPanel.js');
const {SystemMontage} = require('../.test-build/ui/SystemMontage.js');

const screenshotHtml = renderToStaticMarkup(React.createElement(SystemMontage, {frame: 65, lang: 'zh'}));
const clipboardHtml = renderToStaticMarkup(React.createElement(SystemMontage, {frame: 115, lang: 'zh'}));
const muteHtml = renderToStaticMarkup(React.createElement(SystemMontage, {frame: 175, lang: 'zh'}));
const menuPanelHtml = renderToStaticMarkup(React.createElement(MenuPanel, {lang: 'zh'}));

const failures = [];

const expectIncludes = (html, needle, message) => {
  if (!html.includes(needle)) {
    failures.push(message);
  }
};

const expectExcludes = (html, needle, message) => {
  if (html.includes(needle)) {
    failures.push(message);
  }
};

expectIncludes(
  screenshotHtml,
  'data-ui="capture-selection-frame"',
  'Screenshot beat should render a dashed capture selection frame.',
);
expectIncludes(screenshotHtml, 'data-ui="capture-mode-bar"', 'Screenshot beat should render the capture mode bar.');
expectIncludes(screenshotHtml, '区域', 'Capture mode bar should include the Region mode.');
expectIncludes(screenshotHtml, '窗口', 'Capture mode bar should include the Window mode.');
expectIncludes(screenshotHtml, '全屏', 'Capture mode bar should include the Fullscreen mode.');
expectIncludes(screenshotHtml, '定时', 'Capture mode bar should include the Timer mode.');
expectIncludes(screenshotHtml, '滚动截图', 'Capture mode bar should include the Scrolling mode.');
expectIncludes(screenshotHtml, '录屏', 'Capture mode bar should include the Recording mode.');
[
  ['区域', 47],
  ['窗口', 55],
  ['全屏', 63],
  ['定时', 71],
  ['滚动截图', 79],
  ['录屏', 87],
].forEach(([mode, modeFrame]) => {
  const modeHtml = renderToStaticMarkup(React.createElement(SystemMontage, {frame: modeFrame, lang: 'zh'}));
  expectIncludes(
    modeHtml,
    `data-active-capture-mode="${mode}"`,
    `Capture mode "${mode}" should be highlighted at frame ${modeFrame}.`,
  );
});
expectExcludes(clipboardHtml, '⌘⇧V', 'Clipboard history beat should not show the keyboard shortcut.');
expectIncludes(muteHtml, 'data-ui="mute-speaker-icon"', 'Mute beat should render a speaker icon.');
expectIncludes(muteHtml, 'data-ui="mute-speaker-body"', 'Mute beat should render a rounded speaker body.');
expectIncludes(muteHtml, 'data-ui="mute-speaker-cone"', 'Mute beat should render a speaker cone.');
expectIncludes(muteHtml, 'data-ui="mute-speaker-wave"', 'Mute beat should render sound-wave anatomy under the slash.');
expectIncludes(muteHtml, 'data-ui="mute-speaker-slash"', 'Mute beat should render a mute slash.');
expectExcludes(muteHtml, 'M37 63h34l52-37', 'Mute beat should not use the old megaphone-style path.');
expectExcludes(muteHtml, '◖', 'Mute beat should not use the old half-disc glyph.');
expectExcludes(menuPanelHtml, '>V</span>', 'Clipboard history panel row should not show the V shortcut key.');
expectIncludes(copy.close.caption.zh, '一颗按键，一扇任意门。', 'Close scene should use the current Chinese project slogan.');
expectIncludes(copy.close.caption.en, 'One key. Any door.', 'Close scene should use the current English project slogan.');
expectExcludes(copy.close.caption.zh, '启动器只能搜索', 'Close scene should not use the old launcher comparison headline.');
expectExcludes(copy.close.caption.en, 'Launchers search', 'Close scene should not use the old launcher comparison headline.');

if (failures.length > 0) {
  throw new Error(failures.join('\n'));
}
