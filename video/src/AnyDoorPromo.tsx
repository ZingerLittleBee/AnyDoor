import type {FC} from 'react';
import {AbsoluteFill} from 'remotion';
import {TransitionSeries, linearTiming} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {slide} from '@remotion/transitions/slide';
import type {Lang} from './copy';
import {loadFonts} from './fonts';
import {ease, sceneDurations, transitions} from './timing';
import {Scene0} from './scenes/Scene0';
import {Scene1} from './scenes/Scene1';
import {Scene2} from './scenes/Scene2';
import {Scene3} from './scenes/Scene3';
import {Scene4} from './scenes/Scene4';
import {Scene5} from './scenes/Scene5';

export const AnyDoorPromo: FC<{lang: Lang}> = ({lang}) => {
  loadFonts();

  const standardTiming = linearTiming({
    durationInFrames: transitions.standard,
    easing: ease,
  });
  const montageOutTiming = linearTiming({
    durationInFrames: transitions.montageOut,
    easing: ease,
  });

  return (
    <AbsoluteFill>
      <TransitionSeries>
        <TransitionSeries.Sequence durationInFrames={sceneDurations.scene0}>
          <Scene0 lang={lang} />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={standardTiming} />
        <TransitionSeries.Sequence durationInFrames={sceneDurations.scene1}>
          <Scene1 lang={lang} />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={standardTiming} />
        <TransitionSeries.Sequence durationInFrames={sceneDurations.scene2}>
          <Scene2 lang={lang} />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={standardTiming} />
        <TransitionSeries.Sequence durationInFrames={sceneDurations.scene3}>
          <Scene3 lang={lang} />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={standardTiming} />
        <TransitionSeries.Sequence durationInFrames={sceneDurations.scene4}>
          <Scene4 lang={lang} />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={slide({direction: 'from-right'})}
          timing={montageOutTiming}
        />
        <TransitionSeries.Sequence durationInFrames={sceneDurations.scene5}>
          <Scene5 lang={lang} />
        </TransitionSeries.Sequence>
      </TransitionSeries>
    </AbsoluteFill>
  );
};
