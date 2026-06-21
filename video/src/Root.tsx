import type {FC} from 'react';
import {Composition} from 'remotion';
import {z} from 'zod';
import {AnyDoorPromo} from './AnyDoorPromo';
import {timeline, video} from './timing';

export const promoSchema = z.object({
  lang: z.enum(['zh', 'en']),
});

export type PromoProps = z.infer<typeof promoSchema>;

export const RemotionRoot: FC = () => {
  return (
    <>
      <Composition
        id="AnyDoorPromo"
        component={AnyDoorPromo}
        schema={promoSchema}
        defaultProps={{lang: 'zh'}}
        width={video.width}
        height={video.height}
        fps={video.fps}
        durationInFrames={timeline.durationInFrames}
      />
      <Composition
        id="AnyDoorPromoEn"
        component={AnyDoorPromo}
        schema={promoSchema}
        defaultProps={{lang: 'en'}}
        width={video.width}
        height={video.height}
        fps={video.fps}
        durationInFrames={timeline.durationInFrames}
      />
    </>
  );
};
