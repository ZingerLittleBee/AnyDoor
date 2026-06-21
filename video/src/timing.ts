import {Easing, interpolate} from 'remotion';

export const video = {
  width: 1920,
  height: 1080,
  fps: 30,
} as const;

export const sceneDurations = {
  scene0: 90,
  scene1: 180,
  scene2: 180,
  scene3: 180,
  scene4: 220,
  scene5: 240,
} as const;

export const transitions = {
  standard: 12,
  montageOut: 15,
} as const;

export const timeline = {
  durationInFrames:
    sceneDurations.scene0 +
    sceneDurations.scene1 +
    sceneDurations.scene2 +
    sceneDurations.scene3 +
    sceneDurations.scene4 +
    sceneDurations.scene5 -
    transitions.standard * 4 -
    transitions.montageOut,
} as const;

export const ease = Easing.bezier(0.16, 1, 0.3, 1);
export const overshoot = Easing.bezier(0.34, 1.56, 0.64, 1);

export const clamp = (frame: number, input: [number, number], output: [number, number], easing = ease) =>
  interpolate(frame, input, output, {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing,
  });
