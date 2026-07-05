import { PWSlider } from 'meeting-pipe-design';

// PWSlider renders fragments meant for a stacked row: track fills, value sits right.
export const Timeout = () => (
  <div style={{ width: 380, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)' }}>
    <div style={{ fontSize: 13 }}>Prompt timeout</div>
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 8 }}>
      <PWSlider value={30} max={120} format="30 s" />
    </div>
  </div>
);

// A ratio-style value with the thumb past halfway.
export const Gain = () => (
  <div style={{ width: 380, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)' }}>
    <div style={{ fontSize: 13 }}>Input gain</div>
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 8 }}>
      <PWSlider value={6} max={10} format="0.6" />
    </div>
  </div>
);
