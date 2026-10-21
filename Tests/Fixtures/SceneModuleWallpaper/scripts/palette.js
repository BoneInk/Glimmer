import * as WEColor from 'WEColor';
let color=new Vec3(1,0.45,0.12);
export function setTint(value) { color=value.copy(); }
export default function tint() {
  return WEColor.hsv2rgb(WEColor.rgb2hsv(color));
}
