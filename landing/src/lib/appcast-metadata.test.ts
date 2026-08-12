import { describe, expect, test } from 'bun:test';
import { parseLatestStableRelease } from './appcast-metadata';

describe('parseLatestStableRelease', () => {
  test('ignores a newer Beta item', () => {
    const appcast = `
      <item>
        <sparkle:version>4.2.1</sparkle:version>
        <sparkle:channel>beta</sparkle:channel>
        <enclosure url="https://github.com/ZingerLittleBee/AnyDoor/releases/download/v4.2.0-beta.1/AnyDoor-4.2.0-beta.1.zip" length="42000000" />
      </item>
      <item>
        <sparkle:version>4.1.199</sparkle:version>
        <enclosure url="https://github.com/ZingerLittleBee/AnyDoor/releases/download/v4.1.1/AnyDoor-4.1.1.zip" length="41000000" />
      </item>`;

    expect(parseLatestStableRelease(appcast)).toEqual({
      version: '4.1.1',
      downloadBytes: 41000000,
    });
  });

  test('selects Stable by internal build instead of XML order', () => {
    const appcast = `
      <item><sparkle:version>4.1.99</sparkle:version><enclosure url="https://github.com/ZingerLittleBee/AnyDoor/releases/download/v4.1.0/AnyDoor-4.1.0.zip" length="1" /></item>
      <item><sparkle:version>4.1.199</sparkle:version><enclosure url="https://github.com/ZingerLittleBee/AnyDoor/releases/download/v4.1.1/AnyDoor-4.1.1.zip" length="2" /></item>`;

    expect(parseLatestStableRelease(appcast).version).toBe('4.1.1');
  });
});
